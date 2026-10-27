#!/usr/bin/env bash
# 用法: snapshot_svc.sh <ns> <milvus-name>  -> 每行: <svc> <type> <portName>=<port>:<nodePort> ...
# 使用环境变量 KUBECONFIG（编排脚本里指向 SA kubeconfig）
set -euo pipefail
NS=$1; NAME=$2
kubectl get svc -n "$NS" -l app.kubernetes.io/instance="$NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.type}{range .spec.ports[*]} {.name}={.port}:{.nodePort}{end}{"\n"}{end}' | sort
