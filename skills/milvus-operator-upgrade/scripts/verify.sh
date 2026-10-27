#!/usr/bin/env bash
# 用法: verify.sh <ns> <milvus-name> <svc_snapshot.txt> [target-image]
# 校验：Service type/nodePort 与快照完全一致；CR Healthy 且 MilvusUpdated=True；spec 与 status 镜像=目标；Milvus Pod 全部 Ready 且镜像=目标。
set -euo pipefail
NS=$1; NAME=$2; SNAP=$3; IMG=${4:-}
now=$("$(dirname "$0")/snapshot_svc.sh" "$NS" "$NAME")
if ! diff <(cat "$SNAP") <(echo "$now"); then
  echo "!!!!! VERIFY FAIL: Service type/nodePort 与升级前快照不一致 !!!!!" >&2; exit 1; fi
st=$(kubectl get milvus "$NAME" -n "$NS" -o jsonpath='{.status.status}')
[ "$st" = Healthy ] || { echo "VERIFY FAIL: CR status=$st" >&2; exit 1; }
upd=$(kubectl get milvus "$NAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="MilvusUpdated")].status}')
[ "$upd" = True ] || { echo "VERIFY FAIL: MilvusUpdated=$upd" >&2; exit 1; }
if [ -n "$IMG" ]; then
  cur=$(kubectl get milvus "$NAME" -n "$NS" -o jsonpath='{.spec.components.image}')
  [ "$cur" = "$IMG" ] || { echo "VERIFY FAIL: spec image=$cur" >&2; exit 1; }
  ci=$(kubectl get milvus "$NAME" -n "$NS" -o jsonpath='{.status.currentImage}')
  [ "$ci" = "$IMG" ] || { echo "VERIFY FAIL: status.currentImage=$ci" >&2; exit 1; }
  bad=$(kubectl get pods -n "$NS" -l "app.kubernetes.io/instance=$NAME,app.kubernetes.io/name=milvus" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].image} {.status.containerStatuses[0].ready}{"\n"}{end}' \
    | awk -v img="$IMG" 'NF && ($2!=img || $3!="true")')
  [ -z "$bad" ] || { echo "VERIFY FAIL: 以下 Pod 未就绪或镜像不符:"; echo "$bad"; exit 1; } >&2
fi
echo "VERIFY OK: Service/nodePort 与快照一致、CR Healthy、MilvusUpdated=True${IMG:+、镜像=$IMG}"
