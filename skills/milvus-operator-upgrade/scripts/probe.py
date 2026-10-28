#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Milvus 业务探针（仅标准库，兼容 Python 3.6+），经 RESTful v2（与 gRPC 同端口，默认 19530）访问。
pre : 记录行数、取一行向量（存入 --state，600 权限）、记录 top-k 主键
post: 等待集合可查询后重新统计，并用同一向量检索，与 pre（默认同目录 probe_pre.json，或 --pre 指定）比较
load: 加载集合（--collection '*' 表示全部集合）并等待 Loaded，打印每个集合行数
count: 打印集合行数（需已加载）
RBAC（开启鉴权时；用户/角色/授权，均不含也不打印密码或密码哈希）:
rbac-check   : 校验 MILVUS_TOKEN 具备管理员能力（可列用户/角色并读取各角色授权），否则退出 3
rbac-login   : 打印当前可用凭据 LOGIN token|default_root|none（新实例恢复后 root 密码是默认 Milvus，见 rbac-fixroot）
rbac-snapshot: 把 用户、角色、用户-角色绑定、授权、权限组 写入 --out（600 权限 JSON）
rbac-compare : 重新取快照与 --pre 比较（等待最多 --wait 秒），一致 0，不一致 14，访问出错 3；--out 保存新快照
rbac-fixroot : 若 MILVUS_TOKEN 用户是 root 且恢复后 root 仍是默认密码 Milvus，则用 update_password 改回 MILVUS_TOKEN 里的密码
rbac-authtest: 可选：用 MILVUS_TEST_TOKEN（自定义应用用户）验证 允许的操作成功 / 禁止的操作被拒（退出 14 表示不符）
可选环境变量 MILVUS_TOKEN（如 "user:password"，开启鉴权时需要）。
退出码: 0 一致 / 9 不一致 / 14 RBAC 不一致 / 3 访问出错
"""
import argparse, json, os, sys, time
try:
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError
except ImportError:  # pragma: no cover
    sys.exit(3)
DEFAULT_ROOT = 'root:Milvus'
BUILTIN_GROUPS = {'%s%s' % (a, b) for a in ('Cluster', 'Database', 'Collection') for b in ('ReadOnly', 'ReadWrite', 'Admin')}


class ApiError(RuntimeError):
    def __init__(self, path, code, message):
        RuntimeError.__init__(self, '%s -> code=%s message=%s' % (path, code, message))
        self.code = code
        self.message = str(message or '')

    def kind(self):   # auth=凭据错误 / denied=已认证但无权限 / other
        m = self.message.lower()
        if 'auth check failure' in m or 'password' in m or 'unauthenticated' in m or 'token' in m or 'authenticat' in m:
            return 'auth'
        if 'permission' in m or 'privilege' in m or 'not permitted' in m or 'forbidden' in m:
            return 'denied'
        return 'other'


def call(ep, path, body, timeout=30, token=None):
    req = Request(ep.rstrip('/') + path, data=json.dumps(body).encode(), method='POST')
    req.add_header('Content-Type', 'application/json')
    tok = token if token is not None else os.environ.get('MILVUS_TOKEN')
    if tok:
        req.add_header('Authorization', 'Bearer ' + tok)
    try:
        with urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode())
    except HTTPError as e:   # 401/403 等也带 JSON 体
        try:
            d = json.loads(e.read().decode())
        except Exception:
            raise ApiError(path, 'http%s' % e.code, e.reason)
    if d.get('code', 0) != 0:
        raise ApiError(path, d.get('code'), d.get('message'))
    return d.get('data')


def describe(ep, c):
    d = call(ep, '/v2/vectordb/collections/describe', {'collectionName': c})
    pk = vec = None
    for f in d.get('fields', []):
        if f.get('primaryKey'):
            pk = f['name']
        if f.get('type') == 'FloatVector' and vec is None:
            vec = f['name']
    return d, pk, vec


def count(ep, c):
    d = call(ep, '/v2/vectordb/entities/query', {'collectionName': c, 'filter': '', 'outputFields': ['count(*)']})
    return int(d[0]['count(*)'])


def search(ep, c, vec_field, pk, v, k):
    d = call(ep, '/v2/vectordb/entities/search',
             {'collectionName': c, 'data': [v], 'annsField': vec_field, 'limit': k, 'outputFields': [pk]})
    return [row.get(pk, row.get('id')) for row in d]


def snapshot(ep, c, k, state=None):
    d, pk, vec = describe(ep, c)
    out = {'collection': c, 'load': d.get('load'), 'pk': pk, 'vector_field': vec, 'count': count(ep, c)}
    if vec:
        if state is None:
            row = call(ep, '/v2/vectordb/entities/query',
                       {'collectionName': c, 'filter': '', 'limit': 1, 'outputFields': [pk, vec]})[0]
            state = {'pk': row[pk], 'vector': row[vec]}
        out['query_pk'] = state['pk']
        out['topk'] = search(ep, c, vec, pk, state['vector'], k)
    return out, state


def load_all(ep, coll, wait):
    names = call(ep, '/v2/vectordb/collections/list', {}) if coll == '*' else [coll]
    if not names:
        print('LOAD: 没有集合'); return 3
    rc = 0
    for c in names:
        deadline, last = time.time() + wait, None
        while True:
            try:
                call(ep, '/v2/vectordb/collections/load', {'collectionName': c}, timeout=120)
                st = call(ep, '/v2/vectordb/collections/get_load_state', {'collectionName': c})
                if st.get('loadState') == 'LoadStateLoaded':
                    print('LOADED %s count=%d' % (c, count(ep, c))); break
                last = st
            except Exception as e:
                last = e
            if time.time() > deadline:
                print('LOAD ERROR %s（%ss）: %s' % (c, wait, last)); rc = 3; break
            time.sleep(5)
    return rc


# ---------------- RBAC ----------------
def rbac_snapshot(ep, token=None):
    """用户 / 角色 / 绑定 / 授权 / 权限组。REST 不返回密码，快照里没有密码或哈希。"""
    users = {}
    for u in call(ep, '/v2/vectordb/users/list', {}, token=token) or []:
        d = call(ep, '/v2/vectordb/users/describe', {'userName': u}, token=token) or []
        # 2.6/3.0 RESTful v2 的 users/describe 返回角色名列表（data: ["role", ...]）；兼容返回 {"roles": [...]} 的写法
        rl = d.get('roles') if isinstance(d, dict) else d
        users[u] = sorted(x if isinstance(x, str) else (x.get('roleName') or x.get('name') or '') for x in (rl or []))
    roles = sorted(call(ep, '/v2/vectordb/roles/list', {}, token=token) or [])
    grants = set()
    for r in roles:
        for g in call(ep, '/v2/vectordb/roles/describe', {'roleName': r}, token=token) or []:
            grants.add((r, g.get('objectType', ''), g.get('objectName', ''), g.get('privilege', ''), g.get('dbName', '')))
    groups = {}
    try:
        pg = call(ep, '/v2/vectordb/privilege_groups/list', {}, token=token) or []
    except ApiError:
        pg = []   # 旧版本没有权限组接口
    # 2.6/3.0 返回 data: {"privilegeGroups": [{"privilegeGroupName": .., "privileges": "A,B,C"}]}；privileges 也可能是列表
    if isinstance(pg, dict):
        pg = pg.get('privilegeGroups') or []
    for g in pg:
        if not isinstance(g, dict):
            continue
        name = g.get('privilegeGroupName') or g.get('groupName') or ''
        if name in BUILTIN_GROUPS:
            continue   # 内置权限组由 Milvus 版本定义（升级后可能增加权限），不属于用户 RBAC，不备份也不比较
        pv = g.get('privileges') or []
        if isinstance(pv, str):
            pv = [x.strip() for x in pv.split(',') if x.strip()]
        groups[name] = sorted(x if isinstance(x, str) else (x.get('name') or '') for x in pv)
    return {'users': users, 'roles': roles, 'grants': sorted(list(x) for x in grants), 'privilege_groups': groups}


def rbac_counts(s):
    return 'users=%d roles=%d grants=%d bindings=%d groups=%d' % (
        len(s['users']), len(s['roles']), len(s['grants']), sum(len(v) for v in s['users'].values()), len(s['privilege_groups']))


def rbac_diff(pre, post):
    """返回差异描述列表（只含名字，不含密码）。"""
    diff = []
    for u in sorted(set(pre['users']) | set(post['users'])):
        if u not in post['users']:
            diff.append('缺少用户 %s' % u)
        elif u not in pre['users']:
            diff.append('多出用户 %s' % u)
        elif pre['users'][u] != post['users'][u]:
            diff.append('用户 %s 的角色 %s -> %s' % (u, pre['users'][u], post['users'][u]))
    for r in sorted(set(pre['roles']) ^ set(post['roles'])):
        diff.append('%s角色 %s' % ('缺少' if r in pre['roles'] else '多出', r))
    a = set(map(tuple, pre['grants'])); b = set(map(tuple, post['grants']))
    for g in sorted(a - b):
        diff.append('缺少授权 %s' % '/'.join(g))
    for g in sorted(b - a):
        diff.append('多出授权 %s' % '/'.join(g))
    for g in sorted(set(pre['privilege_groups']) | set(post['privilege_groups'])):
        if pre['privilege_groups'].get(g) != post['privilege_groups'].get(g):
            diff.append('权限组 %s 不一致' % g)
    return diff


def write_private(path, obj):
    old = os.umask(0o077)
    try:
        with open(path, 'w') as f:
            json.dump(obj, f, ensure_ascii=False, sort_keys=True)
    finally:
        os.umask(old)


def rbac_check(ep):
    tok = os.environ.get('MILVUS_TOKEN', '')
    if ':' not in tok:
        print('RBAC CHECK FAIL: 开启鉴权需要环境变量 MILVUS_TOKEN=user:password（或 MILVUS_TOKEN_FILE）'); return 3
    try:
        s = rbac_snapshot(ep)
    except ApiError as e:
        k = e.kind()
        why = {'denied': '该账号没有管理员权限（需 root 或带 admin 角色，才能读取用户/角色/授权，恢复时也要写入它们）',
               'auth': '用户名或密码错误（或鉴权未通过）'}.get(k, '访问失败')
        print('RBAC CHECK FAIL: %s：%s' % (why, e.message[:160])); return 3
    except Exception as e:
        print('RBAC CHECK FAIL: 无法访问 Milvus: %s' % e); return 3
    print('RBAC CHECK OK: %s 账号 %s 可读取全部 RBAC（%s）' % ('管理员', tok.split(':', 1)[0], rbac_counts(s)))
    return 0


def try_login(ep, token):
    try:
        call(ep, '/v2/vectordb/users/list', {}, token=token); return True
    except Exception:
        return False


def rbac_login(ep):
    tok = os.environ.get('MILVUS_TOKEN', '')
    if tok and try_login(ep, tok):
        print('LOGIN token'); return 0
    if try_login(ep, DEFAULT_ROOT):
        print('LOGIN default_root'); return 0
    print('LOGIN none'); return 3


def rbac_fixroot(ep):
    """恢复后 root 密码是新实例默认值（milvus-backup 不覆盖已存在的用户）。"""
    tok = os.environ.get('MILVUS_TOKEN', '')
    if ':' not in tok:
        print('RBAC FIXROOT SKIP: 没有 MILVUS_TOKEN'); return 0
    user, pw = tok.split(':', 1)
    if try_login(ep, tok):
        if user != 'root' and try_login(ep, DEFAULT_ROOT):
            print('RBAC FIXROOT WARN: root 仍是默认密码 Milvus（备份不含 root 密码，milvus-backup 不覆盖已存在用户）；请管理员自行改 root 密码')
        else:
            print('RBAC FIXROOT OK: MILVUS_TOKEN 可用')
        return 0
    if user == 'root' and try_login(ep, DEFAULT_ROOT):
        try:
            call(ep, '/v2/vectordb/users/update_password', {'userName': 'root', 'password': 'Milvus', 'newPassword': pw}, token=DEFAULT_ROOT)
        except Exception as e:
            print('RBAC FIXROOT FAIL: 改 root 密码失败: %s' % e); return 3
        if try_login(ep, tok):
            print('RBAC FIXROOT OK: root 恢复后是默认密码，已按 MILVUS_TOKEN 改回（备份不含 root 密码）'); return 0
    print('RBAC FIXROOT FAIL: MILVUS_TOKEN 与默认 root 凭据都无法登录'); return 3


def rbac_authtest(ep, coll, deny):
    tt = os.environ.get('MILVUS_TEST_TOKEN', '')
    if ':' not in tt:
        print('RBAC AUTHTEST ERROR: 需要环境变量 MILVUS_TEST_TOKEN=user:password（或 MILVUS_TEST_TOKEN_FILE）'); return 3
    if not coll:
        print('RBAC AUTHTEST ERROR: 需要 --collection（该用户应有查询权限的集合）'); return 3
    user = tt.split(':', 1)[0]
    problems = []
    try:
        n = int(call(ep, '/v2/vectordb/entities/query', {'collectionName': coll, 'filter': '', 'outputFields': ['count(*)']}, token=tt)[0]['count(*)'])
        allowed = 'query(%s)=%d' % (coll, n)
    except ApiError as e:
        allowed = 'query(%s)=%s' % (coll, e.kind()); problems.append('允许的操作 query %s 失败（%s）：%s' % (coll, e.kind(), e.message[:120]))
    except Exception as e:
        allowed = 'query(%s)=error' % coll; problems.append('允许的操作 query %s 出错: %s' % (coll, e))
    denied = []
    for op in [x for x in deny.split(',') if x]:
        if op == 'list_users':
            path, body = '/v2/vectordb/users/list', {}
        elif op == 'create_collection':
            path, body = '/v2/vectordb/collections/create', {'collectionName': '_rbac_deny_probe', 'dimension': 2}
        else:
            problems.append('未知的禁止操作 %s（支持 list_users, create_collection）' % op); continue
        try:
            call(ep, path, body, token=tt)
            problems.append('禁止的操作 %s 竟然成功（用户 %s 权限过大）' % (op, user)); denied.append(op + '=ALLOWED')
            if op == 'create_collection':   # 清理探针集合（用管理员 token）
                try:
                    call(ep, '/v2/vectordb/collections/drop', {'collectionName': '_rbac_deny_probe'})
                except Exception:
                    pass
        except ApiError as e:
            if e.kind() == 'denied':
                denied.append(op + '=denied')
            else:
                denied.append(op + '=' + e.kind()); problems.append('禁止的操作 %s 的失败原因不是权限拒绝（%s）：%s' % (op, e.kind(), e.message[:120]))
        except Exception as e:
            denied.append(op + '=error'); problems.append('禁止的操作 %s 出错: %s' % (op, e))
    print('RBAC AUTHTEST %s: user=%s allowed=%s denied=[%s]' % ('FAIL' if problems else 'PASS', user, allowed, ','.join(denied)))
    for p in problems:
        print('RBAC AUTHTEST DETAIL: ' + p)
    return 14 if problems else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['pre', 'post', 'load', 'count', 'rbac-check', 'rbac-login', 'rbac-snapshot',
                                     'rbac-compare', 'rbac-fixroot', 'rbac-authtest'])
    ap.add_argument('--endpoint', required=True)
    ap.add_argument('--collection', default='')
    ap.add_argument('--deny', default='list_users')
    ap.add_argument('--state')
    ap.add_argument('--out')
    ap.add_argument('--pre')
    ap.add_argument('--topk', type=int, default=5)
    ap.add_argument('--wait', type=int, default=300)
    a = ap.parse_args()
    if a.mode == 'rbac-check':
        return rbac_check(a.endpoint)
    if a.mode == 'rbac-login':
        return rbac_login(a.endpoint)
    if a.mode == 'rbac-fixroot':
        return rbac_fixroot(a.endpoint)
    if a.mode == 'rbac-authtest':
        return rbac_authtest(a.endpoint, a.collection, a.deny)
    if a.mode == 'rbac-snapshot':
        if not a.out:
            ap.error('rbac-snapshot 需要 --out')
        try:
            s = rbac_snapshot(a.endpoint)
        except Exception as e:
            print('RBAC SNAPSHOT ERROR: %s' % e); return 3
        write_private(a.out, s)
        print('RBAC SNAPSHOT: %s' % rbac_counts(s)); return 0
    if a.mode == 'rbac-compare':
        if not a.pre:
            ap.error('rbac-compare 需要 --pre（升级/备份前的 rbac 快照）')
        pre = json.load(open(a.pre))
        deadline, last = time.time() + a.wait, None
        while True:
            try:
                post = rbac_snapshot(a.endpoint); break
            except Exception as e:
                last = e
                if time.time() > deadline:
                    print('RBAC COMPARE ERROR（等待 %ss 后仍不可读取）: %s' % (a.wait, last)); return 3
                time.sleep(5)
        if a.out:
            write_private(a.out, post)
        diff = rbac_diff(pre, post)
        if diff:
            print('RBAC MISMATCH: 前 [%s] 后 [%s]' % (rbac_counts(pre), rbac_counts(post)))
            for d in diff[:40]:
                print('RBAC DIFF: ' + d)
            return 14
        print('RBAC MATCH: %s' % rbac_counts(post)); return 0
    if not a.collection:
        ap.error('需要 --collection')
    if a.mode == 'load':
        return load_all(a.endpoint, a.collection, a.wait)
    if a.mode == 'count':
        try:
            print('COUNT %s=%d' % (a.collection, count(a.endpoint, a.collection))); return 0
        except Exception as e:
            print('COUNT %s ERROR: %s' % (a.collection, e)); return 3
    if not a.state or not a.out:
        ap.error('pre/post 需要 --state 与 --out')
    if a.mode == 'pre':
        try:
            out, state = snapshot(a.endpoint, a.collection, a.topk)
        except Exception as e:
            print('PROBE ERROR: %s' % e); return 3
        old = os.umask(0o077)
        with open(a.state, 'w') as f:
            json.dump(state, f)
        os.umask(old)
        json.dump(out, open(a.out, 'w'), ensure_ascii=False)
        print('PROBE PRE: ' + json.dumps(out, ensure_ascii=False))
        return 0
    pre_path = a.pre or a.out.replace('probe_post', 'probe_pre')
    pre = json.load(open(pre_path))
    state = json.load(open(a.state)) if os.path.exists(a.state) else None
    deadline, last = time.time() + a.wait, None
    while True:
        try:
            out, _ = snapshot(a.endpoint, a.collection, a.topk, state)
            break
        except Exception as e:
            last = e
            if time.time() > deadline:
                print('PROBE ERROR（等待 %ss 后仍不可查询）: %s' % (a.wait, last)); return 3
            time.sleep(10)
    json.dump(out, open(a.out, 'w'), ensure_ascii=False)
    print('PROBE POST: ' + json.dumps(out, ensure_ascii=False))
    ok, note = verdict(a.endpoint, a.collection, pre, out, state)
    print('PROBE %s: count %s -> %s, top%d %s -> %s%s' % ('MATCH' if ok else 'MISMATCH', pre['count'], out['count'],
                                                       a.topk, pre.get('topk'), out.get('topk'), note))
    return 0 if ok else 9


def verdict(ep, c, pre, out, state):
    """行数必须一致。top-k 完全一致 = MATCH。HNSW 等 ANN 索引是近似检索：恢复时 --rebuild_index 重建的图与原图不同，
    top-k 的成员/顺序可能变化（实测 5000 行 HNSW：[0,4693,1937,1411,3887] -> [0,4693,1937,3887,560]，两者都不是精确结果）。
    因此 top-k 不完全一致时改用确定性校验：探针行（query_pk）的向量与 pre 记录逐值一致、top-1 一致、top-k 重叠 >= 60%。"""
    if out['count'] != pre['count']:
        return False, ''
    a, b = pre.get('topk'), out.get('topk')
    if a == b:
        return True, ''
    if not a or not b or not state or 'vector' not in state:
        return False, ''
    k = len(a); ov = len(set(a) & set(b)); need = -(-k * 3 // 5)
    try:
        pk = out.get('pk') or pre.get('pk'); vf = out.get('vector_field') or pre.get('vector_field')
        flt = '%s == %s' % (pk, json.dumps(state['pk']))
        row = call(ep, '/v2/vectordb/entities/query', {'collectionName': c, 'filter': flt, 'limit': 1, 'outputFields': [pk, vf]})
        same_vec = bool(row) and len(row[0][vf]) == len(state['vector']) and \
            all(abs(float(x) - float(y)) <= 1e-6 * max(1.0, abs(float(y))) for x, y in zip(row[0][vf], state['vector']))
    except Exception as e:
        return False, '（ANN 近似校验出错: %s）' % e
    ok = same_vec and a[0] == b[0] and ov >= need
    return ok, '（top-k 不完全一致；ANN 近似校验：探针行 %s=%s 的向量%s，top-1 %s，重叠 %d/%d，要求 >= %d）' % (
        pk, state['pk'], '逐值一致' if same_vec else '不一致', '一致' if a[0] == b[0] else '不一致', ov, k, need)


if __name__ == '__main__':
    sys.exit(main())
