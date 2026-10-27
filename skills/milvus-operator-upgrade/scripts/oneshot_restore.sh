#!/usr/bin/env bash
# milvus-operator 一键恢复/回滚（在 master 上以 root 运行）：删除 NS 内当前 Milvus 实例及其数据 → 用旧镜像按原配置重建 → 从备份恢复数据
# 用法: oneshot_restore.sh <NS> --check-only [--name CR]   # 只读：列出可用备份(BACKUP 行)与建议恢复镜像，不建任何对象
#       oneshot_restore.sh <NS> <RESTORE_IMAGE> [--name CR] [--backup NAME] [--backup-bin PATH] [--probe-collection C]
#                         [--restore-timeout 3600] [--healthy-timeout 1200] [--token-ttl 4h] [--workdir DIR] [--yes]
# 退出码: 0 成功 | 2 参数/需要选择 | 3 环境 | 4 权限/隔离自检 | 5 预检(备份/镜像/配置，尚未删除任何东西)
#         10 删除旧实例 | 11 重建/Healthy/nodePort | 12 数据恢复/加载 | 13 校验 | 9 探针不一致 | 130 中断/未确认
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SA=milvus-upgrader
usage(){ sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

NS=""; RESTORE_IMAGE=""; NAME=""; BACKUP_NAME=""; BACKUP_BIN="${MILVUS_BACKUP_BIN:-}"; PROBE=""; YES=0; CHECK_ONLY=0
RESTORE_TIMEOUT=3600; HEALTHY_TIMEOUT=1200; PULL_TIMEOUT=900; TOKEN_TTL=4h; WORKBASE=/root/milvus-upgrade
ADMIN_KC=${ADMIN_KUBECONFIG:-${KUBECONFIG:-$HOME/.kube/config}}
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=${2:?}; shift 2;;
    --backup) BACKUP_NAME=${2:?}; shift 2;;
    --backup-bin) BACKUP_BIN=${2:?}; shift 2;;
    --probe-collection) PROBE=${2:?}; shift 2;;
    --restore-timeout) RESTORE_TIMEOUT=${2:?}; shift 2;;
    --healthy-timeout) HEALTHY_TIMEOUT=${2:?}; shift 2;;
    --pull-timeout) PULL_TIMEOUT=${2:?}; shift 2;;
    --token-ttl) TOKEN_TTL=${2:?}; shift 2;;
    --workdir) WORKBASE=${2:?}; shift 2;;
    --check-only) CHECK_ONLY=1; shift;;
    --yes|-y) YES=1; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "未知参数 $1" >&2; usage; exit 2;;
    *) pos+=("$1"); shift;;
  esac
done
if [ $CHECK_ONLY = 1 ]; then
  [ ${#pos[@]} -eq 1 ] || { usage; exit 2; }
  [[ ${pos[0]} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "NS 不合法: ${pos[0]}"; echo "CHECK_RESULT rc=2"; exit 2; }
  ca=(restore "${pos[0]}" --workdir "$WORKBASE"); [ -z "$NAME" ] || ca+=(--name "$NAME"); [ -z "$BACKUP_BIN" ] || ca+=(--backup-bin "$BACKUP_BIN")
  ADMIN_KUBECONFIG=$ADMIN_KC exec python3 "$SCRIPT_DIR/check.py" "${ca[@]}"
fi
[ ${#pos[@]} -eq 2 ] || { usage; exit 2; }
NS=${pos[0]}; RESTORE_IMAGE=${pos[1]}
[[ $NS =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "NS 不合法: $NS" >&2; exit 2; }
[[ $RESTORE_IMAGE =~ ^[^[:space:]]+(:[A-Za-z0-9_.-]+|@sha256:[a-f0-9]{64})$ ]] || { echo "RESTORE_IMAGE 需为 仓库/镜像:tag 全路径" >&2; exit 2; }
[ -z "$NAME" ] || [[ $NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "--name 不合法" >&2; exit 2; }
[ -z "$BACKUP_NAME" ] || [[ $BACKUP_NAME =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "--backup 不合法" >&2; exit 2; }

TS=$(date +%Y%m%d%H%M%S)
mkdir -p "$WORKBASE/runs"; chmod 700 "$WORKBASE" 2>/dev/null || true
RUN_DIR="$WORKBASE/runs/${NS}-restore-${TS}"; mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
LOG="$RUN_DIR/run.log"
exec > >(tee -a "$LOG") 2>&1
TMP=$(mktemp -d /tmp/milvus-upgrader.XXXXXX); chmod 700 "$TMP"
SA_KC="$TMP/sa.kubeconfig"
T_START=$(date +%s)
declare -A GATE; GATE_ORDER=()
gate(){ GATE[$1]="$2"; local f=0 g; for g in "${GATE_ORDER[@]}"; do [ "$g" = "$1" ] && f=1; done; [ $f = 1 ] || GATE_ORDER+=("$1"); }
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }
step(){ echo; echo "[$(ts)] ===== $* ====="; }
DELETED=0
die(){ local rc=$1; shift; echo "[$(ts)] !!!!! 失败(rc=$rc): $*" >&2
  if [ "$DELETED" = 1 ]; then echo "[$(ts)] !!!!! 旧实例已删除。修复原因后用同一条命令重跑即可续做（会复用 $RUN_DIR/cr-recreate.json 与本地备份导出）" >&2; fi
  exit "$rc"; }
kadm(){ kubectl --kubeconfig "$ADMIN_KC" "$@"; }   # root/管理员：NS 存在性、RBAC 增删、签 token、(必要时)读 MinIO secret
ksa(){ kubectl --kubeconfig "$SA_KC" "$@"; }        # 其余全部操作
PF_PIDS=(); RBAC_APPLIED=0; PULL_PODS=()

cleanup(){
  local rc=$?
  set +e
  echo; log "===== 清理（rc=$rc）====="
  for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  [ -n "${SA_KC:-}" ] && pkill -f -- "--kubeconfig $SA_KC" 2>/dev/null
  sleep 1; log "port-forward 残留进程: $(pgrep -fc -- "--kubeconfig $SA_KC" 2>/dev/null || true)"
  if [ ${#PULL_PODS[@]} -gt 0 ] && [ -s "$SA_KC" ]; then ksa -n "$NS" delete pod "${PULL_PODS[@]}" --ignore-not-found --wait=false >/dev/null 2>&1; fi
  if [ "$RBAC_APPLIED" = 1 ]; then
    kadm -n "$NS" delete rolebinding,role,serviceaccount "$SA" --ignore-not-found
    left=$(kadm -n "$NS" get sa,role,rolebinding -o name 2>/dev/null | grep -c "/$SA\$")
    log "RBAC 清理完成（残留 $left 个）；token 随 SA 删除即失效"
  fi
  rm -rf "$TMP"
  log "临时目录已删除；日志与报告: $RUN_DIR"
  echo "ONESHOT_RESULT rc=$rc run_dir=$RUN_DIR"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
# shellcheck disable=SC2154  # 变量在 trap 字符串内赋值
trap '_erc=$?; _eln=$LINENO; echo "[$(date "+%F %T")] ERROR: 第 $_eln 行命令失败 (rc=$_erc): $BASH_COMMAND" >&2' ERR

cat <<NOTICE
================ 风险提示（恢复/回滚） ================
将把命名空间 [$NS] 中的 Milvus 恢复为镜像 [$RESTORE_IMAGE] + 备份 [${BACKUP_NAME:-自动选择最近一次 pre_upgrade_* 备份}]，全程无人值守：
1. 【不可逆】删除 [$NS] 中当前的 Milvus CR${NAME:+ $NAME} 及其全部数据：Milvus Pod、Service（随后按原 nodePort 重建）、
   该实例的 etcd 与 MinIO（helm release 由 operator 卸载）以及这些组件挂载的 PVC。删除前当前实例里的数据将永久丢失。
2. 【数据丢失】只能恢复到备份时间点：备份之后写入/删除/修改的数据全部丢失（含升级后写入的数据）。
3. 用原 CR 配置在旧镜像上重建（etcd/MinIO 等依赖沿用原 CR 里的配置与镜像，不需要另外准备；容器以 root 运行：
   securityContext runAsUser=0——官方文档没有这一步，因为原数据文件属主是 root；保持 serviceType 与原 nodePort），等待 Healthy 后
   把备份（优先使用 master 本地导出副本；若只在 MinIO 中则先导出到 master 本地再删除）导入新 MinIO，用 milvus-backup restore
   恢复全部集合并重建索引、加载集合，与备份时记录的探针（行数 + top-5）比对。
4. 在 [$NS] 临时创建 SA/Role/RoleBinding "$SA"（含删除/创建该 Milvus CR 与删除上述 PVC 的权限）及拉取检查 Pod，结束自动删除。
5. 期间 Milvus 完全不可用（删除 + 重建 + 导入，取决于数据量）。除上述对象外不修改 [$NS] 内其他资源，也不触碰其他命名空间。
=======================================================
NOTICE
if [ "$YES" != 1 ]; then
  [ -r /dev/tty ] || die 130 "非交互运行必须加 --yes（agent 须先向用户展示风险提示并获得确认）"
  read -r -p "确认删除当前实例并恢复，请输入 yes: " ans < /dev/tty; [ "$ans" = yes ] || die 130 "用户未确认"
fi

# ---------- 0. 环境 ----------
step "0. 环境检查（root/管理员 context）"
exec 9>"$WORKBASE/.lock-$NS"; flock -n 9 || die 3 "同一 NS 已有升级/恢复在运行（锁 $WORKBASE/.lock-$NS）"
command -v kubectl >/dev/null || die 3 "master 上没有 kubectl"
command -v python3 >/dev/null || die 3 "master 上没有 python3（备份导入导出/探针需要）"
[ -r "$ADMIN_KC" ] || die 3 "找不到管理员 kubeconfig: $ADMIN_KC"
kadm get ns "$NS" -o name >/dev/null || die 3 "命名空间 $NS 不存在或管理员 kubeconfig 不可用"
for v in "create serviceaccounts" "create roles" "create rolebindings" "create serviceaccounts/token"; do
  [ "$(kadm auth can-i $v -n "$NS" 2>/dev/null)" = yes ] || die 3 "管理员 context 无权 $v -n $NS"
done
log "Milvus NS=$NS  workdir=$RUN_DIR"
gate env PASS

# ---------- 1. SA 阶段 1 + CR 发现 / 续做检测 ----------
step "1. 临时 SA（阶段 1：只读 Milvus CR）"
RBAC_APPLIED=1
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" - "$SA" | kadm apply -f -
KUBECONFIG="$ADMIN_KC" bash "$SCRIPT_DIR/make_kubeconfig.sh" "$NS" "$TOKEN_TTL" "$SA_KC" "$SA"
export KUBECONFIG="$SA_KC"
mapfile -t CRS < <(ksa -n "$NS" get milvus -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
RESUME=""
if [ -z "$NAME" ]; then
  if [ ${#CRS[@]} -gt 1 ]; then log "NEED_CR_NAME: $NS 中有多个 Milvus CR: ${CRS[*]}"; die 2 "请用 --name 指定要恢复的 CR"; fi
  [ ${#CRS[@]} -eq 1 ] && NAME=${CRS[0]}
fi
if [ -z "$NAME" ] || ! printf '%s\n' "${CRS[@]}" | grep -qx "$NAME"; then
  # CR 不存在：只允许“续做”上一次在删除后中断的恢复
  for d in $(ls -1d "$WORKBASE/runs/${NS}"-restore-*/ 2>/dev/null | sort -r); do
    f="$d/cr-recreate.json"; [ -s "$f" ] || continue
    n=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["metadata"]["name"])' "$f")
    if [ -z "$NAME" ] || [ "$n" = "$NAME" ]; then RESUME=${d%/}; NAME=$n; break; fi
  done
  [ -n "$RESUME" ] || die 3 "$NS 中没有${NAME:+名为 $NAME 的} Milvus CR，也没有可续做的恢复记录（现有: ${CRS[*]:-无}）"
  log "续做模式：CR $NAME 已不存在，复用上次中断的恢复记录 $RESUME"
fi
log "目标 CR: $NS/$NAME"
SVC="$NAME-milvus"
# 预检需要读 Service/Pod/PVC/ConfigMap：先授予与升级相同的阶段 2 权限（不含任何 delete/create milvus），删除类权限在隔离自检前才授予
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" "$NAME" "$SA" upgrade | kadm apply -f - >/dev/null

# ---------- 2. 预检（不做任何修改） ----------
step "2. 预检：配置、备份可用性、milvus-backup、PVC 清单（尚未修改任何东西）"
if [ -z "$RESUME" ]; then
  ksa -n "$NS" get milvus "$NAME" -o json > "$RUN_DIR/cr-original.json"
  ksa -n "$NS" get milvus "$NAME" -o yaml > "$RUN_DIR/cr-original.yaml"
  bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME" | tee "$RUN_DIR/svc_snapshot.txt"
  [ -s "$RUN_DIR/svc_snapshot.txt" ] || die 5 "找不到 $NAME 的 Service"
else
  cp "$RESUME/cr-original.json" "$RESUME/svc_snapshot.txt" "$RUN_DIR/"
  [ -f "$RESUME/restore.meta" ] && cp "$RESUME/restore.meta" "$RUN_DIR/prev-restore.meta"
  log "沿用上次快照: $(tr '\n' ' ' < "$RUN_DIR/svc_snapshot.txt")"
fi
J="$RUN_DIR/cr-original.json"
jq_(){ python3 - "$J" "$@" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d = d.get(k) if isinstance(d, dict) else None
    if d is None: break
print('' if d is None else (json.dumps(d) if isinstance(d,(dict,list)) else d))
PY
}
MODE=$(jq_ spec.mode); MODE=${MODE:-standalone}
CUR_IMAGE=$(jq_ spec.components.image)
MQ=$(jq_ spec.dependencies.msgStreamType)
SVC_TYPE=$(head -1 "$RUN_DIR/svc_snapshot.txt" | awk '{print $2}')
for dep in etcd storage; do
  [ "$(jq_ spec.dependencies.$dep.external)" = True ] || [ "$(jq_ spec.dependencies.$dep.external)" = true ] && die 5 "$dep 为外部依赖：脚本不能清空外部 $dep，不支持自动恢复（需人工处理）"
done
case "${MQ:-rocksmq}" in
  rocksmq|natsmq|woodpecker) ;;
  pulsar|kafka) [ "$(jq_ spec.dependencies.$MQ.external)" != true ] || die 5 "$MQ 为外部依赖，不支持自动恢复";;
  *) log "WARN: 未验证的 msgStreamType=$MQ";;
esac
EXCL=$(jq_ spec.dependencies.rocksmq.persistence.persistentVolumeClaim.existingClaim)
[ -z "$EXCL" ] || die 5 "rocksmq 使用 existingClaim=$EXCL（用户自管 PVC），不支持自动清空"
log "mode=$MODE MQ=${MQ:-rocksmq} 当前镜像=$CUR_IMAGE → 恢复镜像=$RESTORE_IMAGE  Service=$SVC_TYPE"

# 备份选择
META=""
for f in $(ls -1 "$WORKBASE"/runs/"${NS}"-[0-9]*/backup.meta 2>/dev/null | sort -r); do
  bn=$(sed -n 's/^BACKUP_NAME=//p' "$f"); cn=$(sed -n 's/^CR=//p' "$f")
  [ "$cn" = "$NAME" ] || continue
  if [ -z "$BACKUP_NAME" ] || [ "$bn" = "$BACKUP_NAME" ]; then META=$f; BACKUP_NAME=$bn; break; fi
done
mget(){ [ -n "$META" ] && sed -n "s/^$1=//p" "$META" | head -1; }
LOCAL_EXPORT=""; PROBE_PRE=""; PROBE_STATE=""; SRC_IMAGE=""
if [ -n "$META" ]; then
  ed=$(mget EXPORT_DIR); [ -n "$ed" ] && [ -s "$ed/MANIFEST" ] && grep -q " backup/$BACKUP_NAME/" "$ed/MANIFEST" && LOCAL_EXPORT=$ed
  [ -n "$PROBE" ] || PROBE=$(mget PROBE_COLLECTION)
  PROBE_PRE=$(mget PROBE_PRE); PROBE_STATE=$(mget PROBE_STATE); SRC_IMAGE=$(mget SOURCE_IMAGE)
  log "备份元数据: $META → $BACKUP_NAME（升级前镜像 ${SRC_IMAGE:-?}，本地导出 ${LOCAL_EXPORT:-无}，探针 ${PROBE:-无}）"
fi
if [ -n "$RESUME" ] && [ -z "$LOCAL_EXPORT" ] && [ -s "$RESUME/backup_export/MANIFEST" ]; then
  LOCAL_EXPORT="$RESUME/backup_export"; [ -n "$BACKUP_NAME" ] || BACKUP_NAME=$(awk 'NR==1{split($3,a,"/");print a[2]}' "$LOCAL_EXPORT/MANIFEST")
fi
[ -n "$SRC_IMAGE" ] && [ "$SRC_IMAGE" != "$RESTORE_IMAGE" ] && log "WARN: 备份来自 $SRC_IMAGE，恢复镜像为 $RESTORE_IMAGE（不同）"

# milvus-backup
BK_DIR="$TMP/backup"; mkdir -p "$BK_DIR"
# 只接受与 master 架构一致的二进制/包（前置条件 milvus-backup 0.6.1：用户自行下载后放到 $WORKBASE/，或经本机 scripts/install_backup.sh --from 装到 $WORKBASE/milvus-backup）
case "$(uname -m)" in x86_64|amd64) MARCH=x86_64;; aarch64|arm64) MARCH=arm64;; *) MARCH=$(uname -m);; esac
bin_arch_ok(){ local em; em=$(od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' ')
  case "$em" in 62) [ "$MARCH" = x86_64 ];; 183) [ "$MARCH" = arm64 ];; *) true;; esac; }
tgz_arch_ok(){ case "$1" in *_Linux_x86_64.t*|*_Linux_amd64.t*) [ "$MARCH" = x86_64 ];; *_Linux_arm64.t*|*_Linux_aarch64.t*) [ "$MARCH" = arm64 ];; *) true;; esac; }
cand=("$BACKUP_BIN" "$WORKBASE/milvus-backup" "/root/milvus-backup/milvus-backup" "/usr/local/bin/milvus-backup" "$(command -v milvus-backup 2>/dev/null || true)")
for g in "$WORKBASE"/milvus-backup_*_Linux_*.tar.gz /root/milvus-backup_*_Linux_*.tar.gz; do [ -f "$g" ] && cand+=("$g"); done
BIN=""
for c in "${cand[@]}"; do
  [ -n "$c" ] || continue
  [ -d "$c" ] && c="$c/milvus-backup"
  [ -f "$c" ] || continue
  if [[ $c == *.tar.gz || $c == *.tgz ]]; then
    tgz_arch_ok "$c" || { log "跳过架构不符的 $c"; continue; }
    tar -xzf "$c" -C "$BK_DIR" milvus-backup && BIN="$BK_DIR/milvus-backup" && break; continue
  fi
  [ -x "$c" ] || continue
  bin_arch_ok "$c" || { log "跳过架构不符的 $c"; continue; }
  BIN="$c"; break
done
[ -n "$BIN" ] || die 5 "找不到可用的 milvus-backup（master 架构 $MARCH）。这是前置条件，回到 SKILL.md B2：请用户自行下载 https://github.com/zilliztech/milvus-backup/releases/download/v0.6.1/milvus-backup_0.6.1_Linux_${MARCH}.tar.gz（sha256 见 scripts/milvus-backup-sha256.txt），放到 master 的 $WORKBASE/（tarball 或可执行的 milvus-backup 二进制；其他路径用 --backup-bin），或下载到本机后用 scripts/install_backup.sh <master> --from <本地路径> 安装，再重跑 --check-only。agent 不得代为下载"
log "milvus-backup: $BIN"

# ---------- 端口转发 / 配置工具（与 oneshot_upgrade.sh 相同） ----------
free_port(){ local p=$1; while ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p\$"; do p=$((p+1)); done; echo "$p"; }
PF_PORT=""
pf(){ local tag=$1 tgt=$2 rp=$3 n=0; PF_PORT=$(free_port "$4")
  kubectl --kubeconfig "$SA_KC" -n "$NS" port-forward --address 127.0.0.1 "$tgt" "$PF_PORT:$rp" > "$TMP/pf-$tag.log" 2>&1 &
  PF_PIDS+=($!)
  until grep -q "Forwarding from" "$TMP/pf-$tag.log" 2>/dev/null; do
    n=$((n+1)); [ $n -lt 60 ] || { cat "$TMP/pf-$tag.log" >&2; return 1; }; sleep 0.5; done; }
pf_stop(){ for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; PF_PIDS=(); pkill -f -- "--kubeconfig $SA_KC .*port-forward" 2>/dev/null || true; sleep 1; }
UY="$TMP/user.yaml"; CRED="$TMP/minio.cred"
yget(){ awk -v want="$1" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    { match($0,/^ */); ind=RLENGTH/2; line=substr($0,RLENGTH+1)
      if (line ~ /^- /) next
      k=line; sub(/:.*/,"",k); v=line; if (index(v,":")) { sub(/^[^:]*:[ ]*/,"",v) } else v=""
      path[ind]=k; p=path[0]; for(i=1;i<=ind;i++) p=p"."path[i]
      if (p==want) { gsub(/^["\x27]|["\x27]$/,"",v); print v; exit } }' "$UY"; }
read_conf(){ # 读取（当前）实例的 user.yaml 与 MinIO 凭据
  ksa -n "$NS" get cm "$NAME" -o jsonpath='{.data.user\.yaml}' > "$UY" || return 1
  ETCD_ROOT=$(yget etcd.rootPath); ETCD_ROOT=${ETCD_ROOT:-$NAME}
  BUCKET=$(yget minio.bucketName); BUCKET=${BUCKET:-milvus-bucket}
  DATA_ROOT=$(yget minio.rootPath); DATA_ROOT=${DATA_ROOT:-files}
  MINIO_ADDR=$(yget minio.address); MINIO_PORT=$(yget minio.port); MINIO_PORT=${MINIO_PORT:-9000}
  MINIO_SSL=$(yget minio.useSSL); MINIO_SSL=${MINIO_SSL:-false}
  CHAN_PREFIX=$(yget msgChannel.chanNamePrefix.cluster); CHAN_PREFIX=${CHAN_PREFIX:-by-dev}
  AUTH_ON=$(yget common.security.authorizationEnabled)
  local ak sk; ak=$(yget minio.accessKeyID); sk=$(yget minio.secretAccessKey)
  ( umask 077; : > "$CRED" )
  if [ -z "$ak" ] || [ -z "$sk" ]; then
    local sref; sref=$(jq_ spec.dependencies.storage.secretRef)
    [ -n "$sref" ] || return 1
    kadm -n "$NS" get secret "$sref" -o jsonpath='{.data.accesskey}' | base64 -d > "$CRED"; echo >> "$CRED"
    kadm -n "$NS" get secret "$sref" -o jsonpath='{.data.secretkey}' | base64 -d >> "$CRED"; echo >> "$CRED"
  else printf '%s\n%s\n' "$ak" "$sk" > "$CRED"; fi
  [ "$(wc -l < "$CRED")" -ge 2 ] && [ -n "$(sed -n 1p "$CRED")" ]
}
start_pf(){ # start_pf milvus|minio|etcd ...
  local w
  for w in "$@"; do case $w in
    milvus) pf milvus "svc/$SVC" 19530 41953 || return 1; MV_PORT=$PF_PORT
            pf mgmt "svc/$SVC" 9091 41909 || return 1; MG_PORT=$PF_PORT;;
    minio)  local msvc=${MINIO_ADDR%%.*}; pf minio "svc/${msvc:-$NAME-minio}" "$MINIO_PORT" 49000 || return 1; S3_PORT=$PF_PORT
            S3_URL="http$([ "$MINIO_SSL" = true ] && echo s || true)://127.0.0.1:$S3_PORT";;
    etcd)   pf etcd "svc/$NAME-etcd" 2379 42379 || return 1; ETCD_EP="127.0.0.1:$PF_PORT";;
  esac; done; }
write_backup_yaml(){
  local ak sk; ak=$(sed -n 1p "$CRED"); sk=$(sed -n 2p "$CRED")
  ( umask 077; cat > "$BK_DIR/backup.yaml" <<YAML
configVersion: v2
log: {level: info, console: true, file: {path: "$RUN_DIR/milvus-backup.log"}}
milvus:
  grpc: {address: 127.0.0.1, port: $MV_PORT}
  management: {endpoint: "http://127.0.0.1:$MG_PORT"}
  replicate: {rpcChannelName: "${CHAN_PREFIX}-replicate-msg"}
  etcd: {endpoints: ["$ETCD_EP"], rootPath: "$ETCD_ROOT"}
  storage:
    provider: minio
    address: 127.0.0.1
    port: $S3_PORT
    useSSL: $MINIO_SSL
    bucketName: "$BUCKET"
    rootPath: "$DATA_ROOT"
    auth: {type: static, accessKeyID: "$ak", secretAccessKey: "$sk"}
backup:
  storage:
    provider: minio
    address: 127.0.0.1
    port: $S3_PORT
    useSSL: $MINIO_SSL
    bucketName: "$BUCKET"
    rootPath: backup
    auth: {type: static, accessKeyID: "$ak", secretAccessKey: "$sk"}
  pauseGC: false
YAML
  )
  if [ -n "${MILVUS_TOKEN:-}" ]; then local u=${MILVUS_TOKEN%%:*} p=${MILVUS_TOKEN#*:}
    ( umask 077; sed -i "s|^milvus:|milvus:\n  user: \"$u\"\n  password: \"$p\"|" "$BK_DIR/backup.yaml" ); fi
}
mb(){ ( cd "$BK_DIR" && "$BIN" --config "$BK_DIR/backup.yaml" "$@" ); }

# 当前实例：确保备份在本地有完整副本（删除前）
if [ -z "$RESUME" ]; then
  read_conf || die 5 "读取 $NAME 的 ConfigMap/MinIO 凭据失败"
  [ "${AUTH_ON:-false}" != true ] || [ -n "${MILVUS_TOKEN:-}" ] || die 5 "Milvus 开启了鉴权，需在环境变量 MILVUS_TOKEN=user:password 中提供凭据"
  start_pf milvus minio etcd || die 5 "port-forward 失败"
  if [ -z "$BACKUP_NAME" ]; then
    write_backup_yaml
    mb list > "$RUN_DIR/backup_list_before.out" 2>&1 || true
    BACKUP_NAME=$(grep -o 'pre_upgrade_[0-9]\{14\}' "$RUN_DIR/backup_list_before.out" | sort -u | tail -1 || true)
    [ -n "$BACKUP_NAME" ] || die 5 "没有找到任何 pre_upgrade_* 备份（本地元数据与 MinIO 都没有），请用 --backup 指定"
    log "MinIO 中最近的备份: $BACKUP_NAME"
  fi
  if [ -z "$LOCAL_EXPORT" ]; then
    OBJ=$(python3 "$SCRIPT_DIR/s3tool.py" ls "$S3_URL" "$BUCKET" "backup/$BACKUP_NAME/" "$CRED") || die 5 "列 MinIO 失败: $OBJ"
    [[ $OBJ =~ OBJECTS=([0-9]+)\ BYTES=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 0 ] || die 5 "备份 $BACKUP_NAME 既不在 master 本地导出中，也不在当前 MinIO 中"
    bytes=${BASH_REMATCH[2]}; avail=$(( $(df -Pk "$RUN_DIR" | awk 'NR==2{print $4}') * 1024 ))
    [ "$avail" -ge $(( bytes + bytes/5 + 1073741824 )) ] || die 5 "master 磁盘空间不足以导出备份（${bytes}B）"
    EX=$(python3 "$SCRIPT_DIR/s3tool.py" pull "$S3_URL" "$BUCKET" "backup/$BACKUP_NAME/" "$CRED" "$RUN_DIR/backup_export") || die 5 "导出备份失败: $EX"
    LOCAL_EXPORT="$RUN_DIR/backup_export"; log "备份仅在 MinIO 中，已导出到本地: $EX"
  fi
  if [ -n "$PROBE" ]; then
    python3 "$SCRIPT_DIR/probe.py" count --endpoint "http://127.0.0.1:$MV_PORT" --collection "$PROBE" > "$RUN_DIR/count_before.out" 2>&1 || true
    log "删除前当前实例: $(tr '\n' ' ' < "$RUN_DIR/count_before.out")"
  fi
  pf_stop
fi
[ -n "$BACKUP_NAME" ] && [ -n "$LOCAL_EXPORT" ] || die 5 "无法确定可用的备份"
V=$(python3 "$SCRIPT_DIR/s3tool.py" verify - - "backup/$BACKUP_NAME/" - "$LOCAL_EXPORT") || die 5 "本地备份副本校验失败: $V"
log "本地备份副本 $LOCAL_EXPORT: $V"
gate backup_ready "PASS ($BACKUP_NAME, $V)"
{ echo "BACKUP_NAME=$BACKUP_NAME"; echo "LOCAL_EXPORT=$LOCAL_EXPORT"; echo "PROBE_COLLECTION=$PROBE"; echo "PROBE_PRE=$PROBE_PRE"; echo "PROBE_STATE=$PROBE_STATE"; } > "$RUN_DIR/restore.meta"
if [ -n "$RESUME" ] && [ -f "$RUN_DIR/prev-restore.meta" ]; then
  [ -n "$PROBE" ] || PROBE=$(sed -n 's/^PROBE_COLLECTION=//p' "$RUN_DIR/prev-restore.meta")
  [ -n "$PROBE_PRE" ] || PROBE_PRE=$(sed -n 's/^PROBE_PRE=//p' "$RUN_DIR/prev-restore.meta")
  [ -n "$PROBE_STATE" ] || PROBE_STATE=$(sed -n 's/^PROBE_STATE=//p' "$RUN_DIR/prev-restore.meta")
fi

# 重建用 CR（去掉状态/运行时字段与 operator 注解；镜像改为恢复镜像；root 运行；deletionPolicy 保持原值）
python3 - "$J" "$RESTORE_IMAGE" > "$RUN_DIR/cr-recreate.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); md = o['metadata']
ann = {k: v for k, v in (md.get('annotations') or {}).items()
       if not k.startswith('milvus.io/') and k != 'kubectl.kubernetes.io/last-applied-configuration'}
new = {'apiVersion': o['apiVersion'], 'kind': o['kind'],
       'metadata': {'name': md['name'], 'namespace': md['namespace'], 'labels': md.get('labels') or {}, 'annotations': ann},
       'spec': o['spec']}
c = new['spec'].setdefault('components', {})
c['image'] = sys.argv[2]
c['securityContext'] = dict(c.get('securityContext') or {}, runAsUser=0, runAsNonRoot=False)
json.dump(new, sys.stdout, indent=1)
PY
log "重建清单: $RUN_DIR/cr-recreate.json"

# PVC 清单：该实例（milvus / etcd / minio / 实例自带 MQ）Pod 挂载的 PVC + 同标签 PVC；任何被其他 Pod 使用的 PVC 直接停止
INST_RE="^($NAME|$NAME-etcd|$NAME-minio|$NAME-pulsar|$NAME-kafka)\$"
mapfile -t PVCS < <( {
  ksa -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/instance}|{.metadata.labels.release}|{range .spec.volumes[*]}{.persistentVolumeClaim.claimName} {end}{"\n"}{end}' \
    | awk -F'|' -v re="$INST_RE" '$1 ~ re || $2 ~ re {n=split($3,a," "); for(i=1;i<=n;i++) print a[i]}'
  ksa -n "$NS" get pvc -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.app\.kubernetes\.io/instance}|{.metadata.labels.release}{"\n"}{end}' \
    | awk -F'|' -v re="$INST_RE" '$2 ~ re || $3 ~ re {print $1}'
  [ -n "$RESUME" ] && [ -f "$RESUME/pvcs.txt" ] && cat "$RESUME/pvcs.txt"
} | grep -v '^$' | sort -u )
if [ -z "$RESUME" ]; then
  others=$(ksa -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.app\.kubernetes\.io/instance}|{.metadata.labels.release}|{range .spec.volumes[*]}{.persistentVolumeClaim.claimName} {end}{"\n"}{end}' \
    | awk -F'|' -v re="$INST_RE" '!($2 ~ re || $3 ~ re) {print}' || true)
  for p in "${PVCS[@]}"; do
    if echo "$others" | awk -F'|' -v p="$p" '{n=split($4,a," "); for(i=1;i<=n;i++) if(a[i]==p) f=1} END{exit !f}'; then
      die 5 "PVC $p 同时被非本实例的 Pod 使用，停止（不能删除共享卷）"; fi
  done
fi
printf '%s\n' "${PVCS[@]}" > "$RUN_DIR/pvcs.txt"
log "将随实例删除的 PVC: ${PVCS[*]:-无}"

step "2b. 收紧/补全 Role（阶段 2，restore 模式）"
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" "$NAME" "$SA" restore "${PVCS[@]}" | kadm apply -f -
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" "$NAME" "$SA" restore "${PVCS[@]}" > "$RUN_DIR/rbac.yaml"

step "3. 隔离自检（SA 身份）"
iso_fail=0
chk(){ local want=$1; shift; local got; got=$(ksa auth can-i "$@" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then log "OK   can-i $* = $got"; else log "FAIL can-i $* = $got (期望 $want)"; iso_fail=1; fi; }
chk yes delete "milvuses.milvus.io/$NAME" -n "$NS"
chk yes create milvuses.milvus.io -n "$NS"
chk no  delete milvuses.milvus.io/other-cr -n "$NS"
chk no  delete persistentvolumeclaims/milvus-upgrader-not-a-pvc -n "$NS"
chk no  delete deployments -n "$NS"
chk no  get secrets -n "$NS"
chk no  create pods --subresource=exec -n "$NS"
chk no  get pods -n kube-system
chk no  create milvuses.milvus.io -n default
chk no  delete persistentvolumeclaims -n default
chk no  get nodes
chk no  list milvuses.milvus.io -A
out=$(ksa get pods -n kube-system 2>&1 || true); log "实测 get pods -n kube-system => $out"
echo "$out" | grep -qi forbidden || iso_fail=1
out=$(ksa -n kube-system create configmap milvus-upgrader-isolation-test --from-literal=a=b --dry-run=server 2>&1 || true)
log "实测 create configmap -n kube-system (dry-run=server) => $out"
echo "$out" | grep -qi forbidden || iso_fail=1
[ $iso_fail = 0 ] || die 4 "SA 权限超出预期，为安全起见停止"
gate isolation PASS

# ---------- 4. 拉取检查 ----------
step "4. 恢复镜像拉取检查"
MSEL="app.kubernetes.io/instance=$NAME,app.kubernetes.io/name=milvus"
PULL_SECRETS=$(python3 -c 'import json,sys;print(" ".join(s["name"] for s in (json.load(open(sys.argv[1]))["spec"].get("components",{}).get("imagePullSecrets") or [])))' "$J")
mapfile -t NODES < <(ksa -n "$NS" get pods -l "$MSEL" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -v '^$' || true)
if [ ${#NODES[@]} -eq 0 ]; then log "当前没有 Milvus Pod（续做/已删除），跳过拉取检查，由重建等待环节判断"; gate image_pull "SKIP"
else
  ips=""; for s in $PULL_SECRETS; do ips="$ips{\"name\":\"$s\"},"; done; ips="[${ips%,}]"
  i=0
  for node in "${NODES[@]:0:10}"; do
    pod="milvus-upgrader-pullcheck-$i"; PULL_PODS+=("$pod")
    ksa -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    cat > "$TMP/$pod.json" <<JSON
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"$pod","namespace":"$NS","labels":{"app.kubernetes.io/managed-by":"milvus-oneshot-upgrade"}},
 "spec":{"nodeName":"$node","restartPolicy":"Never","automountServiceAccountToken":false,"imagePullSecrets":$ips,
  "tolerations":[{"operator":"Exists"}],"terminationGracePeriodSeconds":0,
  "containers":[{"name":"pullcheck","image":"$RESTORE_IMAGE","imagePullPolicy":"IfNotPresent","command":["/bin/sh","-c","exit 0"],
   "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}
JSON
    ksa create -f "$TMP/$pod.json" >/dev/null; log "已创建 $pod -> 节点 $node"; i=$((i+1))
  done
  for pod in "${PULL_PODS[@]}"; do
    t0=$(date +%s); res=""
    while :; do
      phase=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      wr=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
      tr=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
      case "$wr" in ImagePullBackOff|ErrImageNeverPull|InvalidImageName) res="FAIL:$wr"; break;; esac
      if [ "$phase" = Succeeded ] || [ "$phase" = Failed ] || [ -n "$tr" ]; then res="OK($phase)"; break; fi
      [ $(( $(date +%s) - t0 )) -lt "$PULL_TIMEOUT" ] || { res="FAIL:超时 phase=$phase waiting=$wr"; break; }
      sleep 5
    done
    log "$pod: $res（$(( $(date +%s) - t0 ))s）"
    [[ $res == FAIL* ]] && die 5 "恢复镜像拉取失败: $res（尚未删除任何东西）"
  done
  ksa -n "$NS" delete pod "${PULL_PODS[@]}" --ignore-not-found --wait=true >/dev/null; PULL_PODS=()
  gate image_pull PASS
fi
gate preflight PASS

# ---------- 5. 删除旧实例 ----------
T_DEL=$(date +%s)
if [ -z "$RESUME" ]; then
step "5. 删除旧实例（CR + etcd/MinIO release + PVC）"
DELETED=1
patch=$(python3 - "$J" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); dep = o['spec'].get('dependencies', {}); mq = dep.get('msgStreamType') or 'rocksmq'
p = {'etcd': {'inCluster': {'deletionPolicy': 'Delete', 'pvcDeletion': True}},
     'storage': {'inCluster': {'deletionPolicy': 'Delete', 'pvcDeletion': True}}}
d = dep.get(mq) or {}
if 'inCluster' in d: p[mq] = {'inCluster': {'deletionPolicy': 'Delete', 'pvcDeletion': True}}
if 'persistence' in d: p[mq] = {'persistence': {'pvcDeletion': True}}
print(json.dumps({'spec': {'dependencies': p}}))
PY
)
log "patch 删除策略: $patch"
ksa -n "$NS" patch milvus "$NAME" --type merge -p "$patch" >/dev/null
sleep 5
ksa -n "$NS" delete milvus "$NAME" --wait=false
fi
deadline=$(( $(date +%s) + 900 )); gone_at=0; pvc_forced=0; lastp=0
while :; do
  now=$(date +%s)
  crx=$(ksa -n "$NS" get milvus "$NAME" -o name --ignore-not-found 2>/dev/null || echo err)
  pods=$(ksa -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.app\.kubernetes\.io/instance}|{.metadata.labels.release}{"\n"}{end}' | awk -F'|' -v re="$INST_RE" '$2 ~ re || $3 ~ re {print $1}' | paste -sd' ' -)
  wl=$(ksa -n "$NS" get sts,deploy -o name 2>/dev/null | grep -E "/($NAME|$NAME-etcd|$NAME-minio|$NAME-milvus-[a-z]+)\$" | paste -sd' ' - || true)
  left=""; for p in "${PVCS[@]}"; do ksa -n "$NS" get pvc "$p" -o name >/dev/null 2>&1 && left="$left $p"; done
  if [ $((now - lastp)) -ge 20 ]; then lastp=$now; log "等待删除: CR=${crx:-已删} pods=[${pods}] workloads=[${wl}] pvc=[${left# }]"; fi
  [ -z "$crx" ] && [ $gone_at = 0 ] && gone_at=$now
  if [ -z "$crx" ] && [ -z "$pods" ] && [ -z "$wl" ] && [ -z "$left" ]; then break; fi
  if [ $gone_at -gt 0 ] && [ -n "$left" ] && [ $pvc_forced = 0 ] && [ $((now - gone_at)) -ge 90 ] && [ -z "$pods" ]; then
    log "operator 未删除 PVC:${left}，由 SA 删除（仅限清单内名字）"; ksa -n "$NS" delete pvc $left --wait=false || true; pvc_forced=1; fi
  [ "$now" -lt "$deadline" ] || die 10 "删除超时: CR=${crx:-已删} pods=[$pods] workloads=[$wl] pvc=[${left# }]（etcd/MinIO helm release 未卸载时需管理员 helm uninstall）"
  sleep 5
done
DEL_SECS=$(( $(date +%s) - T_DEL ))
log "旧实例已删除（${DEL_SECS}s）"
gate delete "PASS (${DEL_SECS}s, PVC: ${PVCS[*]:-无})"
DELETED=1

# ---------- 6. 重建 ----------
step "6. 用 $RESTORE_IMAGE 按原配置重建 CR"
T_RC=$(date +%s)
ksa create -f "$RUN_DIR/cr-recreate.json"
cr(){ ksa -n "$NS" get milvus "$NAME" -o jsonpath="$1"; }
lastp=-100
while :; do
  el=$(( $(date +%s) - T_RC ))
  st=$(cr '{.status.status}' 2>/dev/null || true); up=$(cr '{.status.conditions[?(@.type=="MilvusUpdated")].status}' 2>/dev/null || true)
  ci=$(cr '{.status.currentImage}' 2>/dev/null || true)
  pods=$(ksa -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.app\.kubernetes\.io/instance}{.metadata.labels.release}|{.spec.containers[0].image}|{.status.containerStatuses[0].ready}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' | awk -F'|' -v re="$INST_RE" '$2 ~ re' || true)
  if [ $(( el - lastp )) -ge 30 ]; then lastp=$el; log "t+${el}s status=${st:-?} MilvusUpdated=${up:-?} currentImage=${ci##*/}"; echo "$pods" | sed 's/^/      /'; fi
  [ "$st" = Healthy ] && [ "$up" = True ] && [ "$ci" = "$RESTORE_IMAGE" ] && break
  crash=$(echo "$pods" | awk -F'|' '$6=="CrashLoopBackOff" && $5>=3 {print $1}' | head -1)
  [ -z "$crash" ] || { ksa -n "$NS" logs "$crash" --previous --tail=60 || true; die 11 "重建后 Pod $crash CrashLoop"; }
  pb=$(echo "$pods" | awk -F'|' '$6=="ImagePullBackOff"||$6=="ErrImagePull" {print $1}' | head -1)
  [ -z "$pb" ] || [ $el -lt 300 ] || die 11 "Pod $pb 拉取镜像失败超过 300s"
  [ $el -lt "$HEALTHY_TIMEOUT" ] || die 11 "重建后等待 Healthy 超时（${HEALTHY_TIMEOUT}s）"
  sleep 10
done
RC_SECS=$(( $(date +%s) - T_RC )); log "重建完成：Healthy（${RC_SECS}s）"
fix_nodeports(){
  diff <(cat "$RUN_DIR/svc_snapshot.txt") <(bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME") >/dev/null && return 0
  log "Service 与原快照不同，按快照恢复 type/nodePort"
  local ports; ports=$(grep "^$SVC " "$RUN_DIR/svc_snapshot.txt" | tr ' ' '\n' | sed -n 's/^\([^=]*\)=\([0-9]*\):\([0-9][0-9]*\)$/{"name":"\1","port":\2,"nodePort":\3}/p' | paste -sd, -)
  [ -n "$ports" ] || return 0
  ksa -n "$NS" patch svc "$SVC" -p "{\"spec\":{\"type\":\"$SVC_TYPE\",\"ports\":[$ports]}}" >/dev/null
  diff <(cat "$RUN_DIR/svc_snapshot.txt") <(bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME"); }
fix_nodeports || die 11 "nodePort 无法恢复为原值（可能已被其他 Service 占用）"
log "Service: $(bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME" | tr '\n' ' ')"
gate recreate "PASS (${RC_SECS}s)"

# ---------- 7. 导入备份并恢复 ----------
step "7. 导入备份到新 MinIO 并 milvus-backup restore"
read_conf || die 12 "读取新实例配置/凭据失败"
start_pf milvus minio etcd || die 12 "port-forward 失败"
T_RS=$(date +%s)
PU=$(python3 "$SCRIPT_DIR/s3tool.py" push "$S3_URL" "$BUCKET" "backup/$BACKUP_NAME/" "$CRED" "$LOCAL_EXPORT") || die 12 "导入备份到新 MinIO 失败: $PU"
log "$PU"
write_backup_yaml
mb list > "$RUN_DIR/backup_list.out" 2>&1 || true
grep -q "$BACKUP_NAME" "$RUN_DIR/backup_list.out" || { tail -20 "$RUN_DIR/backup_list.out"; die 12 "导入后 milvus-backup list 看不到 $BACKUP_NAME"; }
set +e
timeout "$RESTORE_TIMEOUT" "$BIN" --config "$BK_DIR/backup.yaml" restore -n "$BACKUP_NAME" --rebuild_index > "$RUN_DIR/backup_restore.out" 2>&1 < /dev/null
rrc=$?; set -e
tail -25 "$RUN_DIR/backup_restore.out"
[ $rrc = 0 ] || die 12 "milvus-backup restore 失败/超时（rc=$rrc，见 $RUN_DIR/backup_restore.out）"
grep -Eqi 'fail|error' "$RUN_DIR/backup_restore.out" && ! grep -qi 'success' "$RUN_DIR/backup_restore.out" && die 12 "milvus-backup restore 输出含错误"
python3 "$SCRIPT_DIR/probe.py" load --endpoint "http://127.0.0.1:$MV_PORT" --collection '*' --wait 900 | tee "$RUN_DIR/load.out"
[ "${PIPESTATUS[0]}" = 0 ] || die 12 "恢复后加载集合失败"
RS_SECS=$(( $(date +%s) - T_RS ))
gate restore_data "PASS (${RS_SECS}s, $(grep -c '^LOADED' "$RUN_DIR/load.out") 个集合)"

PROBE_RES="跳过（无探针参照）"
if [ -n "$PROBE" ] && [ -n "$PROBE_PRE" ] && [ -f "$PROBE_PRE" ] && [ -f "$PROBE_STATE" ]; then
  step "8. 探针：与备份时记录比对（行数 + top-k）"
  set +e; python3 "$SCRIPT_DIR/probe.py" post --endpoint "http://127.0.0.1:$MV_PORT" --collection "$PROBE" --state "$PROBE_STATE" --pre "$PROBE_PRE" --out "$RUN_DIR/probe_post.json" --wait 300 | tee "$TMP/probe.out"; prc=${PIPESTATUS[0]}; set -e
  PROBE_RES=$(grep -E '^PROBE (MATCH|MISMATCH|ERROR)' "$TMP/probe.out" | tail -1 || true)
  pf_stop
  [ "$prc" = 0 ] || { gate probe FAIL; die 9 "探针不一致: $PROBE_RES"; }
  gate probe PASS
elif [ -n "$PROBE" ]; then PROBE_RES="仅行数: $(grep "^LOADED $PROBE " "$RUN_DIR/load.out" || echo 无)"
fi
pf_stop

# ---------- 9. 校验 ----------
step "9. 校验（镜像/Healthy/Service 与原快照一致，reconcile 后复验）"
bash "$SCRIPT_DIR/verify.sh" "$NS" "$NAME" "$RUN_DIR/svc_snapshot.txt" "$RESTORE_IMAGE" || die 13 "verify 第 1 次失败"
ksa -n "$NS" annotate milvus "$NAME" "milvus.io/reconcile=$(date +%s)" --overwrite >/dev/null
sleep 40
bash "$SCRIPT_DIR/verify.sh" "$NS" "$NAME" "$RUN_DIR/svc_snapshot.txt" "$RESTORE_IMAGE" || die 13 "reconcile 后 verify 失败"
gate verify PASS
ksa -n "$NS" get milvus "$NAME" -o yaml > "$RUN_DIR/cr-after.yaml"
bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME" > "$RUN_DIR/svc_after.txt"

step "10. 报告"
TOTAL=$(( $(date +%s) - T_START ))
{
echo "# Milvus 恢复报告 $NS/$NAME（$(date '+%F %T %Z')）"
echo
echo "| 项目 | 结果 |"
echo "|---|---|"
echo "| 模式 / MQ | $MODE / ${MQ:-rocksmq} |"
echo "| 镜像 恢复前 → 后 | $CUR_IMAGE → $(cr '{.status.currentImage}') |"
echo "| CR 状态 | $(cr '{.status.status}') / MilvusUpdated=$(cr '{.status.conditions[?(@.type=="MilvusUpdated")].status}') |"
echo "| 备份 | $BACKUP_NAME（本地副本 $LOCAL_EXPORT） |"
echo "| 删除的 PVC | ${PVCS[*]:-无} |"
echo "| Service 原快照 | $(tr '\n' ' ' < "$RUN_DIR/svc_snapshot.txt") |"
echo "| Service 恢复后 | $(tr '\n' ' ' < "$RUN_DIR/svc_after.txt") |"
echo "| 删除前探针集合 | $(tr '\n' ' ' 2>/dev/null < "$RUN_DIR/count_before.out" || echo -) |"
echo "| 恢复后集合 | $(grep '^LOADED' "$RUN_DIR/load.out" | sed 's/^LOADED //' | paste -sd';' -) |"
echo "| 探针 | $PROBE_RES |"
echo "| 用时 删除 / 重建 / 导入+恢复+加载 | ${DEL_SECS}s / ${RC_SECS}s / ${RS_SECS}s |"
echo "| 总用时 | ${TOTAL}s |"
for g in "${GATE_ORDER[@]}"; do echo "| 关卡 $g | ${GATE[$g]} |"; done
echo
echo "备份点之后写入的数据已丢失；本地备份副本保留在 $LOCAL_EXPORT（确认无需后可手动删除）。"
} | tee "$RUN_DIR/report.md"
log "ONESHOT OK"
