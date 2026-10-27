#!/usr/bin/env bash
# 用法: make_kubeconfig.sh <milvus-ns> <duration> <out-file> [sa-name]
# 用当前（root/管理员）kubeconfig 为 SA 签发短期 token（TokenRequest，K8s>=1.24），写出只含该 token 的 kubeconfig（600）。
# API Server 地址与 CA 沿用管理员 kubeconfig（脚本在 master 上运行，地址在本机可解析）。不在 stdout 打印 token。
set -euo pipefail
NS=${1:?}; DUR=${2:?}; OUT=${3:?}; SA=${4:-milvus-upgrader}
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [ -z "$CA" ]; then f=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}'); CA=$(base64 < "$f" | tr -d '\n'); fi
TOKEN=$(kubectl create token "$SA" -n "$NS" --duration="$DUR")
umask 077
cat > "$OUT" <<KC
apiVersion: v1
kind: Config
clusters: [{name: $CLUSTER, cluster: {server: "$SERVER", certificate-authority-data: $CA}}]
users: [{name: $SA, user: {token: $TOKEN}}]
contexts: [{name: $SA, context: {cluster: $CLUSTER, user: $SA, namespace: $NS}}]
current-context: $SA
KC
chmod 600 "$OUT"
echo "SA kubeconfig 已生成（600，token 有效期 $DUR，API Server: $SERVER）"
