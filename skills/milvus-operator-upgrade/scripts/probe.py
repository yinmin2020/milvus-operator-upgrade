#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Milvus 业务探针（仅标准库，兼容 Python 3.6+），经 RESTful v2（与 gRPC 同端口，默认 19530）访问。
pre : 记录行数、取一行向量（存入 --state，600 权限）、记录 top-k 主键
post: 等待集合可查询后重新统计，并用同一向量检索，与 pre（默认同目录 probe_pre.json，或 --pre 指定）比较
load: 加载集合（--collection '*' 表示全部集合）并等待 Loaded，打印每个集合行数
count: 打印集合行数（需已加载）
可选环境变量 MILVUS_TOKEN（如 "user:password"，开启鉴权时需要）。
退出码: 0 一致 / 9 不一致 / 3 访问出错
"""
import argparse, json, os, sys, time
try:
    from urllib.request import Request, urlopen
except ImportError:  # pragma: no cover
    sys.exit(3)


def call(ep, path, body, timeout=30):
    req = Request(ep.rstrip('/') + path, data=json.dumps(body).encode(), method='POST')
    req.add_header('Content-Type', 'application/json')
    tok = os.environ.get('MILVUS_TOKEN')
    if tok:
        req.add_header('Authorization', 'Bearer ' + tok)
    with urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read().decode())
    if d.get('code', 0) != 0:
        raise RuntimeError('%s -> code=%s message=%s' % (path, d.get('code'), d.get('message')))
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['pre', 'post', 'load', 'count'])
    ap.add_argument('--endpoint', required=True)
    ap.add_argument('--collection', required=True)
    ap.add_argument('--state')
    ap.add_argument('--out')
    ap.add_argument('--pre')
    ap.add_argument('--topk', type=int, default=5)
    ap.add_argument('--wait', type=int, default=300)
    a = ap.parse_args()
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
    ok = out['count'] == pre['count'] and out.get('topk') == pre.get('topk')
    print('PROBE %s: count %s -> %s, top%d %s -> %s' % ('MATCH' if ok else 'MISMATCH', pre['count'], out['count'],
                                                     a.topk, pre.get('topk'), out.get('topk')))
    return 0 if ok else 9


if __name__ == '__main__':
    sys.exit(main())
