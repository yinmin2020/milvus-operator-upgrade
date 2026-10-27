#!/usr/bin/env bash
# 用法: gen_rbac.sh <milvus-ns> <cr-name|-> [sa-name] [upgrade|restore] [pvc-name ...]
# 输出命名空间级 SA/Role/RoleBinding YAML（由 root/管理员 context 执行 `| kubectl apply -f -`）。
#   cr-name 为 "-"：阶段 1，只授予在 <milvus-ns> 内 get/list milvuses，用于发现 CR。
#   cr-name 为实际名：阶段 2，完整最小权限；patch 仅限该 CR 和 <cr>-milvus Service，
#   pods delete 仅限 milvus-upgrader-pullcheck-0..9，configmaps 仅能读 <cr>。
#   所有对象只建在 <milvus-ns> 内；不在任何其他命名空间创建对象。
#   restore 模式（oneshot_restore.sh 用）额外授予：delete milvuses/<cr>、create milvuses（K8s 无法按名字限制 create，
#   仅限本 NS）、delete 指定名字的 PVC（该实例 Pod 挂载的 PVC，由调用方列出）。
# 不授予：secrets、pods/exec、除上述之外的任何 delete、任何集群级权限。
set -euo pipefail
NS=${1:?缺少 Milvus 命名空间}; CR=${2:?缺少 CR 名或 -}; SA=${3:-milvus-upgrader}; MODE=${4:-upgrade}
[ $# -gt 4 ] && shift 4 || set --
case "$MODE" in upgrade|restore) ;; *) echo "mode 只能是 upgrade|restore" >&2; exit 2;; esac
LBL='app.kubernetes.io/managed-by: milvus-oneshot-upgrade'
cat <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: $SA, namespace: $NS, labels: {$LBL}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: $SA, namespace: $NS, labels: {$LBL}}
rules:
- apiGroups: ["milvus.io"]
  resources: ["milvuses"]
  verbs: ["get","list","watch"]
YAML
if [ "$CR" != "-" ]; then
pc=""; for i in 0 1 2 3 4 5 6 7 8 9; do pc="$pc\"milvus-upgrader-pullcheck-$i\","; done; pc=${pc%,}
cat <<YAML
- apiGroups: ["milvus.io"]
  resources: ["milvuses"]
  resourceNames: ["$CR"]
  verbs: ["patch"]
- apiGroups: [""]
  resources: ["services","pods","pods/log","persistentvolumeclaims","events","endpoints"]
  verbs: ["get","list","watch"]
- apiGroups: [""]
  resources: ["services"]
  resourceNames: ["$CR-milvus"]
  verbs: ["patch"]
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["$CR"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods/portforward"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["pods"]
  resourceNames: [$pc]
  verbs: ["delete"]
- apiGroups: ["apps"]
  resources: ["deployments","statefulsets","replicasets"]
  verbs: ["get","list","watch"]
YAML
if [ "$MODE" = restore ]; then
cat <<YAML
- apiGroups: ["milvus.io"]
  resources: ["milvuses"]
  resourceNames: ["$CR"]
  verbs: ["delete"]
- apiGroups: ["milvus.io"]
  resources: ["milvuses"]
  verbs: ["create"]
YAML
if [ $# -gt 0 ]; then pv=""; for n in "$@"; do pv="$pv\"$n\","; done
cat <<YAML
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  resourceNames: [${pv%,}]
  verbs: ["delete"]
YAML
fi
fi
fi
cat <<YAML
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: $SA, namespace: $NS, labels: {$LBL}}
subjects: [{kind: ServiceAccount, name: $SA, namespace: $NS}]
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: $SA}
YAML
