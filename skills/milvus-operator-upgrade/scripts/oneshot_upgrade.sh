#!/usr/bin/env bash
# milvus-operator 一键原地升级（在 master 上以 root 运行）
# 用法: oneshot_upgrade.sh <NS> --check-only [--name CR] [--target-tag TAG] [TARGET_IMAGE]   # 只读预检，不建任何对象；省略 tag 则列出合法终点
#       oneshot_upgrade.sh <NS> <TARGET_IMAGE> [--name CR] [--backup-bin PATH] [--probe-collection C] [--export-dir DIR]
#                         [--no-export] [--operator-ns ONS] [--upgrade-timeout 1200] [--token-ttl 3h] [--workdir DIR] [--yes]
#                         [--rbac-test [--rbac-test-collection C] [--rbac-test-deny list_users,create_collection]]
# 鉴权（authorizationEnabled=true）：环境变量 MILVUS_TOKEN=user:password（或 MILVUS_TOKEN_FILE=<600 权限文件>），账号须为 root/admin。
#   备份始终带 milvus-backup --rbac（用户/角色/授权）；升级前后各取一份 RBAC 快照比较；可选 --rbac-test 用 MILVUS_TEST_TOKEN（应用用户）验证权限。
# 退出码: 0 成功 | 2 参数/需要选择 CR | 3 环境/前置(admin、NS、CR) | 4 权限/隔离自检 | 5 预检(健康/版本/Service/拉镜像/鉴权凭据无管理员权限)
#         6 备份(含 RBAC 元数据缺失) | 7 升级(超时/CrashLoop/拉取失败) | 8 升级后校验 | 9 探针不一致 | 14 升级后 RBAC 不一致 | 130 中断/未确认
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SA=milvus-upgrader
usage(){ sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------- 参数 ----------
NS=""; TARGET_IMAGE=""; NAME=""; BACKUP_BIN="${MILVUS_BACKUP_BIN:-}"; PROBE=""; ONS=""; YES=0; EXPORT_DIR=""; NO_EXPORT=0
RBAC_TEST=0; RBAC_TEST_COLL=""; RBAC_TEST_DENY=list_users
CHECK_ONLY=0; TARGET_TAG=; UPGRADE_TIMEOUT=1200; PULL_TIMEOUT=900; TOKEN_TTL=3h; WORKBASE=/root/milvus-upgrade
ADMIN_KC=${ADMIN_KUBECONFIG:-${KUBECONFIG:-$HOME/.kube/config}}
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=${2:?}; shift 2;;
    --backup-bin) BACKUP_BIN=${2:?}; shift 2;;
    --probe-collection) PROBE=${2:?}; shift 2;;
    --operator-ns) ONS=${2:?}; shift 2;;
    --export-dir) EXPORT_DIR=${2:?}; shift 2;;
    --no-export) NO_EXPORT=1; shift;;
    --upgrade-timeout) UPGRADE_TIMEOUT=${2:?}; shift 2;;
    --pull-timeout) PULL_TIMEOUT=${2:?}; shift 2;;
    --token-ttl) TOKEN_TTL=${2:?}; shift 2;;
    --workdir) WORKBASE=${2:?}; shift 2;;
    --rbac-test) RBAC_TEST=1; shift;;
    --rbac-test-collection) RBAC_TEST_COLL=${2:?}; shift 2;;
    --rbac-test-deny) RBAC_TEST_DENY=${2:?}; shift 2;;
    --check-only) CHECK_ONLY=1; shift;;
    --target-tag) TARGET_TAG=${2:?}; shift 2;;
    --yes|-y) YES=1; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "未知参数 $1" >&2; usage; exit 2;;
    *) pos+=("$1"); shift;;
  esac
done
if [ $CHECK_ONLY = 1 ]; then
  # 只读预检：不创建目录/文件/集群对象，直接交给 check.py（输出 CHECK*/SUGGEST 行 + 表格 + CHECK_RESULT rc=N）
  [ ${#pos[@]} -ge 1 ] && [ ${#pos[@]} -le 2 ] || { usage; exit 2; }
  [[ ${pos[0]} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "NS 不合法: ${pos[0]}"; echo "CHECK_RESULT rc=2"; exit 2; }
  ca=(upgrade "${pos[0]}" --workdir "$WORKBASE")
  [ -z "$TARGET_TAG" ] || ca+=(--target-tag "$TARGET_TAG")
  [ -z "$NAME" ] || ca+=(--name "$NAME"); [ -z "$BACKUP_BIN" ] || ca+=(--backup-bin "$BACKUP_BIN")
  [ -z "$ONS" ] || ca+=(--operator-ns "$ONS"); [ ${#pos[@]} -lt 2 ] || ca+=(--target-image "${pos[1]}")
  [ $RBAC_TEST = 0 ] || ca+=(--rbac-test)
  ADMIN_KUBECONFIG=$ADMIN_KC exec python3 "$SCRIPT_DIR/check.py" "${ca[@]}"
fi
[ ${#pos[@]} -eq 2 ] || { usage; exit 2; }
NS=${pos[0]}; TARGET_IMAGE=${pos[1]}
[[ $NS =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "NS 不合法: $NS" >&2; exit 2; }
[[ $TARGET_IMAGE =~ ^[^[:space:]]+(:[A-Za-z0-9_.-]+|@sha256:[a-f0-9]{64})$ ]] || { echo "TARGET_IMAGE 需为 仓库/镜像:tag 全路径: $TARGET_IMAGE" >&2; exit 2; }
[ -z "$NAME" ] || [[ $NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "--name 不合法" >&2; exit 2; }

TS=$(date +%Y%m%d%H%M%S)
RUN_DIR="$WORKBASE/runs/${NS}-${TS}"
EXPORT_DIR=${EXPORT_DIR:-$RUN_DIR/backup_export}
mkdir -p "$RUN_DIR"; chmod 700 "$WORKBASE" "$RUN_DIR" 2>/dev/null || true
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
die(){ local rc=$1; shift; echo "[$(ts)] !!!!! 失败(rc=$rc): $*" >&2; exit "$rc"; }
kadm(){ kubectl --kubeconfig "$ADMIN_KC" "$@"; }          # root/管理员：仅限 NS 存在性、operator 定位、RBAC 增删、签 token、(必要时)读指定 secret
ksa(){ kubectl --kubeconfig "$SA_KC" "$@"; }               # 其余全部操作
PF_PIDS=(); RBAC_APPLIED=0; PULL_PODS=()

# 凭据只来自环境变量；MILVUS_TOKEN_FILE / MILVUS_TEST_TOKEN_FILE 指向用户自己在 master 上创建的 600 权限文件（内容 user:password，不经聊天）
load_token(){ # load_token <变量名> <文件变量名>
  local v=$1 fv=$2 f m
  if [ -z "${!v:-}" ] && [ -n "${!fv:-}" ]; then
    f=${!fv}; [ -r "$f" ] || die 5 "$fv 指向的文件不可读: $f"
    m=$(stat -c %a "$f" 2>/dev/null || echo 777); [[ $m =~ ^[0-7]00$ ]] || die 5 "$f 权限为 $m：必须是 600 或 400（chmod 600），避免凭据被其他用户读取"
    printf -v "$v" '%s' "$(head -n1 "$f")"
  fi
  export "${v?}"
}

cleanup(){
  local rc=$?
  set +e
  echo; log "===== 清理（rc=$rc）====="
  for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  [ -n "${SA_KC:-}" ] && pkill -f -- "--kubeconfig $SA_KC" 2>/dev/null   # 兜底：本次运行的所有 SA kubectl 进程
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

# ---------- 风险提示（与 SKILL.md 一致） ----------
cat <<NOTICE
================ 风险提示 ================
将对命名空间 [$NS] 中的 Milvus 按版本路径原地升级到 [$TARGET_IMAGE]（可能多跳；两端对等：可停在 2.6.x 或升到 GA 3.0.y），全程无人值守，任一关卡失败即停止：
1. 按官方文档展开 hops（见 references/upgrade-paths.md）：可能先升 operator≥1.3.7（由你在 operator 命名空间完成，本 skill 不跨 NS 改 operator）、
   Cluster 启用 mixCoord、经 ≥2.5.16 / 2.6.x 桥接，再改 Milvus 镜像；etcd/MinIO/MQ 及其镜像不动。
   每跳设置 securityContext={runAsUser:0, runAsNonRoot:false}（容器以 root 运行）。
   【与官方文档的差异】官方 2.6→3.0 Standalone 只 patch image；这里额外改为 root，因为 2.6 写入的 rocksmq/缓存文件属主是 root，
   3.0 镜像默认非 root 用户启动会 Permission denied/CrashLoop。若安全策略不允许 root 容器，请取消。
   Cluster→3.0：倾向完整 CR apply（显式 indexNode.replicas=0），保留现有拓扑；组件与官方模板差异大时请先非生产验证。
   Service 为 NodePort/LoadBalancer 时把 CR 的 serviceType 固定为同类型（nodePort 漂移则改回快照值）。
2. 在 [$NS] 临时创建 SA/Role/RoleBinding "$SA" 和短期 token，结束（含失败）自动删除；之后所有操作都用该 SA 身份执行。
3. 用 milvus-backup 做全量备份 pre_upgrade_<时间戳>，写入该 Milvus 的 MinIO 桶（backup/ 前缀），不自动删除；
   并完整导出一份到 master 本地 $EXPORT_DIR（MinIO 被删后仍可用 oneshot_restore.sh 恢复；会先检查磁盘空间）。
4. 在 [$NS] 临时创建拉取检查 Pod（milvus-upgrader-pullcheck-N），固定到 Milvus 所在节点，用完即删。
5. 3.0 无法通过改回镜像回滚，只能从备份恢复到新实例；升级期间 Milvus 有短暂停机（standalone 实测 patch→Healthy 约 65 秒，镜像已预拉取）。
除上述对象外，不修改 [$NS] 内其他资源，也不在任何其他命名空间创建或修改对象（由 SA 权限在 API Server 层强制）。
==========================================
NOTICE
if [ "$YES" != 1 ]; then
  [ -r /dev/tty ] || die 130 "非交互运行必须加 --yes（agent 须先向用户展示风险提示并获得确认）"
  read -r -p "确认执行请输入 yes: " ans < /dev/tty; [ "$ans" = yes ] || die 130 "用户未确认"
fi

# ---------- 凭据（环境变量 / 600 权限文件） ----------
load_token MILVUS_TOKEN MILVUS_TOKEN_FILE
[ $RBAC_TEST = 0 ] || load_token MILVUS_TEST_TOKEN MILVUS_TEST_TOKEN_FILE
if [ $RBAC_TEST = 1 ]; then
  [ -n "${MILVUS_TEST_TOKEN:-}" ] && [[ ${MILVUS_TEST_TOKEN:-} == *:* ]] || die 2 "--rbac-test 需要环境变量 MILVUS_TEST_TOKEN=user:password（应用用户，或 MILVUS_TEST_TOKEN_FILE）"
  RBAC_TEST_COLL=${RBAC_TEST_COLL:-$PROBE}
  [ -n "$RBAC_TEST_COLL" ] || die 2 "--rbac-test 需要 --rbac-test-collection（或 --probe-collection）：该用户应有查询权限的集合"
fi

# ---------- 0. 环境 ----------
step "0. 环境检查（root/管理员 context）"
exec 9>"$WORKBASE/.lock-$NS"; flock -n 9 || die 3 "同一 NS 已有升级在运行（锁 $WORKBASE/.lock-$NS）"
command -v kubectl >/dev/null || die 3 "master 上没有 kubectl"
[ -r "$ADMIN_KC" ] || die 3 "找不到管理员 kubeconfig: $ADMIN_KC"
kadm get ns "$NS" -o name >/dev/null || die 3 "命名空间 $NS 不存在或管理员 kubeconfig 不可用"
for v in "create serviceaccounts" "create roles" "create rolebindings" "create serviceaccounts/token"; do
  [ "$(kadm auth can-i $v -n "$NS" 2>/dev/null)" = yes ] || die 3 "管理员 context 无权 $v -n $NS"
done
# operator 位置/镜像只用于报告：管理员 context 只读查询一次（跨命名空间只读，SA 做不到；不创建任何对象）
OP_SEL=app.kubernetes.io/name=milvus-operator
if [ -n "$ONS" ]; then OP_LINE=$(kadm -n "$ONS" get deploy -l $OP_SEL -o jsonpath='{.items[0].metadata.namespace} {.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
else OP_LINE=$(kadm get deploy -A -l $OP_SEL -o jsonpath='{.items[0].metadata.namespace} {.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true); fi
read -r ONS OP_IMAGE <<<"${OP_LINE:-}" || true
log "Milvus NS=$NS  operator NS=${ONS:-<未找到>}  operator 镜像=${OP_IMAGE:-?}  workdir=$RUN_DIR"
gate env PASS

# ---------- 1. SA 与 CR 发现 ----------
step "1. 创建临时 SA（阶段 1：仅可在 $NS 内读取 Milvus CR）并签发短期 token"
RBAC_APPLIED=1
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" - "$SA" | kadm apply -f -
KUBECONFIG="$ADMIN_KC" bash "$SCRIPT_DIR/make_kubeconfig.sh" "$NS" "$TOKEN_TTL" "$SA_KC" "$SA"
export KUBECONFIG="$SA_KC"   # 之后所有普通 kubectl / 子脚本都用 SA 身份
mapfile -t CRS < <(ksa -n "$NS" get milvus -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ -z "$NAME" ]; then
  [ ${#CRS[@]} -eq 0 ] && die 3 "$NS 中没有 Milvus CR"
  [ ${#CRS[@]} -gt 1 ] && { log "NEED_CR_NAME: $NS 中有多个 Milvus CR: ${CRS[*]}"; die 2 "请用 --name 指定要升级的 CR"; }
  NAME=${CRS[0]}
else
  printf '%s\n' "${CRS[@]}" | grep -qx "$NAME" || die 3 "$NS 中没有名为 $NAME 的 Milvus CR（现有: ${CRS[*]:-无}）"
fi
log "目标 CR: $NS/$NAME"

step "1b. 收紧/补全 Role（阶段 2：patch 仅限 milvus/$NAME 与 svc/$NAME-milvus）"
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" "$NAME" "$SA" | kadm apply -f -
bash "$SCRIPT_DIR/gen_rbac.sh" "$NS" "$NAME" "$SA" > "$RUN_DIR/rbac.yaml"

step "2. 隔离自检（SA 身份，跨命名空间必须被 API Server 拒绝）"
iso_fail=0
chk(){ local want=$1; shift; local got; got=$(ksa auth can-i "$@" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then log "OK   can-i $* = $got"; else log "FAIL can-i $* = $got (期望 $want)"; iso_fail=1; fi; }
chk yes patch "milvuses.milvus.io/$NAME" -n "$NS"
chk yes create pods --subresource=portforward -n "$NS"
chk no  patch milvuses.milvus.io/other-cr -n "$NS"
chk no  delete "milvuses.milvus.io/$NAME" -n "$NS"
chk no  get secrets -n "$NS"
chk no  create pods --subresource=exec -n "$NS"
chk no  get pods -n kube-system
chk no  patch deployments -n kube-system
chk no  create configmaps -n default
chk no  get nodes
chk no  list milvuses.milvus.io -A
out=$(ksa get pods -n kube-system 2>&1 || true); log "实测 get pods -n kube-system => $out"
echo "$out" | grep -qi forbidden || iso_fail=1
out=$(ksa -n kube-system create configmap milvus-upgrader-isolation-test --from-literal=a=b --dry-run=server 2>&1 || true)
log "实测 create configmap -n kube-system (dry-run=server) => $out"
echo "$out" | grep -qi forbidden || iso_fail=1
[ $iso_fail = 0 ] || die 4 "SA 权限超出预期（可能有绑定到 system:serviceaccounts 的集群级权限），为安全起见停止"
gate isolation PASS

# ---------- 3. 预检 ----------
step "3. 预检（SA 身份）"
cr(){ ksa -n "$NS" get milvus "$NAME" -o jsonpath="$1"; }
MODE=$(cr '{.spec.mode}'); MODE=${MODE:-standalone}
COMP=standalone; [ "$MODE" = cluster ] && COMP=proxy
CUR_IMAGE=$(cr '{.spec.components.image}')
STATUS=$(cr '{.status.status}')
UPDATED=$(cr '{.status.conditions[?(@.type=="MilvusUpdated")].status}')
PAUSED=$(cr '{.spec.components.paused}')
OPVER=$(cr '{.metadata.labels.milvus\.io/operator-version}')
MQ=$(cr '{.spec.dependencies.msgStreamType}')
PULL_SECRETS=$(cr '{range .spec.components.imagePullSecrets[*]}{.name}{" "}{end}')
CR_SVCTYPE=$(cr "{.spec.components.$COMP.serviceType}"); CR_SVCTYPE=${CR_SVCTYPE:-ClusterIP}
ksa -n "$NS" get milvus "$NAME" -o yaml > "$RUN_DIR/cr-before.yaml"
log "mode=$MODE comp=$COMP status=$STATUS MilvusUpdated=$UPDATED paused=${PAUSED:-false} MQ=${MQ:-?}"
log "当前镜像=$CUR_IMAGE  目标镜像=$TARGET_IMAGE"
log "operator 版本(CR 标签)=${OPVER:-?}  operator 镜像=${OP_IMAGE:-?}  imagePullSecrets=${PULL_SECRETS:-无}"
ALREADY=0
if [ "$CUR_IMAGE" = "$TARGET_IMAGE" ]; then
  if [ "$STATUS" = Healthy ] && [ "$(cr '{.status.currentImage}')" = "$TARGET_IMAGE" ]; then
    ALREADY=1; log "CR 已是目标镜像且 Healthy：跳过备份与升级，只做校验"
  else
    die 5 "CR 已指向目标镜像但未 Healthy（上次升级未完成？status=$STATUS），请按 SKILL.md 失败处理排查"
  fi
fi
[ "$STATUS" = Healthy ] || die 5 "CR status=$STATUS（必须 Healthy）"
[ "$UPDATED" = True ] || die 5 "MilvusUpdated=$UPDATED（必须 True）"
[ "${PAUSED:-false}" != true ] || die 5 "CR paused=true，不能在暂停状态改镜像"
# 版本路径：交由 upgrade_paths.py（官方文档；不强制经 2.6.24）
HAS_MIX=0
MIX_JSON=$(ksa -n "$NS" get milvus "$NAME" -o jsonpath='{.spec.components.mixCoord}' 2>/dev/null || true)
[ -n "$MIX_JSON" ] && [ "$MIX_JSON" != "null" ] && HAS_MIX=1
STATUS_IMG=$(cr '{.status.currentImage}')
POD_IMGS=$(ksa -n "$NS" get pods -l "app.kubernetes.io/instance=$NAME,app.kubernetes.io/name=milvus" -o jsonpath='{range .items[*].spec.containers[*]}{.image}{","}{end}' 2>/dev/null || true)
SRC_LINE=$(python3 "$SCRIPT_DIR/upgrade_paths.py" discover --cr-image "$CUR_IMAGE" --status-image "$STATUS_IMG" --pod-images "$POD_IMGS" | awk '/^SOURCE /{print; exit}')
log "源版本发现: ${SRC_LINE:-none}"
SOURCE_TAG=$(echo "$SRC_LINE" | sed -n 's/.* version=\([^ ]*\).*/\1/p')
[ -n "$SOURCE_TAG" ] || SOURCE_TAG=$(python3 "$SCRIPT_DIR/upgrade_paths.py" parse "$CUR_IMAGE" | awk '/^PARSE ok=1/{print $0}' | sed -n 's/.* tag=\([^ ]*\).*/\1/p')
TARGET_TAG_RESOLVED=$(python3 "$SCRIPT_DIR/upgrade_paths.py" parse "$TARGET_IMAGE" | awk '/^PARSE ok=1/{for(i=1;i<=NF;i++) if($i~/^tag=/){sub(/^tag=/,"",$i); print $i}}')
PATH_OUT=$(mktemp)
set +e
python3 "$SCRIPT_DIR/upgrade_paths.py" plan --source "${SOURCE_TAG:-$CUR_IMAGE}" --target "${TARGET_TAG_RESOLVED:-$TARGET_IMAGE}" \
  --mode "$MODE" --has-mixcoord "$HAS_MIX" --operator "${OPVER:-$OP_IMAGE}" >"$PATH_OUT" 2>&1
prc=$?
set -e
cat "$PATH_OUT" | while IFS= read -r ln; do log "path: $ln"; done
if grep -q '^PATH_BLOCK ' "$PATH_OUT"; then
  die 5 "$(grep '^PATH_BLOCK ' "$PATH_OUT" | head -1 | sed 's/^PATH_BLOCK //')"
fi
[ $prc = 0 ] || [ $ALREADY = 1 ] || die 5 "版本路径规划失败（rc=$prc），见上方 path: 日志"
PATH_PLAN_LINE=$(grep '^PATH_PLAN ' "$PATH_OUT" | tail -1 || true)
HOP_TAGS=$(echo "$PATH_PLAN_LINE" | sed -n 's/.* hops=\([^ ]*\).*/\1/p')
[ "$HOP_TAGS" = "BLOCKED" ] && die 5 "版本路径被阻止"
# 软警告（如 2.6.x < 2.6.20）不阻断
grep '^PATH_WARN ' "$PATH_OUT" >/dev/null && log "注意: 存在 PATH_WARN（不阻断，见 references/upgrade-paths.md）"
log "版本路径计划: ${PATH_PLAN_LINE:-?}（官方文档；已验证参考 2.6.20→3.0.3；不强制 2.6.24）"
# 保存 hop 明细供升级阶段使用
cp "$PATH_OUT" "$RUN_DIR/path_plan.txt"
rm -f "$PATH_OUT"
# 解析 hops → 镜像列表（拉取检查 + 多跳升级）
REPO_BASE=$(python3 -c "import re,sys; s=sys.argv[1]; print(re.sub(r'(@sha256:[0-9a-f]+|:[A-Za-z0-9_.+-]+)$','',s) or 'milvusdb/milvus')" "$TARGET_IMAGE")
HOP_IMAGES=()
HOP_META=()  # tag|enable_mixcoord|require_op|apply_mode
while IFS= read -r hline; do
  tag=$(echo "$hline" | sed -n 's/.* tag=\([^ ]*\).*/\1/p')
  em=$(echo "$hline" | sed -n 's/.* enable_mixcoord=\([01]\).*/\1/p')
  ro=$(echo "$hline" | sed -n 's/.* require_operator_ge=\([^ ]*\).*/\1/p')
  am=$(echo "$hline" | sed -n 's/.* apply_mode=\([^ ]*\).*/\1/p')
  [ -n "$tag" ] || continue
  HOP_IMAGES+=("${REPO_BASE}:${tag}")
  HOP_META+=("${tag}|${em:-0}|${ro:--}|${am:-merge}")
done < <(grep '^HOP ' "$RUN_DIR/path_plan.txt" || true)
if [ ${#HOP_IMAGES[@]} -eq 0 ]; then
  _htag=$(python3 "$SCRIPT_DIR/upgrade_paths.py" parse "$TARGET_IMAGE" | awk '/^PARSE ok=1/{for(i=1;i<=NF;i++) if($i~/^tag=/){sub(/^tag=/,"",$i); print $i}}')
  HOP_IMAGES=("$TARGET_IMAGE")
  HOP_META=("${_htag:-vunknown}|0|-|merge")
fi
log "待执行 hops (${#HOP_IMAGES[@]}): ${HOP_IMAGES[*]}"
bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME" | tee "$RUN_DIR/svc_snapshot.txt"
[ -s "$RUN_DIR/svc_snapshot.txt" ] || die 5 "找不到 $NAME 的 Service"
SVC="$NAME-milvus"
SVC_TYPE=$(ksa -n "$NS" get svc "$SVC" -o jsonpath='{.spec.type}')
NEED_PIN=0
if [ "$SVC_TYPE" != "$CR_SVCTYPE" ]; then
  case "$SVC_TYPE" in NodePort|LoadBalancer) NEED_PIN=1; log "Service type=$SVC_TYPE 但 CR serviceType=$CR_SVCTYPE（带外修改），升级前会固定";;
    *) die 5 "Service type=$SVC_TYPE 与 CR serviceType=$CR_SVCTYPE 不一致且无法自动处理";; esac
fi
mgr=$(ksa -n "$NS" get svc "$SVC" --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\n"}{end}' | sort -u | grep -vx manager || true)
[ -z "$mgr" ] || log "WARN: Service 存在非 operator 写入者: $(echo "$mgr" | tr '\n' ' ')"
gate preflight PASS

# ---------- 4. 拉镜像检查 ----------
MSEL="app.kubernetes.io/instance=$NAME,app.kubernetes.io/name=milvus"
if [ $ALREADY = 0 ]; then
step "4. 目标镜像拉取检查（临时 Pod 固定到 Milvus 所在节点）"
mapfile -t NODES < <(ksa -n "$NS" get pods -l "$MSEL" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -v '^$')
[ ${#NODES[@]} -gt 0 ] || die 5 "找不到 Milvus Pod 所在节点"
[ ${#NODES[@]} -le 10 ] || NODES=("${NODES[@]:0:10}")
ips=""; for s in $PULL_SECRETS; do ips="$ips{\"name\":\"$s\"},"; done; ips="[${ips%,}]"
# 对路径中每个唯一镜像做节点拉取检查
mapfile -t PULL_IMGS < <(printf '%s\n' "${HOP_IMAGES[@]}" | awk 'NF && !seen[$0]++')
log "拉取检查镜像: ${PULL_IMGS[*]}"
i=0
for pull_img in "${PULL_IMGS[@]}"; do
for node in "${NODES[@]}"; do
  pod="milvus-upgrader-pullcheck-$i"; PULL_PODS+=("$pod")
  ksa -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  cat > "$TMP/$pod.json" <<JSON
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"$pod","namespace":"$NS","labels":{"app.kubernetes.io/managed-by":"milvus-oneshot-upgrade"}},
 "spec":{"nodeName":"$node","restartPolicy":"Never","automountServiceAccountToken":false,"imagePullSecrets":$ips,
  "tolerations":[{"operator":"Exists"}],"terminationGracePeriodSeconds":0,
  "containers":[{"name":"pullcheck","image":"$pull_img","imagePullPolicy":"IfNotPresent","command":["/bin/sh","-c","exit 0"],
   "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}
JSON
  ksa create -f "$TMP/$pod.json" >/dev/null
  log "已创建 $pod -> 节点 $node 镜像 $pull_img"; i=$((i+1))
done
done
for pod in "${PULL_PODS[@]}"; do
  t0=$(date +%s); res=""
  while :; do
    phase=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    wr=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    tr=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)
    ec=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
    case "$wr" in ImagePullBackOff|ErrImageNeverPull|InvalidImageName) res="FAIL:$wr"; break;; esac
    if [ "$phase" = Succeeded ]; then res="OK(exit 0，/bin/sh 存在)"; break; fi
    if [ "$phase" = Failed ] || [ -n "$tr" ]; then res="OK(镜像已拉取；容器退出 reason=$tr exit=$ec，可能无 /bin/sh，不影响升级)"; break; fi
    [ $(( $(date +%s) - t0 )) -lt "$PULL_TIMEOUT" ] || { res="FAIL:超时(${PULL_TIMEOUT}s) phase=$phase waiting=$wr"; break; }
    sleep 5
  done
  node=$(ksa -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  log "$pod@$node: $res（耗时 $(( $(date +%s) - t0 ))s）"
  if [[ $res == FAIL* ]]; then
    ksa -n "$NS" get events --field-selector "involvedObject.name=$pod" 2>/dev/null | tail -5 || true
    die 5 "目标镜像在节点 $node 拉取失败: $res（检查镜像地址、仓库连通性与 imagePullSecrets）"
  fi
done
ksa -n "$NS" delete pod "${PULL_PODS[@]}" --ignore-not-found --wait=true >/dev/null; PULL_PODS=()
log "拉取检查 Pod 已删除"
gate image_pull PASS
fi

# ---------- 端口转发工具 ----------
free_port(){ local p=$1; while ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p\$"; do p=$((p+1)); done; echo "$p"; }
PF_PORT=""
pf(){ # pf <tag> <target> <remotePort> <baseLocalPort>  -> 设置 PF_PORT（不在子 shell 中运行，便于记录 PID 并清理）
  local tag=$1 tgt=$2 rp=$3 n=0; PF_PORT=$(free_port "$4")
  # 直接后台运行 kubectl（不要经 ksa 函数，否则 $! 是子 shell，kill 不到 kubectl）
  kubectl --kubeconfig "$SA_KC" -n "$NS" port-forward --address 127.0.0.1 "$tgt" "$PF_PORT:$rp" > "$TMP/pf-$tag.log" 2>&1 &
  PF_PIDS+=($!)
  until grep -q "Forwarding from" "$TMP/pf-$tag.log" 2>/dev/null; do
    n=$((n+1)); [ $n -lt 60 ] || { cat "$TMP/pf-$tag.log" >&2; return 1; }; sleep 0.5; done
}
pf_stop(){ for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; PF_PIDS=(); pkill -f -- "--kubeconfig $SA_KC .*port-forward" 2>/dev/null || true; sleep 1; }

# ---------- 5. 读取 Milvus 配置 ----------
UY="$TMP/user.yaml"
ksa -n "$NS" get cm "$NAME" -o jsonpath='{.data.user\.yaml}' > "$UY" || die 6 "读取 ConfigMap $NAME 失败"
yget(){ # yget a.b[.c]  简易 YAML 取值（operator 生成的 user.yaml 为 2 空格缩进的块格式）
  awk -v want="$1" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    { match($0,/^ */); ind=RLENGTH/2; line=substr($0,RLENGTH+1)
      if (line ~ /^- /) next
      k=line; sub(/:.*/,"",k); v=line; if (index(v,":")) { sub(/^[^:]*:[ ]*/,"",v) } else v=""
      path[ind]=k; p=path[0]; for(i=1;i<=ind;i++) p=p"."path[i]
      if (p==want) { gsub(/^["\x27]|["\x27]$/,"",v); print v; exit } }' "$UY"
}
ETCD_ROOT=$(yget etcd.rootPath); ETCD_ROOT=${ETCD_ROOT:-$NAME}
BUCKET=$(yget minio.bucketName); BUCKET=${BUCKET:-milvus-bucket}
DATA_ROOT=$(yget minio.rootPath); DATA_ROOT=${DATA_ROOT:-files}
MINIO_ADDR=$(yget minio.address); MINIO_PORT=$(yget minio.port); MINIO_PORT=${MINIO_PORT:-9000}
MINIO_SSL=$(yget minio.useSSL); MINIO_SSL=${MINIO_SSL:-false}
CHAN_PREFIX=$(yget msgChannel.chanNamePrefix.cluster); CHAN_PREFIX=${CHAN_PREFIX:-by-dev}
AUTH_ON=$(yget common.security.authorizationEnabled)
AK=$(yget minio.accessKeyID); SK=$(yget minio.secretAccessKey)
CRED="$TMP/minio.cred"; ( umask 077; : > "$CRED" )
if [ -z "$AK" ] || [ -z "$SK" ]; then
  SREF=$(cr '{.spec.dependencies.storage.secretRef}')
  [ -n "$SREF" ] || die 6 "ConfigMap 中没有 MinIO 凭据，CR 也没有 storage.secretRef"
  log "ConfigMap 中无 MinIO 凭据：由 root/管理员 context 只读取 secret/$SREF（$NS）写入 600 临时文件"
  kadm -n "$NS" get secret "$SREF" -o jsonpath='{.data.accesskey}' | base64 -d > "$CRED"; echo >> "$CRED"
  kadm -n "$NS" get secret "$SREF" -o jsonpath='{.data.secretkey}' | base64 -d >> "$CRED"; echo >> "$CRED"
else
  printf '%s\n%s\n' "$AK" "$SK" > "$CRED"
fi
unset AK SK
ETCD_EXT=$(cr '{.spec.dependencies.etcd.external}'); STOR_EXT=$(cr '{.spec.dependencies.storage.external}')
log "备份配置: bucket=$BUCKET dataRoot=$DATA_ROOT backupRoot=backup etcdRoot=$ETCD_ROOT minio=$MINIO_ADDR:$MINIO_PORT ssl=$MINIO_SSL chanPrefix=$CHAN_PREFIX MQ=${MQ:-?} etcdExternal=${ETCD_EXT:-false} storageExternal=${STOR_EXT:-false} 鉴权=${AUTH_ON:-false}"
AUTH_ON=$(echo "${AUTH_ON:-false}" | tr 'A-Z' 'a-z')
if [ "$AUTH_ON" = true ]; then
  [[ ${MILVUS_TOKEN:-} == *:* ]] || die 5 "Milvus 开启了鉴权（authorizationEnabled=true）：需在环境变量 MILVUS_TOKEN=user:password（或 MILVUS_TOKEN_FILE）中提供 root/admin 凭据，备份需要它读取用户/角色/授权。未做任何变更"
  log "鉴权: 开启；将用 MILVUS_TOKEN（用户 ${MILVUS_TOKEN%%:*}，密码不显示）并始终带 --rbac 备份用户/角色/授权"
else
  log "鉴权: 未开启；仍带 --rbac 备份（无自定义用户时 RBAC 元数据只含默认项）"
fi

start_pf_all(){
  pf milvus "svc/$SVC" 19530 41953 || die 6 "port-forward Milvus 失败"; MV_PORT=$PF_PORT
  pf mgmt "svc/$SVC" 9091 41909 || die 6 "port-forward Milvus 9091 失败"; MG_PORT=$PF_PORT
  if [ "${STOR_EXT:-false}" = true ]; then S3_HOST=${MINIO_ADDR}; S3_PORT=$MINIO_PORT
  else S3_HOST=127.0.0.1; msvc=${MINIO_ADDR%%.*}; pf minio "svc/${msvc:-$NAME-minio}" "$MINIO_PORT" 49000 || die 6 "port-forward MinIO 失败"; S3_PORT=$PF_PORT; fi
  if [ "${ETCD_EXT:-false}" = true ]; then ETCD_EP=$(cr '{.spec.dependencies.etcd.endpoints[0]}')
  else pf etcd "svc/$NAME-etcd" 2379 42379 || die 6 "port-forward etcd 失败"; ETCD_EP="127.0.0.1:$PF_PORT"; fi
  log "port-forward: milvus=$MV_PORT mgmt=$MG_PORT minio=$S3_HOST:$S3_PORT etcd=$ETCD_EP（本地端口避开 2379）"
}

# ---------- 6. 探针(前) ----------
PROBE_RES="跳过（未提供 --probe-collection）"
if [ $ALREADY = 0 ]; then
step "5. 端口转发 + 探针(升级前)"
start_pf_all
RBAC_RES="未开启鉴权，未取 RBAC 快照"; RBAC_BK_RES="备份带 --rbac（鉴权未开启，未校验元数据内容）"; RBAC_TEST_RES="未启用（--rbac-test）"; RBAC_RC=0
if [ "$AUTH_ON" = true ]; then
  command -v python3 >/dev/null || die 5 "鉴权开启时 master 需要 python3（RBAC 快照/校验）"
  step "5b. RBAC：校验凭据的管理员能力 + 升级前快照（用户/角色/绑定/授权；不含密码）"
  python3 "$SCRIPT_DIR/probe.py" rbac-check --endpoint "http://127.0.0.1:$MV_PORT" \
    || die 5 "MILVUS_TOKEN 不具备管理员权限或不可用：备份/恢复 RBAC 需要 root 或带 admin 角色的账号。未做任何变更"
  gate rbac_admin PASS
  python3 "$SCRIPT_DIR/probe.py" rbac-snapshot --endpoint "http://127.0.0.1:$MV_PORT" --out "$RUN_DIR/rbac_pre.json" | tee "$TMP/rbac_pre.out" \
    || die 5 "RBAC 快照失败"
  RBAC_PRE_COUNTS=$(sed -n 's/^RBAC SNAPSHOT: //p' "$TMP/rbac_pre.out")
  RBAC_RES="升级前 $RBAC_PRE_COUNTS"
  gate rbac_pre "PASS ($RBAC_PRE_COUNTS)"
  if [ $RBAC_TEST = 1 ]; then
    python3 "$SCRIPT_DIR/probe.py" rbac-authtest --endpoint "http://127.0.0.1:$MV_PORT" --collection "$RBAC_TEST_COLL" --deny "$RBAC_TEST_DENY" | tee "$TMP/rbac_test_pre.out" \
      || die 5 "RBAC 权限测试在升级前就不通过（应用用户的权限/测试参数有问题，先修复；未做任何变更）"
    RBAC_TEST_RES="升级前 $(sed -n 's/^RBAC AUTHTEST PASS: //p' "$TMP/rbac_test_pre.out")"
    gate rbac_authtest_pre PASS
  fi
elif [ $RBAC_TEST = 1 ]; then die 5 "--rbac-test 只在开启鉴权的实例上有意义（authorizationEnabled=false）"
fi
if [ -n "$PROBE" ]; then
  if command -v python3 >/dev/null; then
    python3 "$SCRIPT_DIR/probe.py" pre --endpoint "http://127.0.0.1:$MV_PORT" --collection "$PROBE" --state "$RUN_DIR/probe_state.json" --out "$RUN_DIR/probe_pre.json" \
      || die 5 "探针集合 $PROBE 升级前读取失败（需已 load）"
    gate probe_pre PASS
  else PROBE_RES="跳过（master 无 python3）"; PROBE=""; fi
fi

# ---------- 7. 备份 ----------
step "6. milvus-backup 全量备份"
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
[ -n "$BIN" ] || die 6 "找不到可用的 milvus-backup（master 架构 $MARCH）。这是前置条件，回到 SKILL.md B2：请用户自行下载 https://github.com/zilliztech/milvus-backup/releases/download/v0.6.1/milvus-backup_0.6.1_Linux_${MARCH}.tar.gz（sha256 见 scripts/milvus-backup-sha256.txt），放到 master 的 $WORKBASE/（tarball 或可执行的 milvus-backup 二进制；其他路径用 --backup-bin），或下载到本机后用 scripts/install_backup.sh <master> --from <本地路径> 安装，再重跑 --check-only。agent 不得代为下载"
BVER=$("$BIN" --help 2>&1 | head -1 || true); log "milvus-backup: $BIN  ($BVER)"
BACKUP_NAME="pre_upgrade_${TS}"
CRED_AK=$(sed -n 1p "$CRED"); CRED_SK=$(sed -n 2p "$CRED")
# 鉴权凭据写入 YAML 双引号字符串：转义 \ 和 "，不经 sed（密码里有 | & \ 也安全）；文件 600
yq(){ local x=$1; x=${x//\\/\\\\}; x=${x//\"/\\\"}; printf '%s' "$x"; }
AUTH_YAML=""
if [ -n "${MILVUS_TOKEN:-}" ]; then AUTH_YAML=$(printf '  user: "%s"\n  password: "%s"' "$(yq "${MILVUS_TOKEN%%:*}")" "$(yq "${MILVUS_TOKEN#*:}")"); fi
( umask 077; cat > "$BK_DIR/backup.yaml" <<YAML
configVersion: v2
log: {level: info, console: true, file: {path: "$RUN_DIR/milvus-backup.log"}}
milvus:
$AUTH_YAML
  grpc: {address: 127.0.0.1, port: $MV_PORT}
  management: {endpoint: "http://127.0.0.1:$MG_PORT"}
  replicate: {rpcChannelName: "${CHAN_PREFIX}-replicate-msg"}
  etcd: {endpoints: ["$ETCD_EP"], rootPath: "$ETCD_ROOT"}
  storage:
    provider: minio
    address: "$S3_HOST"
    port: $S3_PORT
    useSSL: $MINIO_SSL
    bucketName: "$BUCKET"
    rootPath: "$DATA_ROOT"
    auth: {type: static, accessKeyID: "$CRED_AK", secretAccessKey: "$CRED_SK"}
backup:
  storage:
    provider: minio
    address: "$S3_HOST"
    port: $S3_PORT
    useSSL: $MINIO_SSL
    bucketName: "$BUCKET"
    rootPath: backup
    auth: {type: static, accessKeyID: "$CRED_AK", secretAccessKey: "$CRED_SK"}
  pauseGC: true
YAML
)
unset CRED_AK CRED_SK AUTH_YAML
cd "$BK_DIR"
mb(){ "$BIN" --config "$BK_DIR/backup.yaml" "$@"; }
T_BK=$(date +%s)
mb check > "$RUN_DIR/backup_check.out" 2>&1 || log "WARN: milvus-backup check 返回非 0（继续，以 create 结果为准）"
tail -15 "$RUN_DIR/backup_check.out"
# 始终带 --rbac（milvus-backup 0.6.1：create --rbac，默认 false）：备份用户、角色、授权、权限组
if ! mb create -n "$BACKUP_NAME" --rbac > "$RUN_DIR/backup_create.out" 2>&1; then tail -30 "$RUN_DIR/backup_create.out"; die 6 "milvus-backup create 失败"; fi
tail -15 "$RUN_DIR/backup_create.out"
grep -qi "success" "$RUN_DIR/backup_create.out" || die 6 "milvus-backup create 未报告成功（见 $RUN_DIR/backup_create.out）"
if grep -qi "etcd client is not initialized" "$RUN_DIR/backup_create.out"; then log "注: 'etcd client is not initialized' 为已知可忽略告警"; fi
mb list > "$RUN_DIR/backup_list.out" 2>&1 || die 6 "backup list 失败"
tail -10 "$RUN_DIR/backup_list.out"
grep -q "$BACKUP_NAME" "$RUN_DIR/backup_list.out" || die 6 "backup list 中没有 $BACKUP_NAME"
mb get -n "$BACKUP_NAME" > "$RUN_DIR/backup_get.out" 2>&1 || die 6 "backup get 失败"
head -40 "$RUN_DIR/backup_get.out"
if grep -Eqi 'BACKUP_FAIL|state.*fail' "$RUN_DIR/backup_get.out"; then die 6 "backup get 显示失败状态"; fi
command -v python3 >/dev/null || die 6 "master 上没有 python3（校验/导出备份需要）"
S3_URL="http$([ "$MINIO_SSL" = true ] && echo s || true)://$S3_HOST:$S3_PORT"
OBJ=$(python3 "$SCRIPT_DIR/s3tool.py" ls "$S3_URL" "$BUCKET" "backup/$BACKUP_NAME/" "$CRED") || die 6 "列 MinIO 对象失败: $OBJ"
log "MinIO $BUCKET/backup/$BACKUP_NAME/: $OBJ"
[[ $OBJ =~ OBJECTS=([0-9]+)\ BYTES=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 0 ] || die 6 "MinIO 中 backup/$BACKUP_NAME/ 下没有对象"
BK_BYTES=${BASH_REMATCH[2]}
# RBAC 元数据校验：备份 meta/full_meta.json（0.6.x；旧版本 backup_meta.json）的 rbac_meta（只取数量，不输出内容；其中含密码哈希，导出副本与 MinIO 备份都要妥善保管）
RBAC_META=$(python3 "$SCRIPT_DIR/s3tool.py" rbacmeta "$S3_URL" "$BUCKET" "backup/$BACKUP_NAME/" "$CRED") || die 6 "读取备份的 RBAC 元数据失败: $RBAC_META"
log "$RBAC_META"
if [ "$AUTH_ON" = true ]; then
  rb_n(){ echo "$RBAC_META" | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }
  [[ $RBAC_META == *present=yes* ]] || { gate backup_rbac "FAIL (备份没有 RBAC 元数据)"; die 6 "开启了鉴权但备份里没有 RBAC 元数据（用户/角色/授权未被备份）。检查 MILVUS_TOKEN 是否为 root/admin、milvus-backup 版本是否为 0.6.1，见 $RUN_DIR/backup_create.out；未升级"; }
  # milvus-backup 的 rbac_meta 不含内置用户 root 与内置角色 admin/public，比较前从快照里去掉它们
  pre_u=$(python3 -c "import json,sys; s=json.load(open(sys.argv[1])); print(len([u for u in s['users'] if u != 'root']), len([r for r in s['roles'] if r not in ('admin', 'public')]))" "$RUN_DIR/rbac_pre.json")
  set -- $pre_u   # 备份里的自定义用户/角色数不得少于备份前快照
  { [ "$(rb_n users)" -ge "$1" ] && [ "$(rb_n roles)" -ge "$2" ]; } || { gate backup_rbac "FAIL (备份 users/roles=$(rb_n users)/$(rb_n roles) 与快照自定义用户/角色 $pre_u 不符)"; die 6 "备份中的 RBAC 用户/角色数与备份前快照不一致（$RBAC_META，快照自定义 users roles=$pre_u）；未升级"; }
  gate backup_rbac "PASS ($RBAC_META)"
  RBAC_BK_RES="备份带 --rbac；$RBAC_META"
else
  RBAC_BK_RES="备份带 --rbac（鉴权未开启）；$RBAC_META"
fi
cd "$RUN_DIR"
T_BK_DONE=$(( $(date +%s) - T_BK ))
gate backup "PASS ($BACKUP_NAME, ${T_BK_DONE}s, $OBJ)"
EXPORT_RES="未导出（--no-export）"
if [ $NO_EXPORT = 0 ]; then
  step "6b. 导出备份到 master 本地（MinIO PVC 被删除后仍可恢复）"
  mkdir -p "$EXPORT_DIR"; chmod 700 "$EXPORT_DIR"
  avail=$(( $(df -Pk "$EXPORT_DIR" | awk 'NR==2{print $4}') * 1024 ))
  need=$(( BK_BYTES + BK_BYTES / 5 + 1073741824 ))
  log "备份大小 ${BK_BYTES}B，$EXPORT_DIR 可用 ${avail}B（需要 ≥ ${need}B）"
  [ "$avail" -ge "$need" ] || die 6 "master 本地磁盘空间不足以导出备份（可用 --export-dir 指向更大的目录，或 --no-export 跳过导出——跳过后删除 MinIO 就无法恢复）"
  T_EX=$(date +%s)
  EX_OUT=$(python3 "$SCRIPT_DIR/s3tool.py" pull "$S3_URL" "$BUCKET" "backup/$BACKUP_NAME/" "$CRED" "$EXPORT_DIR") || die 6 "导出备份失败: $EX_OUT"
  log "$EX_OUT -> $EXPORT_DIR/backup/$BACKUP_NAME/（MANIFEST 含 sha256）"
  [[ $EX_OUT =~ OBJECTS=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" = "$(echo "$OBJ" | sed -n 's/OBJECTS=\([0-9]*\).*/\1/p')" ] || die 6 "导出对象数与 MinIO 不一致"
  EXPORT_RES="$EXPORT_DIR（$EX_OUT，$(( $(date +%s) - T_EX ))s）"
  gate backup_export "PASS ($EX_OUT)"
fi
# 供 oneshot_restore.sh 自动发现：备份名、导出目录、探针参照
{ echo "NS=$NS"; echo "CR=$NAME"; echo "BACKUP_NAME=$BACKUP_NAME"; echo "SOURCE_IMAGE=$CUR_IMAGE"; echo "TARGET_IMAGE=$TARGET_IMAGE"
  echo "EXPORT_DIR=$([ $NO_EXPORT = 0 ] && echo "$EXPORT_DIR")"; echo "PROBE_COLLECTION=$PROBE"
  echo "PROBE_PRE=$([ -f "$RUN_DIR/probe_pre.json" ] && echo "$RUN_DIR/probe_pre.json")"
  echo "PROBE_STATE=$([ -f "$RUN_DIR/probe_state.json" ] && echo "$RUN_DIR/probe_state.json")"
  echo "AUTH_ON=$AUTH_ON"; echo "RBAC_BACKED_UP=$([[ $RBAC_META == *present=yes* ]] && echo 1 || echo 0)"
  echo "RBAC_PRE=$([ -f "$RUN_DIR/rbac_pre.json" ] && echo "$RUN_DIR/rbac_pre.json")"
  echo "RBAC_TEST=$RBAC_TEST"; echo "RBAC_TEST_COLLECTION=$RBAC_TEST_COLL"; echo "RBAC_TEST_DENY=$RBAC_TEST_DENY"; } > "$RUN_DIR/backup.meta"
pf_stop
fi

# ---------- 8. 升级 ----------
T_UP=$(date +%s); UP_SECS=0
if [ $ALREADY = 0 ]; then
step "7. 升级"
if [ $NEED_PIN = 1 ] || { [ "$SVC_TYPE" != ClusterIP ] && [ "$(cr "{.spec.components.$COMP.serviceType}")" != "$SVC_TYPE" ]; }; then
  log "固定 CR spec.components.$COMP.serviceType=$SVC_TYPE"
  ksa -n "$NS" patch milvus "$NAME" --type merge -p "{\"spec\":{\"components\":{\"$COMP\":{\"serviceType\":\"$SVC_TYPE\"}}}}"
  sleep 15
else
  log "CR serviceType 已与 Service 一致（$SVC_TYPE），无需固定"
fi
fix_nodeports(){
  if ! diff <(cat "$RUN_DIR/svc_snapshot.txt") <(bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME"); then
    log "nodePort 漂移，按快照恢复"
    ports=$(grep "^$SVC " "$RUN_DIR/svc_snapshot.txt" | tr ' ' '\n' | sed -n 's/^\([^=]*\)=\([0-9]*\):\([0-9][0-9]*\)$/{"name":"\1","port":\2,"nodePort":\3}/p' | paste -sd, -)
    ksa -n "$NS" patch svc "$SVC" -p "{\"spec\":{\"type\":\"$SVC_TYPE\",\"ports\":[$ports]}}"
    diff <(cat "$RUN_DIR/svc_snapshot.txt") <(bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME") || return 1
  fi; return 0; }
fix_nodeports || die 7 "固定 serviceType 后 nodePort 无法恢复"
log "nodePort 与快照一致"
T_UP=$(date +%s)
wait_hop_healthy(){
  local hop_img=$1 hop_tag=$2
  local lastp=-100 el st up ci pods allnew crash pb ready
  while :; do
    el=$(( $(date +%s) - T_HOP ))
    st=$(cr '{.status.status}'); up=$(cr '{.status.conditions[?(@.type=="MilvusUpdated")].status}'); ci=$(cr '{.status.currentImage}')
    pods=$(ksa -n "$NS" get pods -l "$MSEL" -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.containers[0].image}|{.status.containerStatuses[0].ready}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].state.waiting.reason}|{.metadata.deletionTimestamp}{"\n"}{end}')
    if [ $(( el - lastp )) -ge 30 ]; then lastp=$el
      log "hop $hop_tag t+${el}s status=$st MilvusUpdated=$up currentImage=${ci##*/}"; echo "$pods" | sed 's/^/      /'; fi
    allnew=$(echo "$pods" | awk -F'|' -v img="$hop_img" 'NF{n++; if($2==img && $3=="true" && $6=="") ok++} END{print (n>0 && n==ok)?1:0}')
    if [ "$st" = Healthy ] && [ "$up" = True ] && [ "$ci" = "$hop_img" ] && [ "$allnew" = 1 ]; then return 0; fi
    if [ "$st" = Healthy ] && [ "$up" = True ] && [ "$ci" = "$hop_img" ]; then
      ready=$(echo "$pods" | awk -F'|' 'NF{n++; if($3=="true" && $6=="") ok++} END{print (n>0 && n==ok)?1:0}')
      [ "$ready" = 1 ] && return 0
    fi
    crash=$(echo "$pods" | awk -F'|' -v img="$hop_img" '$2==img && $5=="CrashLoopBackOff" && $4>=3 {print $1}' | head -1)
    if [ -n "$crash" ]; then
      log "Pod $crash CrashLoopBackOff，上一次容器日志（末 60 行）:"; ksa -n "$NS" logs "$crash" --previous --tail=60 || true
      die 7 "hop $hop_tag 后 CrashLoop（见上方日志与 SKILL.md 附录坑位）"
    fi
    pb=$(echo "$pods" | awk -F'|' '$5=="ImagePullBackOff"||$5=="ErrImagePull" {print $1}' | head -1)
    if [ -n "$pb" ] && [ $el -ge 300 ]; then die 7 "hop $hop_tag: Pod $pb 拉取镜像失败超过 300s"; fi
    [ $el -lt "$UPGRADE_TIMEOUT" ] || die 7 "hop $hop_tag 等待 Healthy 超时（${UPGRADE_TIMEOUT}s）"
    sleep 10
  done
}
apply_hop(){
  local hop_img=$1 tag=$2 em=$3 am=$4
  local patch_json cr_yaml comps
  if [ "$am" = cluster_full_cr ]; then
    log "hop $tag: Cluster 完整 CR apply（image=$hop_img，显式 indexNode.replicas=0 + securityContext root）"
    cr_yaml="$TMP/cr-hop-${tag}.yaml"
    ksa -n "$NS" get milvus "$NAME" -o yaml > "$cr_yaml"
    comps=$(python3 "$SCRIPT_DIR/rewrite_cr_for_3_0.py" "$cr_yaml" "$hop_img" | awk -F= '/^COMP_KEYS=/{print $2}')
    log "hop $tag: apply 前 components keys=[${comps:-?}]（若与官方 3.0 Cluster 模板差异大，请先非生产验证）"
    ksa -n "$NS" apply -f "$cr_yaml"
  else
    patch_json="{\"spec\":{\"components\":{\"image\":\"$hop_img\",\"securityContext\":{\"runAsUser\":0,\"runAsNonRoot\":false}"
    if [ "$em" = 1 ]; then
      log "hop $tag: merge patch image + 启用 mixCoord（2.5→2.6 官方要求）"
      patch_json="${patch_json},\"mixCoord\":{}"
    else
      log "hop $tag: merge patch image + securityContext"
    fi
    patch_json="${patch_json}}}}"
    ksa -n "$NS" patch milvus "$NAME" --type merge -p "$patch_json"
  fi
}
hop_i=0
for meta in "${HOP_META[@]}"; do
  hop_i=$((hop_i+1))
  IFS='|' read -r tag em ro am <<<"$meta"
  hop_img="${REPO_BASE}:${tag}"
  [ "$ro" = "-" ] || [ -z "$ro" ] || log "hop $tag 要求 operator≥$ro（预检已校验；本 skill 不跨 NS 升级 operator）"
  step "7.$hop_i 升级 hop → $tag ($am)"
  T_HOP=$(date +%s)
  apply_hop "$hop_img" "$tag" "$em" "$am"
  fix_nodeports || die 7 "hop $tag 后 nodePort 无法恢复"
  wait_hop_healthy "$hop_img" "$tag"
  log "hop $tag 完成：Healthy，用时 $(( $(date +%s) - T_HOP ))s"
done
UP_SECS=$(( $(date +%s) - T_UP ))
log "全部 hops 完成：Healthy，最终镜像 $TARGET_IMAGE，总用时 ${UP_SECS}s"
gate upgrade "PASS (${#HOP_META[@]} hops, ${UP_SECS}s)"
fi

# ---------- 9. 校验 ----------
step "8. 升级后校验"
bash "$SCRIPT_DIR/verify.sh" "$NS" "$NAME" "$RUN_DIR/svc_snapshot.txt" "$TARGET_IMAGE" || die 8 "verify 第 1 次失败"
ksa -n "$NS" annotate milvus "$NAME" "milvus.io/reconcile=$(date +%s)" --overwrite >/dev/null
log "已加 milvus.io/reconcile 注解，等待 40s 后复验"
sleep 40
bash "$SCRIPT_DIR/verify.sh" "$NS" "$NAME" "$RUN_DIR/svc_snapshot.txt" "$TARGET_IMAGE" || die 8 "reconcile 后 verify 失败"
gate verify PASS
ksa -n "$NS" get milvus "$NAME" -o yaml > "$RUN_DIR/cr-after.yaml"
bash "$SCRIPT_DIR/snapshot_svc.sh" "$NS" "$NAME" > "$RUN_DIR/svc_after.txt"

if [ -n "$PROBE" ]; then
  step "9. 探针(升级后)"
  if [ ! -f "$RUN_DIR/probe_pre.json" ]; then PROBE_RES="跳过（本次未做升级前探针）"
  else
    pf milvus "svc/$SVC" 19530 41953 || die 9 "port-forward Milvus 失败"; MV_PORT=$PF_PORT
    set +e; python3 "$SCRIPT_DIR/probe.py" post --endpoint "http://127.0.0.1:$MV_PORT" --collection "$PROBE" --state "$RUN_DIR/probe_state.json" --out "$RUN_DIR/probe_post.json" --wait 300 | tee "$TMP/probe.out"; prc=${PIPESTATUS[0]}; set -e
    PROBE_RES=$(grep -E '^PROBE (MATCH|MISMATCH|ERROR)' "$TMP/probe.out" | tail -1 || true)
    pf_stop
    [ "$prc" = 0 ] || { gate probe "FAIL"; die 9 "探针不一致或不可查询: $PROBE_RES"; }
    gate probe PASS
  fi
fi

if [ "$AUTH_ON" = true ] && [ -f "$RUN_DIR/rbac_pre.json" ]; then
  step "9b. RBAC 升级后比较（用户/角色/绑定/授权）"
  pf milvus "svc/$SVC" 19530 41953 || die 9 "port-forward Milvus 失败"; MV_PORT=$PF_PORT
  set +e
  python3 "$SCRIPT_DIR/probe.py" rbac-compare --endpoint "http://127.0.0.1:$MV_PORT" --pre "$RUN_DIR/rbac_pre.json" --out "$RUN_DIR/rbac_post.json" --wait 300 | tee "$TMP/rbac_post.out"; rrc=${PIPESTATUS[0]}
  if [ $RBAC_TEST = 1 ] && [ "$rrc" = 0 ]; then
    python3 "$SCRIPT_DIR/probe.py" rbac-authtest --endpoint "http://127.0.0.1:$MV_PORT" --collection "$RBAC_TEST_COLL" --deny "$RBAC_TEST_DENY" | tee "$TMP/rbac_test_post.out"; rrc=${PIPESTATUS[0]}
    RBAC_TEST_RES="$RBAC_TEST_RES；升级后 $(grep -E '^RBAC AUTHTEST' "$TMP/rbac_test_post.out" | head -1)"
  fi
  set -e
  pf_stop
  RBAC_RES="$RBAC_RES；升级后 $(grep -E '^RBAC (MATCH|MISMATCH|COMPARE ERROR)' "$TMP/rbac_post.out" | tail -1)"
  if [ "$rrc" != 0 ]; then gate rbac "FAIL"; RBAC_RC=14; else gate rbac PASS; fi
fi

# ---------- 10. 报告 ----------
step "10. 报告"
TOTAL=$(( $(date +%s) - T_START ))
{
echo "# Milvus 升级报告 $NS/$NAME（$(date '+%F %T %Z')）"
echo
echo "| 项目 | 结果 |"
echo "|---|---|"
echo "| 模式 / MQ | $MODE / ${MQ:-?} |"
echo "| operator | ${OPVER:-?} (${OP_IMAGE:-?}) |"
echo "| 镜像 升级前 → 后 | $CUR_IMAGE → $(cr '{.status.currentImage}') |"
echo "| CR 状态 | $(cr '{.status.status}') / MilvusUpdated=$(cr '{.status.conditions[?(@.type=="MilvusUpdated")].status}') |"
echo "| Service 升级前 | $(tr '\n' ' ' < "$RUN_DIR/svc_snapshot.txt") |"
echo "| Service 升级后 | $(tr '\n' ' ' < "$RUN_DIR/svc_after.txt") |"
if [ -n "${BACKUP_NAME:-}" ]; then echo "| 备份 | $BACKUP_NAME @ ${BUCKET:-?}/backup/ |"; echo "| 备份本地导出 | $EXPORT_RES |"; else echo "| 备份 | 已是目标版本，本次未备份 |"; fi
echo "| 探针 | $PROBE_RES |"
echo "| 鉴权 / RBAC | AUTH_ON=$AUTH_ON；$RBAC_RES |"
echo "| RBAC 备份 | ${RBAC_BK_RES:-已是目标版本，本次未备份} |"
echo "| RBAC 应用用户权限测试 | $RBAC_TEST_RES |"
echo "| 升级用时（patch→Healthy） | ${UP_SECS}s |"
echo "| 总用时 | ${TOTAL}s |"
for g in "${GATE_ORDER[@]}"; do echo "| 关卡 $g | ${GATE[$g]} |"; done
echo
if [ -n "${BACKUP_NAME:-}" ]; then echo "回滚：3.x 不可改回旧镜像；一键恢复: bash $SCRIPT_DIR/oneshot_restore.sh $NS $CUR_IMAGE --name $NAME --backup $BACKUP_NAME（会删除当前实例及其数据，备份点之后写入的数据丢失）。"; fi
} | tee "$RUN_DIR/report.md"
if [ "$RBAC_RC" != 0 ]; then
  log "ONESHOT PARTIAL: 升级已完成，但 RBAC（用户/角色/授权）升级后与升级前不一致或应用用户权限测试失败，不能算完整成功（见上方 RBAC DIFF / AUTHTEST）。备份已含 RBAC，必要时可走一键恢复"
  exit "$RBAC_RC"
fi
log "ONESHOT OK"
