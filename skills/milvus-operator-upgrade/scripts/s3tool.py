#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S3/MinIO 小工具（仅标准库，SigV4，兼容 Python 3.6+）。凭据文件：第一行 AK，第二行 SK。
  s3tool.py ls   <endpoint> <bucket> <prefix> <cred>                -> OBJECTS=<n> BYTES=<n>
  s3tool.py pull <endpoint> <bucket> <prefix> <cred> <local_dir>    把 prefix 下所有对象下载到 local_dir/<key>，写 local_dir/MANIFEST
  s3tool.py push <endpoint> <bucket> <prefix> <cred> <local_dir>    按 local_dir/MANIFEST 把对象上传回 bucket（key 不变；桶不存在则创建）
  s3tool.py verify - - <prefix> - <local_dir>                       只校验本地副本（MANIFEST 中 prefix 下对象的大小与 sha256）
  s3tool.py rbacmeta <endpoint|-> <bucket|-> <prefix> <cred|-> [local_dir]   读备份 meta/backup_meta.json 的 rbac_meta，只打印数量：RBAC_META present=yes|no users= roles= grants= groups=（无 local_dir 时读 MinIO；不输出密码哈希）
MANIFEST 每行: <size> <sha256> <key>。出错退出 3。"""
import datetime, hashlib, hmac, json, os, re, sys
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

REGION = os.environ.get('S3_REGION', 'us-east-1')


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


class S3(object):
    def __init__(self, ep, bucket, credf):
        self.ep = ep.rstrip('/'); self.bucket = bucket; self.host = urlparse(ep).netloc
        self.ak, self.sk = [l.strip() for l in open(credf).read().splitlines()[:2]]

    def req(self, method, key='', params=None, body=b'', timeout=300):
        params = params or {}
        qs = '&'.join('%s=%s' % (quote(k, safe='-_.~'), quote(v, safe='-_.~')) for k, v in sorted(params.items()))
        path = '/' + quote(self.bucket) + ('/' + quote(key, safe='/-_.~') if key else '')
        now = datetime.datetime.utcnow()
        amz, day = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
        ph = hashlib.sha256(body).hexdigest()
        canon = '\n'.join([method, path, qs, 'host:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n' % (self.host, ph, amz),
                           'host;x-amz-content-sha256;x-amz-date', ph])
        scope = '%s/%s/s3/aws4_request' % (day, REGION)
        sts = '\n'.join(['AWS4-HMAC-SHA256', amz, scope, hashlib.sha256(canon.encode()).hexdigest()])
        k = _sign(_sign(_sign(_sign(('AWS4' + self.sk).encode(), day), REGION), 's3'), 'aws4_request')
        sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
        r = Request(self.ep + path + ('?' + qs if qs else ''), data=body if method == 'PUT' else None, method=method)
        r.add_header('x-amz-date', amz); r.add_header('x-amz-content-sha256', ph)
        r.add_header('Authorization', 'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s'
                     % (self.ak, scope, sig))
        return urlopen(r, timeout=timeout)

    def list(self, prefix):
        out, token = [], None
        while True:
            p = {'list-type': '2', 'prefix': prefix, 'max-keys': '1000'}
            if token:
                p['continuation-token'] = token
            body = self.req('GET', params=p).read().decode()
            for blk in re.findall(r'<Contents>(.*?)</Contents>', body, re.S):
                key = re.search(r'<Key>(.*?)</Key>', blk, re.S).group(1)
                key = key.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"').replace('&apos;', "'")
                out.append((key, int(re.search(r'<Size>(\d+)</Size>', blk).group(1))))
            m = re.search(r'<NextContinuationToken>([^<]+)</NextContinuationToken>', body)
            if '<IsTruncated>true</IsTruncated>' in body and m:
                token = m.group(1)
            else:
                return out


def read_manifest(local, prefix, check=True):
    items = []
    for line in open(os.path.join(local, 'MANIFEST')).read().splitlines():
        if not line.strip():
            continue
        size, sha, key = line.split(' ', 2)
        if not key.startswith(prefix):
            continue
        if check:
            h = hashlib.sha256(); n = 0
            with open(os.path.join(local, key), 'rb') as f:
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    h.update(b); n += len(b)
            if n != int(size) or h.hexdigest() != sha:
                raise RuntimeError('本地文件校验失败: %s' % key)
        items.append((key, int(size)))
    if not items:
        raise RuntimeError('MANIFEST 中没有 %s 下的对象' % prefix)
    return items


def rbac_summary(raw):
    """backup_meta.json 里的 rbac_meta（milvus-backup --rbac 写入）：只输出数量，不输出任何内容（含密码哈希）。"""
    m = json.loads(raw.decode('utf-8')).get('rbac_meta') or {}
    n = lambda k: len(m.get(k) or [])
    if n('users') + n('roles') + n('grants') + n('privilege_groups') == 0:
        return 'RBAC_META present=no users=0 roles=0 grants=0 groups=0'
    return 'RBAC_META present=yes users=%d roles=%d grants=%d groups=%d' % (n('users'), n('roles'), n('grants'), n('privilege_groups'))


def main():
    cmd, ep, bucket, prefix, credf = sys.argv[1:6]
    if cmd == 'rbacmeta':
        # rbacmeta <endpoint|-> <bucket|-> <backup/NAME/> <cred|-> [本地导出目录]：有本地目录时读本地 <dir>/<prefix>meta/backup_meta.json，否则读 MinIO
        key = prefix.rstrip('/') + '/meta/backup_meta.json'
        if len(sys.argv) > 6:
            path = os.path.join(os.path.abspath(sys.argv[6]), key)
            if not os.path.isfile(path):
                print('RBAC_META present=unknown (没有 %s)' % key); return 3
            print(rbac_summary(open(path, 'rb').read())); return 0
        with S3(ep, bucket, credf).req('GET', key) as r:
            print(rbac_summary(r.read())); return 0
    if cmd == 'verify':
        items = read_manifest(os.path.abspath(sys.argv[6]), prefix)
        print('VERIFIED OBJECTS=%d BYTES=%d' % (len(items), sum(s for _, s in items))); return 0
    s3 = S3(ep, bucket, credf)
    if cmd == 'ls':
        objs = s3.list(prefix)
        print('OBJECTS=%d BYTES=%d' % (len(objs), sum(s for _, s in objs))); return 0
    local = os.path.abspath(sys.argv[6])
    if cmd == 'pull':
        objs = s3.list(prefix)
        if not objs:
            raise RuntimeError('前缀 %s 下没有对象' % prefix)
        lines, total = [], 0
        for key, size in objs:
            dst = os.path.join(local, key)
            if not os.path.abspath(dst).startswith(local + os.sep):
                raise RuntimeError('非法 key: %s' % key)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            h = hashlib.sha256(); n = 0
            with s3.req('GET', key) as r, open(dst, 'wb') as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b); h.update(b); n += len(b)
            if n != size:
                raise RuntimeError('%s 大小不符 %d != %d' % (key, n, size))
            lines.append('%d %s %s' % (size, h.hexdigest(), key)); total += size
        with open(os.path.join(local, 'MANIFEST'), 'w') as f:
            f.write('\n'.join(lines) + '\n')
        print('PULLED OBJECTS=%d BYTES=%d' % (len(lines), total)); return 0
    if cmd == 'push':
        items = read_manifest(local, prefix, check=False)
        try:
            s3.req('PUT').read()          # 建桶；已存在时返回 409，忽略
        except Exception as e:
            if getattr(e, 'code', None) != 409:
                raise
        n = total = 0
        for key, size in items:
            data = open(os.path.join(local, key), 'rb').read()   # 单对象读入内存（备份对象为分段 binlog/元数据）
            if len(data) != size:
                raise RuntimeError('本地文件大小不符: %s' % key)
            s3.req('PUT', key, body=data).read()
            n += 1; total += len(data)
        got = dict(s3.list(prefix))
        if len(got) < n:
            raise RuntimeError('上传后对象数 %d < %d' % (len(got), n))
        print('PUSHED OBJECTS=%d BYTES=%d' % (n, total)); return 0
    raise RuntimeError('未知命令 %s' % cmd)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print('S3TOOL ERROR: %s' % e); sys.exit(3)
