#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只读检查镜像 tag 在仓库/镜像源里是否存在（不拉镜像、不下载 layer、不读凭据文件）。

兼容 Python 3.6（master 系统自带）。

  python3 registry_check.py check IMG [IMG ...]   # 每个镜像一行 IMAGE_CHECK
  python3 registry_check.py selftest              # 分类器单元测试（全部用 mock，不联网）

判定顺序：
 1. registry v2 API：HEAD /v2/<repo>/manifests/<tag>（只取 manifest 头，不拉 layer）。
    401 + Bearer 挑战 → 匿名 token（Aliyun ACR 公开仓库 / Docker Hub 公开仓库）→ 再 HEAD。
    200 → present；404 → absent；
    401/403（私有仓库需凭据）、429/5xx、网络不通、超时 → unverified（不判死）。
 2. API 结果为 unverified 时，若 master 上有工具，再用只读方式确认：
    docker manifest inspect / skopeo inspect --raw（远端 manifest，使用这些工具自己的登录态，脚本不读凭据），
    crictl inspecti / ctr images ls（仅本地缓存存在 → present，via=local:*）。
 3. 都不能确定 → unverified（预检给 WARN，不是 FAIL；正式运行的拉取检查 Pod 会再验证）。

输出：IMAGE_CHECK image=<img> status=present|absent|unverified via=<方式> detail=<无空格说明>
环境变量：MILVUS_REGISTRY_CHECK=0 关闭检查（全部 unverified via=disabled）；
          MILVUS_REGISTRY_TIMEOUT=秒（单请求超时，默认 8）。
"""
from __future__ import print_function
import json, os, re, shutil, subprocess, sys, threading

try:
    import urllib.request as _ureq
    import urllib.error as _uerr
    import urllib.parse as _uparse
except ImportError:  # pragma: no cover
    _ureq = _uerr = _uparse = None

PRESENT, ABSENT, UNVERIFIED = 'present', 'absent', 'unverified'
DOCKER_HUB = 'registry-1.docker.io'
ACCEPT = ', '.join([
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.docker.distribution.manifest.v2+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v1+prettyjws',
])


class NetError(Exception):
    """网络层失败（DNS、连接拒绝、超时、TLS）。"""


# ---------- 镜像引用解析 ----------
def parse_ref(image):
    """'milvusdb/milvus:v2.6.25' → ('registry-1.docker.io', 'milvusdb/milvus', 'v2.6.25')。
    返回 None 表示无法解析。"""
    if not image or re.search(r'\s', image):
        return None
    ref = 'latest'
    name = image
    if '@' in name:
        name, ref = name.split('@', 1)
    else:
        last = name.rsplit('/', 1)[-1]
        if ':' in last:
            name, ref = name.rsplit(':', 1)
    parts = name.split('/')
    if len(parts) > 1 and ('.' in parts[0] or ':' in parts[0] or parts[0] == 'localhost'):
        reg, repo = parts[0], '/'.join(parts[1:])
    else:
        reg, repo = DOCKER_HUB, name
    if reg in ('docker.io', 'index.docker.io'):
        reg = DOCKER_HUB
    if reg == DOCKER_HUB and '/' not in repo:
        repo = 'library/' + repo
    if not repo or not ref:
        return None
    return reg, repo, ref


def parse_challenge(h):
    """'Bearer realm="…",service="…",scope="…"' → ('bearer', {realm,service,scope})"""
    if not h:
        return '', {}
    m = re.match(r'\s*(\w+)\s*(.*)$', h)
    if not m:
        return '', {}
    scheme = m.group(1).lower()
    params = dict((k.lower(), v) for k, v in re.findall(r'(\w+)="([^"]*)"', m.group(2)))
    return scheme, params


# ---------- 默认 HTTP 实现（urllib；可被测试替换） ----------
class _NoRedirect(_ureq.HTTPRedirectHandler if _ureq else object):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # 跟随重定向但保留 HEAD
        new = _ureq.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)
        if new is not None and req.get_method() == 'HEAD':
            new = _ureq.Request(new.full_url, headers=dict(req.header_items()), method='HEAD')
        return new


def urllib_http(method, url, headers, timeout):
    """返回 (status:int, headers:dict(lower), body:bytes)；网络失败抛 NetError。"""
    req = _ureq.Request(url, headers=headers or {}, method=method)
    opener = _ureq.build_opener(_NoRedirect())
    try:
        r = opener.open(req, timeout=timeout)
        body = r.read(65536) if method != 'HEAD' else b''
        return r.getcode(), dict((k.lower(), v) for k, v in r.headers.items()), body
    except _uerr.HTTPError as e:
        try:
            body = e.read(65536)
        except Exception:
            body = b''
        return e.code, dict((k.lower(), v) for k, v in (e.headers or {}).items()), body
    except Exception as e:  # URLError, socket.timeout, ssl errors, ConnectionError …
        raise NetError('%s:%s' % (type(e).__name__, str(getattr(e, 'reason', e))[:80]))


# ---------- 分类器 ----------
def classify_status(code):
    if code == 200:
        return PRESENT
    if code == 404:
        return ABSENT
    return UNVERIFIED


class _TokenCache(object):
    def __init__(self):
        self.lock = threading.Lock()
        self.tok = {}

    def get(self, key):
        with self.lock:
            return self.tok.get(key)

    def put(self, key, v):
        with self.lock:
            self.tok[key] = v


def check_http(image, http=None, timeout=8, tokens=None):
    """只用 registry v2 API 判定。返回 (status, via, detail)。"""
    http = http or urllib_http
    tokens = tokens if tokens is not None else _TokenCache()
    pr = parse_ref(image)
    if not pr:
        return UNVERIFIED, 'parse', 'cannot_parse_image_ref'
    reg, repo, ref = pr
    url = 'https://%s/v2/%s/manifests/%s' % (reg, repo, ref)
    hdr = {'Accept': ACCEPT, 'User-Agent': 'milvus-operator-upgrade-precheck'}
    key = (reg, repo)
    tok = tokens.get(key)
    if tok:
        hdr['Authorization'] = 'Bearer ' + tok
    try:
        code, rh, _ = http('HEAD', url, hdr, timeout)
        if code == 401 and not tok:
            scheme, p = parse_challenge(rh.get('www-authenticate', ''))
            if scheme != 'bearer' or not p.get('realm'):
                return UNVERIFIED, 'registry_api', 'auth_required_%s' % (scheme or 'unknown')
            q = {}
            if p.get('service'):
                q['service'] = p['service']
            q['scope'] = p.get('scope') or ('repository:%s:pull' % repo)
            turl = p['realm'] + ('&' if '?' in p['realm'] else '?') + _uparse.urlencode(q)
            tcode, _, tbody = http('GET', turl, {'User-Agent': hdr['User-Agent']}, timeout)
            if tcode != 200:
                return UNVERIFIED, 'registry_api', 'anonymous_token_http_%d' % tcode
            try:
                d = json.loads(tbody.decode('utf-8', 'replace') or '{}')
            except ValueError:
                d = {}
            tok = d.get('token') or d.get('access_token') or ''
            if not tok:
                return UNVERIFIED, 'registry_api', 'anonymous_token_empty'
            tokens.put(key, tok)
            hdr['Authorization'] = 'Bearer ' + tok
            code, rh, _ = http('HEAD', url, hdr, timeout)
        st = classify_status(code)
        if st == UNVERIFIED:
            why = {401: 'auth_required(private_repo?)', 403: 'forbidden(private_repo?)', 429: 'rate_limited'}.get(code, 'http_%d' % code)
            return UNVERIFIED, 'registry_api', why
        return st, 'registry_api', 'http_%d' % code
    except NetError as e:
        return UNVERIFIED, 'registry_api', 'network:' + re.sub(r'\s+', '_', str(e))[:100]


def default_runner(argv, timeout):
    """返回 (rc, combined_output)；工具不存在返回 (None, '')。"""
    if not shutil.which(argv[0]):
        return None, ''
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout or ''
    except subprocess.TimeoutExpired:
        return 124, 'timeout'
    except Exception as e:
        return 125, type(e).__name__


_ABSENT_PAT = re.compile(r'(?i)(no such manifest|manifest unknown|manifest_unknown|not found: manifest|name unknown|name_unknown)')


def check_tools(image, runner=None, timeout=20):
    """只读工具兜底。返回 (status, via, detail) 或 None（没有能下结论的工具）。"""
    runner = runner or default_runner
    tried = []
    # 远端 manifest（只取 manifest，不拉 layer）
    for argv, via in ((['docker', 'manifest', 'inspect', image], 'docker_manifest_inspect'),
                      (['skopeo', 'inspect', '--raw', 'docker://' + image], 'skopeo_inspect')):
        rc, out = runner(argv, timeout)
        if rc is None:
            continue
        tried.append(via)
        if rc == 0:
            return PRESENT, via, 'manifest_ok'
        if _ABSENT_PAT.search(out or ''):
            return ABSENT, via, 'manifest_unknown'
    # 本地缓存（只能证明存在，不能证明不存在）
    rc, out = runner(['crictl', 'inspecti', image], timeout)
    if rc is not None:
        tried.append('crictl')
        if rc == 0:
            return PRESENT, 'local:crictl', 'cached_on_master'
    rc, out = runner(['ctr', '-n', 'k8s.io', 'images', 'ls', '-q', 'name==' + image], timeout)
    if rc is not None:
        tried.append('ctr')
        if rc == 0 and image in (out or '').split():
            return PRESENT, 'local:ctr', 'cached_on_master'
    if tried:
        return UNVERIFIED, 'tools', 'inconclusive:' + ','.join(tried)
    return None


def check_image(image, http=None, runner=None, timeout=8, tokens=None, use_tools=True):
    st, via, detail = check_http(image, http=http, timeout=timeout, tokens=tokens)
    if st != UNVERIFIED or not use_tools:
        return st, via, detail
    t = check_tools(image, runner=runner)
    if t is None:
        return st, via, detail
    if t[0] == UNVERIFIED:
        return UNVERIFIED, via, detail + ';' + t[2]
    return t


def check_many(images, http=None, runner=None, timeout=None, workers=6):
    """并发检查，返回 {image: (status, via, detail)}。同一 registry 网络不通时其余镜像不再逐个等超时。"""
    out = {}
    imgs = []
    for i in images:
        if i and i not in imgs:
            imgs.append(i)
    if os.environ.get('MILVUS_REGISTRY_CHECK', '1') == '0':
        for i in imgs:
            out[i] = (UNVERIFIED, 'disabled', 'MILVUS_REGISTRY_CHECK=0')
        return out
    if timeout is None:
        try:
            timeout = float(os.environ.get('MILVUS_REGISTRY_TIMEOUT', '8'))
        except ValueError:
            timeout = 8
    tokens = _TokenCache()
    by_reg = {}
    for i in imgs:
        pr = parse_ref(i)
        by_reg.setdefault(pr[0] if pr else '?', []).append(i)
    lock = threading.Lock()

    def one_registry(reg_imgs):
        # 先检查第一个镜像（同时拿到匿名 token），网络不通则其余直接走工具兜底/unverified
        first = reg_imgs[0]
        r0 = check_http(first, http=http, timeout=timeout, tokens=tokens)
        net_down = r0[0] == UNVERIFIED and r0[2].startswith('network:')
        auth_blocked = r0[0] == UNVERIFIED and not net_down
        results = {first: r0}
        rest = reg_imgs[1:]
        if not net_down and not auth_blocked and rest:
            sem = threading.Semaphore(workers)
            ths = []

            def run(img):
                with sem:
                    r = check_http(img, http=http, timeout=timeout, tokens=tokens)
                with lock:
                    results[img] = r
            for img in rest:
                t = threading.Thread(target=run, args=(img,))
                t.daemon = True
                ths.append(t); t.start()
            for t in ths:
                t.join()
        else:
            for img in rest:
                results[img] = r0[:2] + (r0[2] + ';same_as_first_image_of_registry',)
        # 工具兜底：只对 unverified；第一次工具也无法下结论则其余不再尝试
        tools_ok = True
        for img in reg_imgs:
            r = results[img]
            if r[0] != UNVERIFIED or not tools_ok:
                continue
            t = check_tools(img, runner=runner)
            if t is None or t[0] == UNVERIFIED:
                tools_ok = False
                if t is not None:
                    results[img] = (UNVERIFIED, r[1], r[2] + ';' + t[2])
                continue
            results[img] = t
        with lock:
            out.update(results)

    ths = []
    for reg, ri in by_reg.items():
        t = threading.Thread(target=one_registry, args=(ri,))
        t.daemon = True
        ths.append(t); t.start()
    for t in ths:
        t.join()
    return out


def worst(statuses):
    """多跳镜像合并：任一 absent → absent；否则任一 unverified → unverified；否则 present。"""
    s = list(statuses)
    if ABSENT in s:
        return ABSENT
    if UNVERIFIED in s or not s:
        return UNVERIFIED
    return PRESENT


def fmt_line(image, r):
    return 'IMAGE_CHECK image=%s status=%s via=%s detail=%s' % (image, r[0], r[1], re.sub(r'\s+', '_', r[2] or '-'))


# ---------- 单元测试（mock，不联网） ----------
class FakeRegistry(object):
    """模拟 Aliyun/Docker Hub 匿名 token 流程。"""
    def __init__(self, tags, private=False, net_down=False, token_code=200, challenge='bearer', codes=None):
        self.tags = set(tags); self.private = private; self.net_down = net_down
        self.token_code = token_code; self.challenge = challenge; self.codes = codes or {}
        self.calls = []

    def __call__(self, method, url, headers, timeout):
        self.calls.append((method, url, bool(headers.get('Authorization'))))
        if self.net_down:
            raise NetError('URLError:timed out')
        if '/auth' in url or 'token' in url.split('?')[0]:
            if self.token_code != 200:
                return self.token_code, {}, b''
            return 200, {}, json.dumps({'token': 'T0K'}).encode()
        tag = url.rsplit('/', 1)[-1]
        if tag in self.codes:
            return self.codes[tag], {}, b''
        if not headers.get('Authorization'):
            if self.challenge == 'bearer':
                ch = 'Bearer realm="https://dockerauth.example/auth",service="svc",scope="repository:x/milvus:pull"'
            else:
                ch = 'Basic realm="r"'
            return 401, {'www-authenticate': ch}, b''
        if self.private:
            return 401, {}, b''
        return (200 if tag in self.tags else 404), {}, b''


def selftest():
    fails = []

    def expect(c, m):
        if c:
            print('OK   %s' % m)
        else:
            fails.append(m); print('FAIL %s' % m)

    no_tools = lambda argv, t: (None, '')
    # parse_ref
    expect(parse_ref('milvusdb/milvus:v2.6.25') == (DOCKER_HUB, 'milvusdb/milvus', 'v2.6.25'), 'parse docker hub')
    expect(parse_ref('docker.io/milvusdb/milvus:v3.0.3') == (DOCKER_HUB, 'milvusdb/milvus', 'v3.0.3'), 'parse docker.io prefix')
    expect(parse_ref('busybox') == (DOCKER_HUB, 'library/busybox', 'latest'), 'parse library default tag')
    expect(parse_ref('registry.cn-hangzhou.aliyuncs.com/xy-zy/milvus:v2.6.10') ==
           ('registry.cn-hangzhou.aliyuncs.com', 'xy-zy/milvus', 'v2.6.10'), 'parse aliyun')
    expect(parse_ref('reg.local:5000/a/b:v1') == ('reg.local:5000', 'a/b', 'v1'), 'parse registry with port')
    expect(parse_ref('a/b@sha256:' + 'a' * 64)[2] == 'sha256:' + 'a' * 64, 'parse digest')
    expect(parse_ref('bad image') is None, 'parse rejects whitespace')
    sch, p = parse_challenge('Bearer realm="https://x/auth",service="s",scope="repository:a:pull"')
    expect(sch == 'bearer' and p['realm'] == 'https://x/auth' and p['service'] == 's', 'parse challenge')

    img = 'registry.cn-hangzhou.aliyuncs.com/xy-zy/milvus:%s'
    fr = FakeRegistry(['v2.6.10', 'v3.0.3'])
    expect(check_image(img % 'v2.6.10', http=fr, runner=no_tools)[0] == PRESENT, 'anon token → 200 present')
    expect(check_image(img % 'v3.0.4', http=fr, runner=no_tools)[0] == ABSENT, 'anon token → 404 absent')
    expect(any('/auth' in c[1] for c in fr.calls), 'token endpoint called')
    # token cache: second call in same cache reuses token
    tc = _TokenCache(); fr2 = FakeRegistry(['v1'])
    check_http(img % 'v1', http=fr2, tokens=tc); n = len(fr2.calls)
    check_http(img % 'v1', http=fr2, tokens=tc)
    expect(len(fr2.calls) - n == 1, 'token cached per repo')
    # private repo → unverified, not absent
    r = check_image(img % 'v2.6.10', http=FakeRegistry([], private=True), runner=no_tools)
    expect(r[0] == UNVERIFIED and 'auth' in r[2], 'private repo → unverified')
    # basic auth → unverified
    expect(check_image(img % 'v1', http=FakeRegistry(['v1'], challenge='basic'), runner=no_tools)[0] == UNVERIFIED, 'basic auth challenge → unverified')
    # network down → unverified
    r = check_image(img % 'v1', http=FakeRegistry(['v1'], net_down=True), runner=no_tools)
    expect(r[0] == UNVERIFIED and r[2].startswith('network:'), 'network down → unverified')
    # token endpoint failure → unverified
    expect(check_image(img % 'v1', http=FakeRegistry(['v1'], token_code=500), runner=no_tools)[0] == UNVERIFIED, 'token 500 → unverified')
    # 429 / 5xx → unverified
    expect(check_image(img % 'v1', http=FakeRegistry(['v1'], codes={'v1': 429}), runner=no_tools)[0] == UNVERIFIED, '429 → unverified')
    expect(check_image(img % 'v1', http=FakeRegistry(['v1'], codes={'v1': 503}), runner=no_tools)[0] == UNVERIFIED, '503 → unverified')
    # tools fallback
    def docker_ok(argv, t):
        return (0, '{}') if argv[0] == 'docker' else (None, '')
    def docker_absent(argv, t):
        return (1, 'no such manifest: x') if argv[0] == 'docker' else (None, '')
    def crictl_cached(argv, t):
        if argv[0] == 'docker':
            return (1, 'error: dial tcp timeout')
        if argv[0] == 'crictl':
            return (0, '{}')
        return (None, '')
    def all_inconclusive(argv, t):
        return (1, 'connection refused')
    down = FakeRegistry([], net_down=True)
    expect(check_image(img % 'v1', http=down, runner=docker_ok)[:2] == (PRESENT, 'docker_manifest_inspect'), 'fallback docker manifest inspect present')
    expect(check_image(img % 'v1', http=down, runner=docker_absent)[0] == ABSENT, 'fallback docker manifest unknown → absent')
    expect(check_image(img % 'v1', http=down, runner=crictl_cached)[1] == 'local:crictl', 'fallback crictl local cache → present')
    r = check_image(img % 'v1', http=down, runner=all_inconclusive)
    expect(r[0] == UNVERIFIED and 'inconclusive' in r[2], 'all tools inconclusive → unverified')
    # crictl missing locally does NOT mean absent
    def crictl_missing(argv, t):
        return (1, 'not found') if argv[0] == 'crictl' else (None, '')
    expect(check_image(img % 'v1', http=down, runner=crictl_missing)[0] == UNVERIFIED, 'local cache miss is not absent')
    # check_many: mixed + net-down short circuit
    res = check_many([img % 'v2.6.10', img % 'v3.0.4', img % 'v3.0.3', img % 'v2.6.10'], http=FakeRegistry(['v2.6.10', 'v3.0.3']), runner=no_tools, timeout=1)
    expect(len(res) == 3 and res[img % 'v3.0.4'][0] == ABSENT and res[img % 'v3.0.3'][0] == PRESENT, 'check_many mixed results (dedup)')
    dn = FakeRegistry([], net_down=True)
    res = check_many([img % 'a', img % 'b', img % 'c'], http=dn, runner=no_tools, timeout=1)
    expect(all(v[0] == UNVERIFIED for v in res.values()) and len(dn.calls) == 1, 'check_many net-down: one probe per registry')
    os.environ['MILVUS_REGISTRY_CHECK'] = '0'
    try:
        res = check_many([img % 'a'], http=FakeRegistry(['a']), runner=no_tools)
        expect(res[img % 'a'][1] == 'disabled', 'MILVUS_REGISTRY_CHECK=0 disables')
    finally:
        del os.environ['MILVUS_REGISTRY_CHECK']
    expect(worst([PRESENT, ABSENT, UNVERIFIED]) == ABSENT, 'worst: absent dominates')
    expect(worst([PRESENT, UNVERIFIED]) == UNVERIFIED, 'worst: unverified over present')
    expect(worst([PRESENT, PRESENT]) == PRESENT, 'worst: all present')
    if fails:
        print('SELFTEST fails=%d' % len(fails)); return 1
    print('SELFTEST ok'); return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__); return 2
    if argv[0] == 'selftest':
        return selftest()
    if argv[0] == 'check':
        imgs = argv[1:]
        if not imgs:
            print('usage: registry_check.py check IMG [IMG ...]'); return 2
        res = check_many(imgs)
        rc = 0
        for i in imgs:
            if i in res:
                print(fmt_line(i, res[i]))
                if res[i][0] == ABSENT:
                    rc = 3
        return rc
    print(__doc__); return 2


if __name__ == '__main__':
    sys.exit(main() or 0)
