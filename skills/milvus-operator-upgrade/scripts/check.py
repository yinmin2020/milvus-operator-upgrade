#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只读预检（不创建、不修改任何集群对象，不写任何文件）。
用法:
  check.py upgrade <NS> [--name CR] [--target-tag TAG] [--target-image IMG] [--backup-bin PATH] [--workdir DIR] [--operator-ns ONS]
  check.py restore <NS> [--name CR] [--backup-bin PATH] [--workdir DIR]
只用管理员 kubeconfig 做 get/list 和 auth can-i（SelfSubjectAccessReview 不落盘），不读 Secret。
输出: CHECK key=value（事实）、CHECK_ITEM name STATUS detail（PASS/FAIL/WARN/INFO/MISSING）、SUGGEST key=value、人读表格、
      最后一行 CHECK_RESULT rc=N（0 全部通过 | 2 需要选择 CR | 3 环境/NS 不存在 |
      4 只缺 milvus-backup（前置条件；打印 NEEDS install_backup、官方下载链接与期望 sha256，由用户自行下载并告知位置）| 5 有 FAIL 项）。
"""
import argparse, fcntl, glob, json, os, re, shutil, socket, stat, subprocess, sys, time
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import upgrade_paths as upaths
import registry_check as regchk

ap = argparse.ArgumentParser()
ap.add_argument('mode', choices=['upgrade', 'restore'])
ap.add_argument('ns')
ap.add_argument('--name', default='')
ap.add_argument('--target-tag', default='', help='最终目标 tag（如 v3.0.3）；省略则只列出合法终点')
ap.add_argument('--target-image', default='')
ap.add_argument('--backup-bin', default=os.environ.get('MILVUS_BACKUP_BIN', ''))
ap.add_argument('--workdir', default='/root/milvus-upgrade')
ap.add_argument('--operator-ns', default='')
ap.add_argument('--rbac-test', action='store_true')
ap.add_argument('--backup', default='', help='restore：检查指定备份（默认最近一个）')
a = ap.parse_args()
KC = os.environ.get('ADMIN_KUBECONFIG') or os.environ.get('KUBECONFIG') or os.path.expanduser('~/.kube/config')
ITEMS = []; FACTS = []

def fact(k, v):
    v = '' if v is None else str(v)
    FACTS.append((k, v)); print('CHECK %s=%s' % (k, v)); sys.stdout.flush()

def item(name, st, detail=''):
    ITEMS.append((name, st, detail)); print('CHECK_ITEM %s %s %s' % (name, st, detail)); sys.stdout.flush()

def k(*args):
    p = subprocess.run(['kubectl', '--kubeconfig', KC] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def finish(rc):
    print('\n| 检查项 | 结果 | 说明 |\n|---|---|---|')
    for n, s, d in ITEMS:
        print('| %s | %s | %s |' % (n, s, d.replace('|', '/')))
    print('CHECK_RESULT rc=%d' % rc)
    sys.exit(rc)

def ver(img):
    """GA tuple (maj,min,pat) or None. Pre-release returns None here; use ver_full()."""
    v = upaths.parse_version(img or '')
    if not v or v['channel'] != 'ga':
        return None
    return v['tuple']

def ver_full(img):
    return upaths.parse_version(img or '')

def vs(t):
    if isinstance(t, dict):
        return upaths.v_str(t)
    return '.'.join(map(str, t)) if t else '?'

fact('mode', a.mode); fact('namespace', a.ns)
print('NOTE 只读检查：不创建、不修改任何对象（仅 get/list 与 auth can-i）')

# 1. master 工具
miss = [t for t in ('kubectl', 'python3', 'flock', 'ss', 'tar', 'base64') if not shutil.which(t)]
item('master_tools', 'FAIL' if miss else 'PASS', ('缺少: ' + ' '.join(miss)) if miss else 'kubectl python3 flock ss tar base64')
if 'kubectl' in miss:
    finish(3)
if not os.access(KC, os.R_OK):
    item('admin_kubeconfig', 'FAIL', '不可读: ' + KC); finish(3)

# 2. NS
rc, out, err = k('get', 'ns', a.ns, '-o', 'name')
if rc != 0:
    item('namespace', 'FAIL', '命名空间 %s 不存在或管理员 kubeconfig 不可用: %s' % (a.ns, err[:160])); finish(3)
item('namespace', 'PASS', a.ns)

# 3. 管理员能否创建临时 SA/Role/RoleBinding/token（正式运行需要；can-i 不落盘）
bad = []
for v in ('create serviceaccounts', 'create roles', 'create rolebindings', 'create serviceaccounts/token'):
    rc, out, _ = k('auth', 'can-i', *v.split(), '-n', a.ns)
    if out != 'yes':
        bad.append(v)
item('admin_rbac', 'FAIL' if bad else 'PASS', ('管理员无权: ' + ', '.join(bad)) if bad else '可在 NS 内创建临时 SA/Role/RoleBinding/token')

# 4. CR 发现
rc, out, err = k('-n', a.ns, 'get', 'milvus', '-o', 'json')
if rc != 0:
    item('milvus_crd', 'FAIL', '无法列出 Milvus CR（未安装 milvus-operator CRD？）: ' + err[:160]); finish(3)
crs = json.loads(out).get('items', [])
names = [c['metadata']['name'] for c in crs]
fact('cr_candidates', ','.join(names))
cr = None
if a.name:
    cr = next((c for c in crs if c['metadata']['name'] == a.name), None)
elif len(crs) == 1:
    cr = crs[0]
elif len(crs) > 1:
    print('NEED_CR_NAME candidates=%s' % ','.join(names))
    item('cr', 'FAIL', 'NS 内有多个 Milvus CR，需要选择: ' + ', '.join(names)); finish(2)
runs = os.path.join(a.workdir, 'runs')
if cr is None:
    if a.mode == 'restore':
        res = sorted(glob.glob(os.path.join(runs, a.ns + '-restore-*', 'cr-recreate.json')), reverse=True)
        if res:
            item('cr', 'WARN', 'CR 不存在；发现上次中断的恢复记录 %s，可用 oneshot_restore.sh 续跑' % os.path.dirname(res[0]))
            fact('resume_dir', os.path.dirname(res[0])); finish(0)
    item('cr', 'FAIL', 'NS %s 中没有%sMilvus CR（现有: %s）。本 skill 只处理 milvus-operator 部署的 Milvus' % (a.ns, (' 名为 %s 的 ' % a.name) if a.name else '', ', '.join(names) or '无')); finish(3)

name = cr['metadata']['name']; spec = cr.get('spec', {}); st = cr.get('status', {}) or {}
comp = spec.get('components', {}) or {}; deps = spec.get('dependencies', {}) or {}
mode = spec.get('mode', 'standalone')
img = comp.get('image', ''); status_img = st.get('currentImage', '') or ''
_src_chosen, _ = upaths.discover_source(img, status_img, [])
cur_img = (_src_chosen or {}).get('image') or status_img or img
src_ver = (_src_chosen or {}).get('version') or ver_full(cur_img)
fact('cr', name); fact('cr_mode', mode); fact('current_image', img); fact('status_current_image', status_img)
fact('current_version', (src_ver['tag'].lstrip('v') if isinstance(src_ver, dict) and src_ver.get('tag') else vs(ver(img))))
fact('source_discovery', (_src_chosen or {}).get('source', 'none'))
has_mixcoord = bool(comp.get('mixCoord'))
fact('has_mixcoord', 'true' if has_mixcoord else 'false')
item('cr', 'PASS', '%s/%s (%s)' % (a.ns, name, mode))

# 4b. 鉴权 / RBAC：开启鉴权时必须提供 root/admin 凭据（备份与恢复 RBAC 都要它）
def read_token(var, fvar):
    """凭据只来自环境变量；<VAR>_FILE 指向用户自己创建的 600/400 权限文件（第一行 user:password）。返回 (token, 问题说明)"""
    t = os.environ.get(var, '')
    if t:
        return t, ''
    f = os.environ.get(fvar, '')
    if not f:
        return '', ''
    try:
        mode_ = stat.S_IMODE(os.stat(f).st_mode)
        if mode_ & 0o077:
            return '', '%s 权限为 %o：必须是 600 或 400（chmod 600）' % (f, mode_)
        with open(f) as _tf:
            return _tf.readline().strip(), ''
    except OSError as e:
        return '', '%s 不可读: %s' % (f, e.strerror)

auth_on = str((((spec.get('config') or {}).get('common') or {}).get('security') or {}).get('authorizationEnabled', False)).lower() == 'true'
fact('auth_enabled', 'true' if auth_on else 'false')
tok, tok_issue = read_token('MILVUS_TOKEN', 'MILVUS_TOKEN_FILE')
if auth_on:
    if ':' not in tok:
        item('milvus_token', 'FAIL', tok_issue or 'Milvus 开启了鉴权（authorizationEnabled=true）：需要 root/admin 凭据——在 master 的环境变量 MILVUS_TOKEN=user:password 或 MILVUS_TOKEN_FILE=<600 权限文件> 提供（备份/恢复 RBAC 需要读写用户、角色、授权）。凭据只能由用户在自己的终端里设置，不要发到聊天里')
    else:
        # 只读验证：临时 port-forward 到 Milvus，用 REST 检查该账号能否读取全部 RBAC（不创建任何对象）
        sock = socket.socket(); sock.bind(('127.0.0.1', 0)); lport = sock.getsockname()[1]; sock.close()
        pf = subprocess.Popen(['kubectl', '--kubeconfig', KC, '-n', a.ns, 'port-forward', '--address', '127.0.0.1', 'svc/%s-milvus' % name, '%d:19530' % lport],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            ok_pf = False
            for _ in range(30):
                time.sleep(0.5)
                try:
                    socket.create_connection(('127.0.0.1', lport), timeout=1).close(); ok_pf = True; break
                except OSError:
                    if pf.poll() is not None:
                        break
            if not ok_pf:
                item('milvus_token', 'WARN', '已提供 MILVUS_TOKEN（用户 %s），但无法 port-forward 到 Milvus，未能验证管理员权限（正式运行会在改动前再验证）' % tok.split(':', 1)[0])
            else:
                env = dict(os.environ, MILVUS_TOKEN=tok)
                p = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'probe.py'), 'rbac-check', '--endpoint', 'http://127.0.0.1:%d' % lport],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, env=env, timeout=120)
                msg = (p.stdout.strip().splitlines() or [''])[-1]
                if p.returncode == 0:
                    item('milvus_token', 'PASS', msg)
                elif '无法访问' in msg:
                    item('milvus_token', 'WARN', '未能验证管理员权限：' + msg[:160])
                else:
                    item('milvus_token', 'FAIL', msg[:240] + '。备份/恢复 RBAC 需要 root 或带 admin 角色的账号；未做任何变更')
        finally:
            pf.terminate()
    if a.rbac_test:
        tt, tt_issue = read_token('MILVUS_TEST_TOKEN', 'MILVUS_TEST_TOKEN_FILE')
        item('rbac_test_token', 'PASS' if ':' in tt else 'FAIL', ('应用用户 %s（--rbac-test）' % tt.split(':', 1)[0]) if ':' in tt else (tt_issue or '--rbac-test 需要 MILVUS_TEST_TOKEN=user:password（或 MILVUS_TEST_TOKEN_FILE）'))
else:
    item('auth', 'INFO', '未开启鉴权（authorizationEnabled=false）；备份仍带 --rbac' + ('；--rbac-test 在未开启鉴权的实例上无意义' if a.rbac_test else ''))

# 5. 状态
status = st.get('status', '')
conds = {c.get('type'): c.get('status') for c in st.get('conditions', []) or []}
upd = conds.get('MilvusUpdated', '')
paused = str(comp.get('paused', False)).lower()
fact('status', status); fact('milvus_updated', upd); fact('paused', paused)
if a.mode == 'upgrade':
    item('health', 'PASS' if status == 'Healthy' and upd == 'True' else 'FAIL', 'status=%s MilvusUpdated=%s' % (status, upd))
    item('paused', 'PASS' if paused != 'true' else 'FAIL', 'paused=%s' % paused)
else:
    item('health', 'INFO', 'status=%s MilvusUpdated=%s（恢复不要求当前实例健康）' % (status, upd))

# 6. operator
opver = cr['metadata'].get('labels', {}).get('milvus.io/operator-version', '')
sel = 'app.kubernetes.io/name=milvus-operator'
rc, out, _ = (k('-n', a.operator_ns, 'get', 'deploy', '-l', sel, '-o', 'json') if a.operator_ns else k('get', 'deploy', '-A', '-l', sel, '-o', 'json'))
opimg = opns = ''
if rc == 0:
    its = json.loads(out).get('items', [])
    if its:
        opns = its[0]['metadata']['namespace']; opimg = its[0]['spec']['template']['spec']['containers'][0]['image']
fact('operator_version', opver); fact('operator_namespace', opns); fact('operator_image', opimg)
item('operator', 'PASS' if opver else 'WARN', 'operator %s（%s %s）；已验证 1.3.12' % (opver or '?', opns or '?', opimg or '?'))

# 7. 依赖与 MQ
mq = deps.get('msgStreamType') or 'rocksmq'
ext = [d for d in ('etcd', 'storage', 'pulsar', 'kafka') if (deps.get(d) or {}).get('external')]
excl = (((deps.get('rocksmq') or {}).get('persistence') or {}).get('persistentVolumeClaim') or {}).get('existingClaim', '')
fact('mq', mq); fact('external_deps', ','.join(ext)); fact('rocksmq_existing_claim', excl)
if a.mode == 'upgrade':
    item('dependencies', 'INFO', 'MQ=%s 外部依赖=%s。升级只改 Milvus 镜像，etcd/MinIO/MQ 及其镜像不动' % (mq, ','.join(ext) or '无'))
else:
    ok = not ext and not excl
    item('dependencies', 'PASS' if ok else 'FAIL', 'MQ=%s 外部依赖=%s existingClaim=%s%s' % (mq, ','.join(ext) or '无', excl or '无', '' if ok else '（不支持一键恢复，需人工）'))

# 8. Pod 就绪
rc, out, _ = k('-n', a.ns, 'get', 'pods', '-o', 'json')
pods = json.loads(out).get('items', []) if rc == 0 else []
inst = re.compile(r'^(%s|%s-etcd|%s-minio|%s-pulsar|%s-kafka)$' % ((re.escape(name),) * 5))
mine = [p for p in pods if inst.match((p['metadata'].get('labels') or {}).get('app.kubernetes.io/instance', '') or (p['metadata'].get('labels') or {}).get('release', ''))]
notready = [p['metadata']['name'] for p in mine if not all(c.get('ready') for c in (p.get('status', {}).get('containerStatuses') or [{}]))]
nodes = sorted({p['spec'].get('nodeName', '') for p in mine if (p['metadata'].get('labels') or {}).get('app.kubernetes.io/instance') == name})
fact('pods', len(mine)); fact('milvus_nodes', ','.join(nodes))
item('pods_ready', ('PASS' if not notready else ('FAIL' if a.mode == 'upgrade' else 'INFO')), ('%d 个 Pod 全部 Ready' % len(mine)) if not notready else ('未 Ready: ' + ' '.join(notready)))
# 用 Pod 镜像补全源版本（CR/status 解析失败时）
_pod_imgs = []
for _p in mine:
    if (_p['metadata'].get('labels') or {}).get('app.kubernetes.io/instance') != name:
        continue
    for _c in ((_p.get('spec') or {}).get('containers') or []):
        if _c.get('image'):
            _pod_imgs.append(_c['image'])
_src2, _ = upaths.discover_source(img, status_img, _pod_imgs)
if _src2:
    cur_img = _src2['image']; src_ver = _src2['version']
    fact('current_image_resolved', cur_img)
    fact('current_version', src_ver['tag'].lstrip('v'))
    fact('source_discovery', _src2['source'])

# 9. Service / NodePort
rc, out, _ = k('-n', a.ns, 'get', 'svc', '-l', 'app.kubernetes.io/instance=' + name, '-o', 'json')
svcs = json.loads(out).get('items', []) if rc == 0 else []
svc = next((s for s in svcs if s['metadata']['name'] == name + '-milvus'), svcs[0] if svcs else None)
if svc:
    stype = svc['spec'].get('type', '')
    ports = ' '.join('%s=%s:%s' % (p.get('name', ''), p.get('port'), p.get('nodePort', '-')) for p in svc['spec'].get('ports', []))
    crst = ((comp.get('proxy') if mode == 'cluster' else comp.get('standalone')) or {}).get('serviceType', '') or 'ClusterIP'
    fact('service', svc['metadata']['name']); fact('service_type', stype); fact('service_ports', ports); fact('cr_service_type', crst)
    if stype == crst:
        item('service', 'PASS', '%s %s %s（与 CR serviceType 一致）' % (svc['metadata']['name'], stype, ports))
    else:
        item('service', 'WARN', '%s 实际 %s，CR serviceType=%s：升级时会先把 CR 固定为 %s 并保持 nodePort（防漂移）' % (svc['metadata']['name'], stype, crst, stype))
else:
    item('service', 'FAIL', '找不到 %s 的 Service' % name)

# 10. imagePullSecrets / securityContext
ips = ','.join(s.get('name', '') for s in (comp.get('imagePullSecrets') or []))
fact('image_pull_secrets', ips)
sc = comp.get('securityContext') or {}
fact('security_context', json.dumps(sc, sort_keys=True))
item('image_pull_secrets', 'INFO', ips or '无（公开仓库或节点已登录）')
item('run_as_root', 'INFO', '当前 securityContext=%s。与官方文档的差异：官方只 patch spec.components.image；本 skill 额外设置 runAsUser=0（root），'
     '因为 2.6 写入的 rocksmq/缓存文件属主是 root，3.0 镜像默认非 root 会 CrashLoop（Permission denied）。策略不允许 root 时不要升级，先由管理员 chown PVC' % (json.dumps(sc) if sc else '{}'))

# 11. milvus-backup（前置条件 0.6.1，skill 不携带、不下载；缺失时状态 MISSING（不算 FAIL），打印官方下载链接与期望 sha256）
MARCH = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(os.uname()[4], os.uname()[4])
MB_VER = '0.6.1'
MB_REL = 'https://github.com/zilliztech/milvus-backup/releases/tag/v%s' % MB_VER
MB_URL = 'https://github.com/zilliztech/milvus-backup/releases/download/v%s/milvus-backup_%s_Linux_%s.tar.gz' % (MB_VER, MB_VER, MARCH)
KNOWN = {}  # sha256 -> 名称（scripts/milvus-backup-sha256.txt，随 scripts 一起传到 master）
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'milvus-backup-sha256.txt'), encoding='utf-8') as _shaf:
        for ln in _shaf:
            f2 = ln.split()
            if len(f2) == 2 and not ln.startswith('#') and re.match(r'^[0-9a-f]{64}$', f2[0]):
                KNOWN[f2[0]] = f2[1]
except Exception:
    pass
EXP_TGZ = next((h for h, n in KNOWN.items() if n == 'milvus-backup_%s_Linux_%s.tar.gz' % (MB_VER, MARCH)), '')
EXP_BIN = next((h for h, n in KNOWN.items() if n == 'milvus-backup_%s_Linux_%s/milvus-backup' % (MB_VER, MARCH)), '')

def bin_arch(path):  # ELF e_machine: 62=x86_64, 183=aarch64；非 ELF 返回 ''
    try:
        with open(path, 'rb') as f:
            h = f.read(20)
    except Exception:
        return ''
    if len(h) < 20 or h[:4] != b'\x7fELF':
        return ''
    em = int.from_bytes(h[18:20], 'little' if h[5:6] == b'\x01' else 'big')
    return {62: 'x86_64', 183: 'arm64'}.get(em, 'em%d' % em)

def sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    try:
        with open(path, 'rb') as f:
            for b in iter(lambda: f.read(1 << 20), b''):
                h.update(b)
        return h.hexdigest()
    except Exception:
        return ''

cands = [a.backup_bin, os.path.join(a.workdir, 'milvus-backup'), '/root/milvus-backup/milvus-backup', '/usr/local/bin/milvus-backup', shutil.which('milvus-backup') or '']
cands += sorted(glob.glob(os.path.join(a.workdir, 'milvus-backup_*_Linux_*.tar.gz'))) + sorted(glob.glob('/root/milvus-backup_*_Linux_*.tar.gz'))
found = ''; bver = ''; wrong = []
if a.backup_bin and not os.path.exists(a.backup_bin):
    wrong.append('%s(不存在)' % a.backup_bin)
for c in cands:
    if not c:
        continue
    if os.path.isdir(c):
        c = os.path.join(c, 'milvus-backup')
    if not os.path.isfile(c):
        continue
    if c.endswith('.tar.gz') or c.endswith('.tgz'):
        m = re.search(r'_Linux_(x86_64|amd64|arm64|aarch64)\.t', c)
        kn = KNOWN.get(sha256_file(c), '')
        mk = re.search(r'_Linux_(x86_64|arm64)', kn)
        ca = mk.group(1) if mk else (MARCH if not m else {'amd64': 'x86_64', 'aarch64': 'arm64'}.get(m.group(1), m.group(1)))
        if ca != MARCH:
            wrong.append('%s(%s，架构不符)' % (c, ca)); continue
        found = c; break
    if not os.access(c, os.X_OK):
        wrong.append('%s(无执行权限，需 chmod +x)' % c); continue
    ca = bin_arch(c)
    if ca and ca != MARCH:
        wrong.append('%s(%s，架构不符)' % (c, ca)); continue
    try:
        p = subprocess.run([c, '--help'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=15, cwd='/')
        _m = re.search(r'\bv?(\d+\.\d+\.\d+\S*)', (p.stdout.strip().splitlines() or [''])[0])
        bver = _m.group(1) if _m else '?'
        if p.returncode != 0:
            wrong.append('%s(--help 失败)' % c); continue
    except Exception as e:
        wrong.append('%s(无法运行:%s)' % (c, type(e).__name__)); continue
    found = c; break
fact('milvus_backup', found)
fact('milvus_backup_version', bver)
fact('master_arch', MARCH)
BACKUP_MISSING = not found
if found:
    fsha = sha256_file(found)
    fact('milvus_backup_file_sha256', fsha)
    item('milvus_backup', 'PASS', found + ((' (%s)' % bver) if bver else '') + (('；忽略不可用: ' + ' '.join(wrong)) if wrong else ''))
    if fsha in KNOWN:
        item('milvus_backup_sha256', 'PASS', 'sha256 与官方 %s 一致（%s）' % (MB_VER, KNOWN[fsha]))
    else:
        item('milvus_backup_sha256', 'WARN', '%s 的 sha256=%s 不在已知 %s 清单中（版本 %s）：本 skill 只验证过 %s，需用户确认后才能继续' % (found, fsha or '?', MB_VER, bver or '?', MB_VER))
elif MARCH not in ('x86_64', 'arm64'):
    item('milvus_backup', 'MISSING', 'master 上未找到 milvus-backup')
    item('milvus_backup_arch', 'FAIL', 'master 架构 %s 不受支持：milvus-backup 官方 Linux 包只有 x86_64 / arm64' % MARCH)
    BACKUP_MISSING = False
else:
    fact('milvus_backup_required_version', MB_VER)
    fact('milvus_backup_url', MB_URL)
    fact('milvus_backup_release_page', MB_REL)
    fact('milvus_backup_sha256', EXP_TGZ)
    fact('milvus_backup_bin_sha256', EXP_BIN)
    item('milvus_backup', 'MISSING', '前置条件未满足：master（%s）上未找到可用的 milvus-backup %s%s。请用户自行下载 %s（sha256 %s），'
         '然后 (a) 放到 master 的 %s/（tarball 或解出的 milvus-backup 二进制，需可执行），或 (b) 下载到用户本机并告知本地路径。agent 不会代为下载'
         % (MARCH, MB_VER, ('（不可用: ' + ' '.join(wrong) + '）') if wrong else '', MB_URL, EXP_TGZ or '?', a.workdir.rstrip('/')))
    print('PREREQ milvus-backup %s 未找到（master 架构 %s）' % (MB_VER, MARCH))
    print('PREREQ 官方下载: %s' % MB_URL)
    print('PREREQ sha256(tarball): %s' % (EXP_TGZ or '?'))
    print('PREREQ sha256(解出的二进制 milvus-backup): %s' % (EXP_BIN or '?'))
    print('PREREQ 放置方式 (a): 放到 master 的 %s/（tarball 原名 或 二进制 milvus-backup，chmod +x），或 master 其他路径（运行时加 --backup-bin <路径>）' % a.workdir.rstrip('/'))
    print('PREREQ 放置方式 (b): 下载到用户本机，告知本地路径，由 scripts/install_backup.sh <master> --from <本地路径> 校验并传到 master')
    if not KNOWN:
        print('PREREQ 警告: 找不到 scripts/milvus-backup-sha256.txt，无法给出期望 sha256（skill 不完整）')

# 12. 磁盘
d = a.workdir
while not os.path.isdir(d):
    d = os.path.dirname(d) or '/'
s = os.statvfs(d); avail = s.f_bavail * s.f_frsize
fact('disk_path', d); fact('disk_avail_bytes', avail)
item('disk', 'PASS' if avail >= 2 * 1024 ** 3 else 'FAIL', '%s 可用 %.1f GiB（导出备份需 ≈ 备份大小×1.2+1GiB，运行时按实际备份大小复核）' % (d, avail / 1024.0 ** 3))

# 13. 锁
lk = os.path.join(a.workdir, '.lock-' + a.ns); busy = False
if os.path.exists(lk):
    with open(lk) as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); fcntl.flock(f, fcntl.LOCK_UN)
        except OSError:
            busy = True
item('lock', 'FAIL' if busy else 'PASS', ('同一 NS 已有升级/恢复在运行（%s）' % lk) if busy else '无正在运行的升级/恢复')

# 版本路径（官方文档；见 references/upgrade-paths.md + scripts/upgrade_paths.py）
repo = upaths.repo_of(img or cur_img)
src_ver = src_ver or ver_full(cur_img or img)
cv = ver(cur_img or img)  # GA tuple or None
policy = upaths.load_policy()
pins = policy['pins']
if a.mode == 'upgrade':
    # 源版本硬门槛
    if not src_ver:
        item('version_source', 'WARN', '无法从 CR/status/pods 解析当前版本（image=%s）' % (cur_img or img))
    else:
        sb = upaths.is_blocked_source(src_ver)
        if sb:
            item('version_source', 'FAIL', sb + ' 文档: ' + policy['docs']['cluster_2_5_to_2_6'])
        else:
            item('version_source', 'PASS', '源 %s（发现自 %s）' % (src_ver['tag'], dict(FACTS).get('source_discovery', '?')))

    # 列出合法终点（两端对等：停在 2.6.x 或升到 GA 3.0.y）
    if src_ver and not upaths.is_blocked_source(src_ver):
        opts, _ob = upaths.list_options(src_ver, repo=repo or 'milvusdb/milvus', mode=mode, policy=policy)
        # 每个候选终点按真实路径展开 hops，只读检查每一跳镜像在当前仓库/镜像源里是否存在
        _opt_imgs = {}
        for o_ in opts:
            try:
                _pl = upaths.plan_hops(src_ver, o_['version'], mode=mode, has_mixcoord=has_mixcoord,
                                       operator_ver=opver or opimg, policy=policy)
                _hops = [h['tag'] for h in _pl['hops']] or [o_['tag']]
            except Exception:
                _hops = [o_['tag']]
            o_['hops'] = _hops
            _opt_imgs[o_['tag']] = ['%s:%s' % (repo or 'milvusdb/milvus', t_) for t_ in _hops]
        _all_imgs = []
        for _l in _opt_imgs.values():
            for _i in _l:
                if _i not in _all_imgs:
                    _all_imgs.append(_i)
        _res = regchk.check_many(_all_imgs) if _all_imgs else {}
        for _i in sorted(_all_imgs, key=lambda x: (upaths.parse_version(x) or {'tuple': (0, 0, 0)})['tuple']):
            print(regchk.fmt_line(_i, _res[_i]))
        _st = {}
        _missing = {}
        for t_, _l in _opt_imgs.items():
            _st[t_] = regchk.worst(_res[_i][0] for _i in _l)
            _missing[t_] = [_i for _i in _l if _res[_i][0] == 'absent']
        _hops_by_tag = dict((o_['tag'], o_['hops']) for o_ in opts)
        opts, _unavail = upaths.apply_availability(opts, _st)
        for g in upaths.group_summary(opts, _unavail):
            print('TARGET_GROUP kind=%s available=%d unavailable=%d recommended=%s newest=%s oldest=%s' % (
                g['kind'], g['available'], g['unavailable'], g['recommended'], g['newest'], g['oldest']))
        for o_ in opts:
            print('TARGET_OPTION kind=%s tag=%s image=%s recommended=%s pull=%s hops=%s order=%d label=%s' % (
                o_['kind'], o_['tag'], o_['image'], 'yes' if o_['recommended'] else 'no', o_['pull'],
                ','.join(_hops_by_tag.get(o_['tag']) or [o_['tag']]), o_['order'],
                o_['label'].replace(' ', '_')))
        for o_ in _unavail:
            print('TARGET_UNAVAILABLE kind=%s tag=%s image=%s reason=image_not_found missing=%s' % (
                o_['kind'], o_['tag'], o_['image'], ','.join(_missing.get(o_['tag']) or [o_['image']])))
        fact('target_options', len(opts))
        fact('target_unavailable', ','.join(o_['tag'] for o_ in _unavail) or '-')
        _n_un = sum(1 for v_ in _res.values() if v_[0] == 'unverified')
        if _unavail:
            item('image_registry', 'INFO', '仓库 %s 中不存在、已从选项中隐藏：%s' % (repo, ','.join(o_['tag'] for o_ in _unavail)))
        if _n_un:
            _why = sorted(set(v_[2].split(';')[0] for v_ in _res.values() if v_[0] == 'unverified'))
            item('image_registry', 'WARN', '%d 个镜像无法确认是否存在（%s）；标记 pull=unverified，正式运行的节点拉取检查会再验证' % (_n_un, ','.join(_why)[:200]))
        elif _all_imgs and not _unavail:
            item('image_registry', 'PASS', '仓库 %s 中全部 %d 个候选镜像均存在' % (repo, len(_all_imgs)))
        # 默认推荐建议（供兼容旧 SUGGEST 行）：优先推荐 3.0，否则推荐 2.6
        rec = next((o_ for o_ in opts if o_['recommended'] and o_['kind'] == '3.0'), None) \
            or next((o_ for o_ in opts if o_['recommended']), None) \
            or (opts[0] if opts else None)
        if rec:
            print('SUGGEST target_image=%s' % rec['image'])
            print('SUGGEST official_image=milvusdb/milvus:%s' % rec['tag'])
            fact('suggested_target_image', rec['image'])
            fact('official_target_image', 'milvusdb/milvus:%s' % rec['tag'])

    # 若用户已选定目标：校验 + 展开 hops
    tgt = a.target_image or ((repo + ':' + a.target_tag) if a.target_tag else '')
    if tgt:
        tv_full = ver_full(tgt)
        tv = ver(tgt)
        fact('requested_target_image', tgt)
        print('SUGGEST target_image=%s' % tgt)
        print('SUGGEST official_image=milvusdb/milvus:%s' % (tgt.rsplit(':', 1)[-1]))
        tb = upaths.is_blocked_target(tv_full) if tv_full else '无法解析目标版本: ' + tgt
        if tv_full and not tb:
            _known = ['v' + t_ for t_ in upaths.ga_list(policy, '2_6') + upaths.ga_list(policy, '3_0')]
            if tv_full['tag'] not in _known:
                print('PATH_WARN 目标 %s 不在 skill 已知的 GA 列表中（upgrade_paths.json ga_2_6/ga_3_0）；仅在镜像可拉取时允许继续' % tv_full['tag'])
                item('version_target_known', 'WARN', '目标 %s 不在已知 GA 列表' % tv_full['tag'])
        already = (cur_img == tgt and status == 'Healthy')
        if tb:
            _dref = policy['docs'].get('cluster_2_6_to_3_0', '')
            print('PATH_BLOCK %s 参见 %s' % (tb, _dref))
            print('PATH_PLAN final=%s hops= BLOCKED' % (tv_full['tag'] if tv_full else tgt))
            item('version_target', 'FAIL', '%s 参见 %s' % (tb, _dref))
        elif already:
            # 已是目标镜像且 Healthy：正式运行进入 ALREADY 模式只做校验，不展开 hops，也不按“同版本”阻断
            item('version_path', 'INFO', '已是目标 %s：不展开 hops（ALREADY，只做校验）' % tgt.rsplit(':', 1)[-1])
        elif not src_ver:
            item('version_path', 'WARN', '有目标但源版本未解析，跳过路径展开')
        else:
            plan = upaths.plan_hops(
                src_ver, tv_full, mode=mode, has_mixcoord=has_mixcoord,
                operator_ver=opver or opimg, policy=policy)
            for w in plan['warns']:
                print('PATH_WARN %s' % w)
                item('version_path_warn', 'WARN', w[:240])
            for i_ in plan['infos']:
                print('PATH_INFO %s' % i_)
            for b in plan['blocks']:
                print('PATH_BLOCK %s' % b)
            if plan['blocks']:
                item('version_path', 'FAIL', plan['blocks'][0][:300])
            else:
                tags = []
                for i_, h in enumerate(plan['hops'], 1):
                    tags.append(h['tag'])
                    print('HOP index=%d tag=%s enable_mixcoord=%d require_operator_ge=%s apply_mode=%s note=%s' % (
                        i_, h['tag'], 1 if h['enable_mixcoord'] else 0,
                        h.get('require_operator_ge') or '-', h['apply_mode'],
                        (h.get('note') or '').replace('\n', ' ')[:200]))
                print('PATH_PLAN final=%s hops=%s' % (plan['final'], ','.join(tags)))
                fact('path_hops', ','.join(tags))
                # 每一跳镜像都必须能从用户配置的仓库/镜像源拉到（只读 manifest HEAD，不拉镜像）
                _trepo = upaths.repo_of(tgt)
                _himgs = ['%s:%s' % (_trepo, t_) for t_ in tags] or [tgt]
                _hres = regchk.check_many(_himgs)
                for _i in _himgs:
                    print(regchk.fmt_line(_i, _hres[_i]))
                _abs = [_i for _i in _himgs if _hres[_i][0] == 'absent']
                _unv = [_i for _i in _himgs if _hres[_i][0] == 'unverified']
                if _abs:
                    item('target_image_pull', 'FAIL', '镜像仓库中不存在：%s（换一个仓库里存在的 tag，或先把镜像同步到该仓库）' % ','.join(_abs))
                elif _unv:
                    item('target_image_pull', 'WARN', '无法确认镜像是否存在（%s）：%s；正式运行会在节点上做拉取检查，拉不到即中止' % (
                        _hres[_unv[0]][2][:120], ','.join(_unv)))
                else:
                    item('target_image_pull', 'PASS', '全部 %d 跳镜像在仓库中存在：%s' % (len(_himgs), ','.join(_himgs)))
                item('version_path', 'PASS', '%s → %s via %s' % (src_ver['tag'], plan['final'], ','.join(tags) or '(none)'))
                # 软提示：2.6.x < verified 已在 WARN；cluster→3.0 完整 CR
                if any(h['apply_mode'] == 'cluster_full_cr' for h in plan['hops']):
                    item('cluster_apply', 'INFO',
                         '目标含 3.0 Cluster：文档要求完整 CR apply（显式 indexNode.replicas=0），'
                         '不要只用缺字段的 image-only merge。本 skill 会按现有 CR 拓扑生成 apply；'
                         '若组件与官方模板差异较大请先非生产验证。文档: ' + policy['docs']['cluster_2_6_to_3_0'])
            if cur_img == tgt and status == 'Healthy':
                item('target', 'INFO', '已是目标镜像 %s，正式运行将只做校验（ALREADY）' % tgt)
            elif tv and cv:
                item('target', 'PASS' if tv > cv else 'FAIL', '%s → %s%s' % (vs(cv), vs(tv), '' if tv > cv else '（不支持降级/同版本）'))
            elif tv_full and src_ver:
                item('target', 'PASS', '%s → %s' % (src_ver['tag'], tv_full['tag']))
    else:
        item('version_target', 'INFO', '未指定最终目标：请用 TARGET_OPTION 选项框选择终点（停在 2.6.x 或升到 GA 3.0.y），两端对等')

    # 源 <2.5.16：不阻断「选终点」，但会在 plan 里插入 2.5.16 hop；这里 INFO
    if src_ver and src_ver['channel'] == 'ga' and src_ver['tuple'] < (2, 5, 16):
        item('version_bridge', 'INFO', '源 <2.5.16：正式路径会先跳到 %s（+Cluster mixCoord），见官方 2.5→2.6 文档' % pins['bridge_2_5_with_mixcoord'])

    item('image_pull', 'INFO', '只读模式不建 Pod（仓库存在性见 IMAGE_CHECK / target_image_pull）；正式运行会在 Milvus 所在节点（%s）做拉取检查' % (','.join(nodes) or '?'))
else:
    metas = []
    for f in sorted(glob.glob(os.path.join(runs, a.ns + '-[0-9]*', 'backup.meta')), reverse=True):
        m = {}
        with open(f) as _mf:
            for ln in _mf:
                if '=' in ln:
                    kk, vv = ln.rstrip('\n').split('=', 1); m[kk] = vv
        if m.get('CR') != name:
            continue
        ed = m.get('EXPORT_DIR', '')
        man = os.path.join(ed, 'MANIFEST') if ed else ''
        nobj = 0
        if man and os.path.isfile(man):
            with open(man) as _manf:
                nobj = sum(1 for _ in _manf)
        # 备份是否含 RBAC 元数据（读本地导出的 full_meta.json / backup_meta.json，只统计数量，不输出内容）
        rb = 'unknown'
        # milvus-backup 0.6.x 的 rbac_meta 只在 full_meta.json 里；旧版本在 backup_meta.json
        bm = ''
        for f_ in ('full_meta.json', 'backup_meta.json'):
            p_ = os.path.join(ed, 'backup', m.get('BACKUP_NAME', ''), 'meta', f_) if ed else ''
            if p_ and os.path.isfile(p_):
                bm = p_; break
        if bm:
            try:
                with open(bm) as _bmf:
                    r_ = json.load(_bmf).get('rbac_meta') or {}
                rb = 'yes' if any(r_.get(x_) for x_ in ('users', 'roles', 'grants', 'privilege_groups')) else 'no'
            except Exception:
                rb = 'unknown'
        m['_rbac'] = rb
        metas.append(m)
        print('BACKUP index=%d name=%s source_image=%s target_image=%s export=%s objects=%d probe=%s rbac=%s meta=%s' % (
            len(metas), m.get('BACKUP_NAME', ''), m.get('SOURCE_IMAGE', ''), m.get('TARGET_IMAGE', ''), ed or '-', nobj, m.get('PROBE_COLLECTION', '') or '-', rb, f))
    fact('backups', len(metas))
    sel = metas[0] if metas else None
    if metas and a.backup:
        sel = next((m for m in metas if m.get('BACKUP_NAME') == a.backup), None)
        if sel is None:
            item('backup', 'WARN', '指定的备份 %s 在 %s 下没有本 CR 的 backup.meta 记录；正式运行会从 MinIO 取该备份，并在删除任何东西之前检查 RBAC 元数据' % (a.backup, runs))
    which = '指定备份' if a.backup else '最近备份'
    if sel:
        b = sel
        print('SUGGEST restore_image=%s' % b.get('SOURCE_IMAGE', ''))
        print('SUGGEST backup=%s' % b.get('BACKUP_NAME', ''))
        ok = bool(b.get('EXPORT_DIR')) and os.path.isfile(os.path.join(b['EXPORT_DIR'], 'MANIFEST'))
        item('backup', 'PASS' if ok else 'WARN', '%s %s（升级前镜像 %s）%s' % (which, b.get('BACKUP_NAME'), b.get('SOURCE_IMAGE'),
             '，master 本地导出副本可用' if ok else '，无本地导出副本：恢复时会先从当前 MinIO 导出，MinIO 数据已损坏则无法恢复'))
    elif not metas:
        item('backup', 'WARN', '%s 下没有本 CR 的升级备份记录(backup.meta)；恢复时将使用当前 MinIO 中最新的 pre_upgrade_* 备份，恢复镜像需人工指定' % runs)
    if sel and auth_on and sel['_rbac'] == 'unknown':
        item('backup_rbac', 'WARN', '实例开启了鉴权，但无法确认%s %s 是否含 RBAC（没有本地导出副本）；正式运行会在删除任何东西之前检查，备份不含 RBAC 时退出 5 并要求选择' % (which, sel.get('BACKUP_NAME', '')))
    elif sel and auth_on and sel['_rbac'] != 'yes':
        print('RBAC_DECISION_NEEDED backup=%s rbac=%s' % (sel.get('BACKUP_NAME', ''), sel['_rbac']))
        item('backup_rbac', 'WARN', '实例开启了鉴权，但%s %s 不含 RBAC 元数据（rbac=%s）：恢复只能恢复数据，用户/角色/授权丢失，结果为部分恢复（退出码 14）。需用户选择“仅恢复数据（--accept-rbac-loss）/取消”，不加 --accept-rbac-loss 时正式运行会在删除任何东西之前退出 5' % (which, sel.get('BACKUP_NAME', ''), sel['_rbac']))
    elif sel and sel['_rbac'] == 'yes':
        item('backup_rbac', 'PASS', '%s %s 含 RBAC 元数据' % (which, sel.get('BACKUP_NAME', '')))
    item('restore_impact', 'INFO', '恢复会删除 %s/%s 当前实例及其 etcd/MinIO/PVC 数据，备份点之后的数据全部丢失' % (a.ns, name))

fails = [n for n, s_, _ in ITEMS if s_ == 'FAIL']
if not fails and BACKUP_MISSING:
    print('NEEDS install_backup')
    finish(4)
finish(5 if fails else 0)
