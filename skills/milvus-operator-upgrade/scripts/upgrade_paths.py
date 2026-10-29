#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Milvus Operator 升级路径策略（官方文档为准，不跟 webinar）。

机器可读入口：
  python3 upgrade_paths.py parse <image-or-tag>
  python3 upgrade_paths.py discover --cr-image I [--status-image S] [--pod-images a,b]
  python3 upgrade_paths.py options --source V [--repo R] [--mode standalone|cluster]
  python3 upgrade_paths.py plan --source V --target T [--mode standalone|cluster] [--has-mixcoord 0|1] [--operator V]
  python3 upgrade_paths.py selftest

输出约定（plan/options）：
  PARSE ok=… major=… minor=… patch=… pre=… channel=ga|rc|beta|alpha|other tag=…
  SOURCE …（discover）
  TARGET_OPTION kind=2.6|3.0 tag=vX.Y.Z image=… recommended=yes|no label=…
  PATH_PLAN final=… hops=vA,vB,…  （每跳细节见 HOP 行）
  HOP index=N tag=v… enable_mixcoord=0|1 require_operator_ge=… apply_mode=merge|cluster_full_cr note=…
  PATH_WARN … / PATH_BLOCK … / PATH_INFO …
"""
from __future__ import print_function
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
POLICY_PATH = os.path.join(HERE, 'upgrade_paths.json')

def load_policy(path=None):
    with open(path or POLICY_PATH, 'r', encoding='utf-8') as f:
        return json.load(f)

# ---------- version parse ----------
# Accepts: v2.6.25 / 2.6.25 / milvusdb/milvus:v3.0.3 / …@sha256:… (no version)
#          v2.6.0-rc1 / v3.0-beta / v3.0.0-beta / spoken "3.0.0-beta"
_TAG_RE = re.compile(
    r'(?:^|:)v?'
    r'(?P<maj>\d+)\.(?P<min>\d+)'
    r'(?:\.(?P<pat>\d+))?'
    r'(?:-(?P<pre>[A-Za-z0-9._-]+))?'
    r'(?:$|[^0-9A-Za-z._-])'
)

def parse_version(s):
    """Return dict or None. channel in ga|rc|beta|alpha|other."""
    if not s:
        return None
    s = str(s).strip()
    # Prefer last path segment / tag after colon (ignore digests)
    if '@sha256:' in s:
        s = s.split('@sha256:', 1)[0]
    tag = s.rsplit(':', 1)[-1] if ('/' in s or s.count(':') == 1) else s
    if tag.startswith('v') and tag[1:2].isdigit():
        cand = tag
    else:
        cand = tag
    m = _TAG_RE.search(cand if cand.startswith('v') or cand[0:1].isdigit() else 'v' + cand)
    # Also try full string (e.g. "3.0.0-beta" without image)
    if not m:
        m = _TAG_RE.search(s)
    if not m:
        # bare "v3.0-beta" style already covered; try spoken forms
        m2 = re.search(r'(?i)\bv?(\d+)\.(\d+)(?:\.(\d+))?-(beta|rc|alpha)([0-9.]*)\b', s)
        if not m2:
            m2 = re.search(r'(?i)\bv?(\d+)\.(\d+)-(beta|rc|alpha)\b', s)
            if m2:
                maj, mn, channel = int(m2.group(1)), int(m2.group(2)), m2.group(3).lower()
                return {
                    'ok': True, 'major': maj, 'minor': mn, 'patch': 0,
                    'pre': channel, 'channel': channel,
                    'tag': 'v%d.%d-%s' % (maj, mn, channel),
                    'tuple': (maj, mn, 0), 'raw': s,
                }
            return None
        maj, mn = int(m2.group(1)), int(m2.group(2))
        pat = int(m2.group(3) or 0)
        channel = m2.group(4).lower()
        pre = channel + (m2.group(5) or '')
        return {
            'ok': True, 'major': maj, 'minor': mn, 'patch': pat,
            'pre': pre, 'channel': channel,
            'tag': 'v%d.%d.%d-%s' % (maj, mn, pat, pre),
            'tuple': (maj, mn, pat), 'raw': s,
        }
    maj, mn = int(m.group('maj')), int(m.group('min'))
    pat = int(m.group('pat') or 0)
    pre = (m.group('pre') or '').lower()
    channel = 'ga'
    if pre:
        if pre.startswith('rc') or '-rc' in pre:
            channel = 'rc'
        elif 'beta' in pre:
            channel = 'beta'
        elif 'alpha' in pre:
            channel = 'alpha'
        else:
            channel = 'other'
    # Special: tag was v3.0-beta → group pat may be None, pre=beta — handled
    tag = 'v%d.%d.%d' % (maj, mn, pat)
    if pre:
        if m.group('pat') is None and channel in ('beta', 'rc', 'alpha'):
            tag = 'v%d.%d-%s' % (maj, mn, pre)
        else:
            tag = 'v%d.%d.%d-%s' % (maj, mn, pat, pre)
    return {
        'ok': True, 'major': maj, 'minor': mn, 'patch': pat,
        'pre': pre, 'channel': channel, 'tag': tag,
        'tuple': (maj, mn, pat), 'raw': s,
    }

def v_str(v):
    if not v:
        return '?'
    if isinstance(v, dict):
        return v['tag'].lstrip('v') if v.get('channel') == 'ga' else v['tag'].lstrip('v')
    if isinstance(v, (tuple, list)) and len(v) >= 3:
        return '%d.%d.%d' % (v[0], v[1], v[2])
    return str(v)

def parse_tuple(s):
    v = parse_version(s)
    return v['tuple'] if v and v['channel'] == 'ga' else (v['tuple'] if v else None)

def cmp_ga(a, b):
    """Compare two GA version dicts/tuples. None if either non-GA."""
    def t(x):
        if isinstance(x, dict):
            if x.get('channel') != 'ga':
                return None
            return x['tuple']
        return tuple(x)
    ta, tb = t(a), t(b)
    if ta is None or tb is None:
        return None
    return (ta > tb) - (ta < tb)

def is_blocked_source(v):
    if not v:
        return '无法解析源版本'
    # 2.6.0-rc* specifically blocked by docs
    if v['major'] == 2 and v['minor'] == 6 and v['patch'] == 0 and v['channel'] == 'rc':
        return '源版本为 2.6.0-rc*：官方文档声明与正式 2.6/3.0 不兼容，不支持直接升级（见 docs）'
    if v['channel'] in ('rc', 'beta', 'alpha') and not (v['major'] == 2 and v['minor'] == 5):
        # other pre-releases as source: block conservatively
        return '源版本为预发布通道 %s（%s），本 skill 不支持以其为源升级' % (v['channel'], v['tag'])
    return ''

def is_blocked_target(v):
    if not v:
        return '无法解析目标版本'
    if v['channel'] in ('beta', 'rc', 'alpha') or 'beta' in (v.get('pre') or '') or 'rc' in (v.get('pre') or ''):
        return '目标为预发布（%s / %s）：已阻止。请选 GA 版本（文档：正式升级路径不使用 v3.0-beta / 3.0.0-beta / rc）' % (v['channel'], v['tag'])
    if v['channel'] != 'ga':
        return '目标通道 %s 不受支持（%s）' % (v['channel'], v['tag'])
    return ''

def discover_source(cr_image='', status_image='', pod_images=None):
    """Prefer CR image → status.currentImage → first parseable pod image."""
    order = []
    if cr_image:
        order.append(('cr_image', cr_image))
    if status_image:
        order.append(('status_currentImage', status_image))
    for p in (pod_images or []):
        if p:
            order.append(('pod', p))
    chosen = None
    for src, img in order:
        v = parse_version(img)
        if v:
            chosen = {'source': src, 'image': img, 'version': v}
            break
    return chosen, order

def _as_ga(s, policy=None):
    v = parse_version(s)
    if not v or v['channel'] != 'ga':
        raise ValueError('not GA: %s' % s)
    return v

def operator_tuple(s):
    v = parse_version(s)
    return v['tuple'] if v else None

def list_options(source_v, repo='milvusdb/milvus', mode='standalone', policy=None):
    """Legal final targets given source. Two end-state families: 2.6.y and 3.0.y."""
    policy = policy or load_policy()
    out = []
    block = is_blocked_source(source_v)
    if block:
        return out, block
    pins = policy['pins']
    st = source_v['tuple']
    # End-state A: GA 2.6.y > source (or any 2.6 if source is 2.5.x)
    for t in policy.get('offer_2_6', []):
        tv = _as_ga(t)
        if cmp_ga(tv, source_v) == 1:
            rec = (t == pins['recommended_2_6'])
            out.append({
                'kind': '2.6', 'tag': tv['tag'], 'version': tv,
                'image': '%s:%s' % (repo, tv['tag']),
                'recommended': rec,
                'label': '停在 2.6.x：%s%s' % (tv['tag'], '（推荐桥接/终点）' if rec else ''),
            })
    # End-state B: GA 3.0.y — allowed as final even from 2.5 (hops expand later);
    # from 3.0.x only higher 3.0; from >3 not listed
    if st[0] < 3 or (st[0] == 3 and st[1] == 0):
        for t in policy.get('offer_3_0', []):
            tv = _as_ga(t)
            if cmp_ga(tv, source_v) != 1:
                continue
            # 2.5 cannot go direct — still a legal FINAL (path will hop via 2.6)
            rec = (t == pins['recommended_3_0'])
            out.append({
                'kind': '3.0', 'tag': tv['tag'], 'version': tv,
                'image': '%s:%s' % (repo, tv['tag']),
                'recommended': rec,
                'label': '升到 3.0.y：%s%s' % (tv['tag'], '（推荐，文档验证路径终点）' if rec else ''),
            })
    # Deduplicate by tag, prefer recommended
    seen = {}
    for o in out:
        prev = seen.get(o['tag'])
        if prev is None or (o['recommended'] and not prev['recommended']):
            seen[o['tag']] = o
    ordered = sorted(seen.values(), key=lambda o: (0 if o['kind'] == '2.6' else 1, o['version']['tuple']))
    # Ensure at least recommended pins appear when legal
    return ordered, ''

def plan_hops(source_v, target_v, mode='standalone', has_mixcoord=False, operator_ver='', policy=None):
    """Expand required hops. Returns dict with hops, warns, blocks, infos."""
    policy = policy or load_policy()
    pins = policy['pins']
    docs = policy['docs']
    warns, blocks, infos, hops = [], [], [], []

    sb = is_blocked_source(source_v)
    if sb:
        blocks.append(sb)
        return {'hops': [], 'warns': warns, 'blocks': blocks, 'infos': infos, 'final': None}
    tb = is_blocked_target(target_v)
    if tb:
        blocks.append(tb + ' 参见 ' + docs.get('cluster_2_6_to_3_0', ''))
        return {'hops': [], 'warns': warns, 'blocks': blocks, 'infos': infos, 'final': None}

    if cmp_ga(target_v, source_v) is not None and cmp_ga(target_v, source_v) <= 0:
        blocks.append('目标 %s ≤ 源 %s：不支持降级/同版本' % (v_str(target_v), v_str(source_v)))
        return {'hops': [], 'warns': warns, 'blocks': blocks, 'infos': infos, 'final': None}

    st, tt = source_v['tuple'], target_v['tuple']
    bridge_2516 = _as_ga(pins['bridge_2_5_with_mixcoord'])
    rec_26 = _as_ga(pins['recommended_2_6'])
    verified_src = _as_ga(pins['verified_2_6_to_3_0_source'])
    min_op = pins['min_operator_for_2_5_to_2_6']

    need_op = False  # operator ≥1.3.7 before 2.5→2.6 image change
    cur = source_v

    def add_hop(tag_v, enable_mixcoord=False, require_op=None, apply_mode='merge', note=''):
        hops.append({
            'tag': tag_v['tag'] if isinstance(tag_v, dict) else ('v' + tag_v if not str(tag_v).startswith('v') else str(tag_v)),
            'version': tag_v if isinstance(tag_v, dict) else _as_ga(tag_v),
            'enable_mixcoord': bool(enable_mixcoord),
            'require_operator_ge': require_op or '',
            'apply_mode': apply_mode,
            'note': note,
        })

    # 2.5 cannot go direct to 3.0
    if st[0] == 2 and st[1] <= 5 and tt[0] >= 3:
        infos.append('2.5.x 不能直达 3.0：将经 2.6.x 桥接（官方文档）')

    # --- Phase: get onto ≥2.5.16 (+ mixCoord for cluster) if still on 2.5.x and going to 2.6+ ---
    if tt[0] > 2 or (tt[0] == 2 and tt[1] >= 6) or tt[0] >= 3:
        if st[0] == 2 and st[1] == 5:
            need_op = True
            if cmp_ga(cur, bridge_2516) < 0:
                # hop to 2.5.16 with mixCoord (cluster)
                add_hop(bridge_2516,
                        enable_mixcoord=(mode == 'cluster'),
                        require_op=min_op,
                        note='源 <2.5.16：先升到 2.5.16' + (' 并启用 mixCoord' if mode == 'cluster' else '') + '（' + docs['cluster_2_5_to_2_6'] + '）')
                cur = bridge_2516
            elif mode == 'cluster' and not has_mixcoord:
                # same version hop: enable mixCoord only (image stays / or reaffirm 2.5.16+)
                mix_tag = cur if cmp_ga(cur, bridge_2516) >= 0 else bridge_2516
                add_hop(mix_tag, enable_mixcoord=True, require_op=min_op,
                        note='Cluster 尚未启用 mixCoord：在改到 2.6 镜像前先启用（' + docs['cluster_2_5_to_2_6'] + '）')
                cur = mix_tag if isinstance(mix_tag, dict) else cur
            else:
                infos.append('已在 ≥2.5.16' + (' 且 mixCoord 已启用' if mode == 'cluster' and has_mixcoord else '') + '，跳过 2.5.16 跳')

    # --- Phase: if target is 3.0 and current still 2.5, hop to recommended 2.6 ---
    if tt[0] >= 3 and cur['tuple'][0] == 2 and cur['tuple'][1] <= 5:
        need_op = True
        bridge = rec_26
        # if somehow recommended_2_6 <= cur (shouldn't), bump
        if cmp_ga(bridge, cur) <= 0:
            bridge = _as_ga(policy['pins']['latest_known_2_6'])
        add_hop(bridge, enable_mixcoord=False, require_op=min_op,
                note='2.5→3.0 桥接：先到 2.6.x %s（官方要求经 2.6；不强制 2.6.24）' % bridge['tag'])
        cur = bridge

    # --- Phase: 2.5 → 2.6 target (direct after mixCoord/2.5.16) ---
    if tt[0] == 2 and tt[1] == 6 and cur['tuple'][0] == 2 and cur['tuple'][1] == 5:
        need_op = True
        add_hop(target_v, enable_mixcoord=False, require_op=min_op,
                note='2.5→2.6：operator≥%s 且 mixCoord 就绪后改镜像（%s）' % (min_op, docs['cluster_2_5_to_2_6']))
        cur = target_v

    # --- Phase: 2.6 → 2.6 higher ---
    if tt[0] == 2 and tt[1] == 6 and cur['tuple'][0] == 2 and cur['tuple'][1] == 6:
        if cmp_ga(target_v, cur) == 1:
            add_hop(target_v, note='2.6.x 小版本升级（image merge）')
            cur = target_v

    # --- Phase: 2.6 → 3.0 ---
    if tt[0] >= 3 and cur['tuple'][0] == 2 and cur['tuple'][1] == 6:
        if cmp_ga(cur, verified_src) < 0:
            warns.append(
                '源 2.6.x（%s）< 文档验证起点 %s：官方写明 validated from 2.6.20 → %s，'
                '任意 2.6.x 仍可直达 GA 3.0.y，但请先在非生产验证（不强制经 2.6.24）。文档：%s'
                % (v_str(cur), pins['verified_2_6_to_3_0_source'], pins['verified_2_6_to_3_0_target'],
                   docs['cluster_2_6_to_3_0'])
            )
        apply_mode = 'cluster_full_cr' if mode == 'cluster' else 'merge'
        note = '2.6→3.0 GA'
        if mode == 'cluster':
            note += '：Cluster 按文档倾向完整 CR apply（保留拓扑，显式 indexNode.replicas=0），勿只用缺字段的 image-only merge（%s）' % docs['cluster_2_6_to_3_0']
        else:
            note += '：Standalone 可用 image merge（本 skill 已验证 2.6.25→3.0.3）；仍设 root securityContext'
        add_hop(target_v, apply_mode=apply_mode, note=note)
        cur = target_v

    # --- Phase: 3.0 → higher 3.0 ---
    if tt[0] == 3 and cur['tuple'][0] == 3:
        if cmp_ga(target_v, cur) == 1:
            apply_mode = 'cluster_full_cr' if mode == 'cluster' else 'merge'
            add_hop(target_v, apply_mode=apply_mode, note='3.0.y 小版本升级')
            cur = target_v

    if not hops and cmp_ga(target_v, source_v) == 1:
        # fallback single hop
        add_hop(target_v, note='直接镜像升级')

    # Operator gate
    if need_op or any(h.get('require_operator_ge') for h in hops):
        req = min_op
        ot = operator_tuple(operator_ver) if operator_ver else None
        rt = parse_tuple(req)
        if ot is None:
            warns.append('需要 operator ≥ %s（2.5→2.6 官方步骤 1），但未能解析当前 operator 版本；请确认后再改 Milvus 镜像（%s）' % (req, docs['cluster_2_5_to_2_6']))
        elif rt and ot < rt:
            blocks.append(
                '当前 operator %s < %s：2.5→2.6 前必须先升级 milvus-operator 到 ≥%s（官方文档 Step 1）。'
                '本 skill 不在其他命名空间改 operator；请用原 Helm/kubectl 安装方式升级 operator 后重跑预检。文档：%s'
                % (operator_ver, req, req, docs['cluster_2_5_to_2_6'])
            )

    # Deduplicate consecutive identical tags with same flags
    dedup = []
    for h in hops:
        if dedup and dedup[-1]['tag'] == h['tag'] and dedup[-1]['enable_mixcoord'] == h['enable_mixcoord'] and dedup[-1]['apply_mode'] == h['apply_mode']:
            # merge notes
            dedup[-1]['note'] = dedup[-1]['note'] + '; ' + h['note']
            continue
        dedup.append(h)

    return {
        'hops': dedup,
        'warns': warns,
        'blocks': blocks,
        'infos': infos,
        'final': target_v['tag'],
        'docs': docs,
        'need_operator_ge': min_op if need_op else '',
    }

def repo_of(image):
    if not image:
        return 'milvusdb/milvus'
    return re.sub(r'(@sha256:[0-9a-f]+|:[A-Za-z0-9_.+-]+)$', '', image) or 'milvusdb/milvus'

# ---------- CLI ----------
def _print_parse(v):
    if not v:
        print('PARSE ok=0')
        return 1
    print('PARSE ok=1 major=%d minor=%d patch=%d pre=%s channel=%s tag=%s' % (
        v['major'], v['minor'], v['patch'], v.get('pre') or '-', v['channel'], v['tag']))
    return 0

def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('parse'); p.add_argument('value')
    d = sub.add_parser('discover')
    d.add_argument('--cr-image', default='')
    d.add_argument('--status-image', default='')
    d.add_argument('--pod-images', default='')
    o = sub.add_parser('options')
    o.add_argument('--source', required=True)
    o.add_argument('--repo', default='milvusdb/milvus')
    o.add_argument('--mode', default='standalone', choices=['standalone', 'cluster'])
    pl = sub.add_parser('plan')
    pl.add_argument('--source', required=True)
    pl.add_argument('--target', required=True)
    pl.add_argument('--mode', default='standalone', choices=['standalone', 'cluster'])
    pl.add_argument('--has-mixcoord', default='0')
    pl.add_argument('--operator', default='')
    pl.add_argument('--repo', default='')
    sub.add_parser('selftest')

    a = ap.parse_args(argv)
    policy = load_policy()

    if a.cmd == 'parse':
        return _print_parse(parse_version(a.value))

    if a.cmd == 'discover':
        pods = [x for x in a.pod_images.split(',') if x]
        chosen, order = discover_source(a.cr_image, a.status_image, pods)
        for src, img in order:
            print('CANDIDATE source=%s image=%s' % (src, img))
        if not chosen:
            print('SOURCE ok=0')
            return 1
        v = chosen['version']
        print('SOURCE ok=1 from=%s image=%s version=%s channel=%s' % (
            chosen['source'], chosen['image'], v['tag'], v['channel']))
        return 0

    if a.cmd == 'options':
        sv = parse_version(a.source)
        if not sv:
            print('PATH_BLOCK 无法解析源版本: %s' % a.source); return 2
        opts, block = list_options(sv, repo=a.repo, mode=a.mode, policy=policy)
        if block:
            print('PATH_BLOCK %s' % block); return 5
        for o_ in opts:
            print('TARGET_OPTION kind=%s tag=%s image=%s recommended=%s label=%s' % (
                o_['kind'], o_['tag'], o_['image'], 'yes' if o_['recommended'] else 'no', o_['label'].replace(' ', '_')))
        print('TARGET_OPTIONS count=%d' % len(opts))
        return 0

    if a.cmd == 'plan':
        sv, tv = parse_version(a.source), parse_version(a.target)
        if not sv:
            print('PATH_BLOCK 无法解析源版本: %s' % a.source); return 2
        if not tv:
            print('PATH_BLOCK 无法解析目标版本: %s' % a.target); return 2
        plan = plan_hops(sv, tv, mode=a.mode, has_mixcoord=a.has_mixcoord in ('1', 'true', 'yes'),
                         operator_ver=a.operator, policy=policy)
        for w in plan['warns']:
            print('PATH_WARN %s' % w)
        for i in plan['infos']:
            print('PATH_INFO %s' % i)
        for b in plan['blocks']:
            print('PATH_BLOCK %s' % b)
        if plan['blocks']:
            print('PATH_PLAN final=%s hops= BLOCKED' % (plan['final'] or a.target))
            return 5
        tags = []
        for i, h in enumerate(plan['hops'], 1):
            tags.append(h['tag'])
            print('HOP index=%d tag=%s enable_mixcoord=%d require_operator_ge=%s apply_mode=%s note=%s' % (
                i, h['tag'], 1 if h['enable_mixcoord'] else 0,
                h.get('require_operator_ge') or '-', h['apply_mode'],
                h.get('note', '').replace('\n', ' ')))
        print('PATH_PLAN final=%s hops=%s' % (plan['final'], ','.join(tags)))
        return 0

    if a.cmd == 'selftest':
        return selftest(policy)
    return 2

def selftest(policy=None):
    policy = policy or load_policy()
    fails = []

    def expect(cond, msg):
        if not cond:
            fails.append(msg); print('FAIL %s' % msg)
        else:
            print('OK   %s' % msg)

    # parse
    expect(parse_version('milvusdb/milvus:v2.6.25')['tuple'] == (2, 6, 25), 'parse image tag')
    expect(parse_version('v2.6.0-rc1')['channel'] == 'rc', 'parse rc')
    expect(parse_version('v3.0-beta')['channel'] == 'beta', 'parse v3.0-beta')
    expect(parse_version('3.0.0-beta')['channel'] == 'beta', 'parse spoken beta')
    expect(parse_version('registry.example/xy/milvus:v3.0.3')['tag'] == 'v3.0.3', 'parse private repo')

    # discover preference
    ch, _ = discover_source('repo:v2.6.10', 'repo:v2.6.11', ['repo:v2.6.12'])
    expect(ch['version']['tuple'] == (2, 6, 10), 'discover prefers cr image')
    ch2, _ = discover_source('', 'repo:v2.6.11', ['repo:v2.6.12'])
    expect(ch2['version']['tuple'] == (2, 6, 11), 'discover falls back to status')

    # blocked source/target
    expect(bool(is_blocked_source(parse_version('v2.6.0-rc1'))), 'block 2.6.0-rc source')
    expect(bool(is_blocked_target(parse_version('v3.0-beta'))), 'block beta target')
    expect(bool(is_blocked_target(parse_version('v3.0.0-beta'))), 'block 3.0.0-beta target')

    # options: 2.5 source gets both 2.6 and 3.0 finals
    opts, blk = list_options(parse_version('v2.5.10'), policy=policy)
    expect(not blk, '2.5.10 options not blocked')
    kinds = set(o['kind'] for o in opts)
    expect('2.6' in kinds and '3.0' in kinds, '2.5.10 offers 2.6 and 3.0 end-states')

    # 2.6.25 → options higher 2.6 + 3.0
    opts2, _ = list_options(parse_version('v2.6.25'), policy=policy)
    tags = [o['tag'] for o in opts2]
    expect('v2.6.26' in tags, '2.6.25 can go to 2.6.26')
    expect(any(o['kind'] == '3.0' for o in opts2), '2.6.25 can go to 3.0')
    expect('v2.6.20' not in tags, '2.6.20 not offered from 2.6.25')

    # plan: 2.5.10 → 2.6.25 expands via 2.5.16
    p = plan_hops(parse_version('v2.5.10'), parse_version('v2.6.25'), mode='cluster',
                  has_mixcoord=False, operator_ver='1.3.12', policy=policy)
    hop_tags = [h['tag'] for h in p['hops']]
    expect(hop_tags[0] == 'v2.5.16' and p['hops'][0]['enable_mixcoord'], '2.5.10 cluster: first hop 2.5.16+mixCoord')
    expect(hop_tags[-1] == 'v2.6.25', '2.5.10 → ends at 2.6.25')
    expect(not p['blocks'], '2.5.10→2.6.25 with op 1.3.12 not blocked')

    # operator too old blocks
    p2 = plan_hops(parse_version('v2.5.20'), parse_version('v2.6.25'), mode='cluster',
                   has_mixcoord=True, operator_ver='1.2.0', policy=policy)
    expect(bool(p2['blocks']), 'operator <1.3.7 blocks 2.5→2.6')

    # 2.5 → 3.0 hops via 2.6, not forced 2.6.24
    p3 = plan_hops(parse_version('v2.5.20'), parse_version('v3.0.3'), mode='standalone',
                   has_mixcoord=True, operator_ver='1.3.12', policy=policy)
    hop_tags3 = [h['tag'] for h in p3['hops']]
    expect('v2.6.24' not in hop_tags3, 'do NOT force hop through 2.6.24')
    expect(any(t.startswith('v2.6.') for t in hop_tags3), '2.5→3.0 includes 2.6 bridge')
    expect(hop_tags3[-1] == 'v3.0.3', '2.5→3.0 ends at 3.0.3')

    # any 2.6.x → 3.0.3 direct; soft warn if <2.6.20
    p4 = plan_hops(parse_version('v2.6.10'), parse_version('v3.0.3'), mode='cluster',
                   operator_ver='1.3.12', policy=policy)
    expect([h['tag'] for h in p4['hops']] == ['v3.0.3'], '2.6.10→3.0.3 single hop (docs: any 2.6.x)')
    expect(bool(p4['warns']), '2.6.10→3.0 soft-warn verified path 2.6.20')
    expect(p4['hops'][0]['apply_mode'] == 'cluster_full_cr', 'cluster 3.0 uses full CR apply mode')

    p5 = plan_hops(parse_version('v2.6.20'), parse_version('v3.0.3'), mode='standalone',
                   operator_ver='1.3.12', policy=policy)
    expect(not p5['warns'], '2.6.20→3.0.3 no soft-warn')
    expect(p5['hops'][0]['apply_mode'] == 'merge', 'standalone 3.0 merge')

    # downgrade blocked
    p6 = plan_hops(parse_version('v2.6.25'), parse_version('v2.6.10'), policy=policy)
    expect(bool(p6['blocks']), 'downgrade blocked')

    # beta target blocked
    p7 = plan_hops(parse_version('v2.6.25'), parse_version('v3.0-beta'), policy=policy)
    expect(bool(p7['blocks']), 'beta target blocked')

    if fails:
        print('SELFTEST fails=%d' % len(fails)); return 1
    print('SELFTEST ok'); return 0

if __name__ == '__main__':
    # argparse required=True on subparsers needs py3; provide fallback
    try:
        sys.exit(main() or 0)
    except TypeError:
        # py3.6 may not support required= on subparsers the same way — still fine on 3.6+ with required=
        raise
