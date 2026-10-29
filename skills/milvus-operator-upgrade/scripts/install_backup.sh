#!/bin/bash
# 把用户自己下载到本机的 milvus-backup（tarball 或二进制）校验后装到 master 工作目录。本脚本不联网下载，不碰 k8s。
# 前提：已用 connect.sh 建立连接（复用 ControlMaster；Windows tmpkey/WSL 场景用 --key）。
#
# 用法：
#   install_backup.sh [--port N] [--key FILE] [--workdir DIR] [--allow-unverified] <master|user@master> --from <本地 tarball 或二进制>
#     --from              用户提供的本地文件：官方 milvus-backup_0.6.1_Linux_<arch>.tar.gz 或解出的 milvus-backup 二进制
#     --workdir           master 上的工作目录，默认 /root/milvus-upgrade（与 oneshot_*.sh 的 --workdir 一致）
#     --key               额外使用 -i FILE -o IdentitiesOnly=yes（临时密钥场景）
#     --allow-unverified  仅当用户在选项里明确选择「仍然使用（未经验证）」时才加：sha256 不在已知清单或版本不是 0.6.1 时只警告不拒绝
# 流程：ssh uname -m 判断架构 → master 已有已知 0.6.1 二进制则跳过 → 本机 sha256 对照 scripts/milvus-backup-sha256.txt →
#       scp 到 <workdir> → master 上校验传输后 sha256 → 解出/放置 <workdir>/milvus-backup → ELF 架构、二进制 sha256、--help 自检。
#       只写 <workdir> 内的文件；<workdir>/milvus-backup 若是其他文件，先改名为 milvus-backup.bak-<时间戳>。
# 输出最后一行：BACKUP_INSTALL rc=N path=<路径> action=installed|skipped|none arch=<arch> verified=yes|no|-
# 退出码：0 已安装/已存在；1 ssh 不通（先运行 connect.sh）；2 参数错误或本地文件不存在；3 master 架构不支持或文件架构与 master 不符；
#         4 sha256 不在已知 0.6.1 清单（可能被篡改/下载不完整，拒绝）；5 传输、解压或 master 端校验失败；6 二进制自检失败；
#         7 版本不是 0.6.1（只验证过 0.6.1，拒绝）。
set +x
umask 077

MB_VER=0.6.1
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SUMS="$SCRIPT_DIR/milvus-backup-sha256.txt"
# shellcheck disable=SC2088  # 字面量 ~ 由 ssh 自己展开
CP_LITERAL='~/.ssh/cm-%r@%h:%p'

PORT=""; KEY=""; WB=/root/milvus-upgrade; TARGET=""; ARCH="?"; DEST=""; FROM=""; ALLOW=0; VERIFIED="-"
usage() { sed -n '2,/^set +x/{/^#/p;}' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --port) shift; PORT="${1:-}" ;;
    --key) shift; KEY="${1:-}" ;;
    --workdir) shift; WB="${1:-}" ;;
    --from) shift; FROM="${1:-}" ;;
    --allow-unverified) ALLOW=1 ;;
    -h|--help) usage ;;
    -*) echo "未知参数: $1" >&2; usage ;;
    *) [ -z "$TARGET" ] || usage; TARGET="$1" ;;
  esac
  shift
done
if [ -z "$TARGET" ] || [ -z "$FROM" ]; then usage; fi
case "$TARGET" in *[!A-Za-z0-9._@:-]*) echo "master 地址含非法字符" >&2; exit 2 ;; esac
case "$PORT" in *[!0-9]*) echo "端口必须是数字" >&2; exit 2 ;; esac
case "$WB" in /*) ;; *) echo "--workdir 必须是绝对路径" >&2; exit 2 ;; esac
case "$WB" in *[!A-Za-z0-9._/-]*|*..*|/) echo "--workdir 含非法字符" >&2; exit 2 ;; esac
WB=${WB%/}
case "$TARGET" in *@*) ;; *) TARGET="root@$TARGET" ;; esac
if [ -n "$KEY" ] && [ ! -f "$KEY" ]; then echo "密钥文件不存在: $KEY" >&2; exit 2; fi

finish() { # rc action
  echo "BACKUP_INSTALL rc=$1 path=${DEST:--} action=$2 arch=$ARCH verified=$VERIFIED"
  exit "$1"
}
err() { echo "BACKUP_INSTALL_ERROR $*" >&2; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 -r "$1" | awk '{print $1}'; fi
}
known_name() { awk -v h="$1" '!/^#/ && $1==h {print $2; exit}' "$SUMS"; }
known_sha() { awk -v n="$1" '!/^#/ && $2==n {print $1; exit}' "$SUMS"; }

[ -f "$SUMS" ] || { err "缺少 scripts/milvus-backup-sha256.txt（skill 不完整，请重新安装 skill）"; finish 2 none; }
if [ ! -f "$FROM" ] || [ ! -r "$FROM" ]; then err "本地文件不存在或不可读: $FROM（请确认用户给出的路径）"; finish 2 none; fi

OPTS=(-o "ControlPath=$CP_LITERAL" -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR)
[ -n "$PORT" ] && OPTS+=(-o "Port=$PORT")
[ -n "$KEY" ] && OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
# shellcheck disable=SC2029  # 远端命令里的 $WB 等有意在本机展开（已校验字符集）
rssh() { ssh "${OPTS[@]}" "$TARGET" "$@"; }

# 1. 架构 + 现有二进制
if ! PROBE=$(rssh "uname -m; f='$WB/milvus-backup'; [ -d \"\$f\" ] && f=\"\$f/milvus-backup\"; echo \"DEST \$f\"; if [ -f \"\$f\" ]; then sha256sum \"\$f\" | awk '{print \"HAVE \" \$1}'; fi" </dev/null 2>&1); then
  err "无法通过 ssh 连接 $TARGET（先运行 scripts/connect.sh 建立连接）: $(echo "$PROBE" | tail -n 2 | tr '\n' ' ')"
  finish 1 none
fi
M=$(echo "$PROBE" | sed -n 1p | tr -d '\r')
DEST=$(echo "$PROBE" | sed -n 's/^DEST //p' | tr -d '\r')
HAVE=$(echo "$PROBE" | sed -n 's/^HAVE //p' | tr -d '\r')
case "$M" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) ARCH="${M:-?}"; err "master 架构 ${M:-未知} 不受支持（milvus-backup 官方 Linux 包只有 x86_64 / arm64）"; finish 3 none ;;
esac
case "$DEST" in "$WB"/milvus-backup|"$WB"/milvus-backup/milvus-backup) ;; *) err "远端返回异常: $PROBE"; finish 5 none ;; esac
TGZ_NAME="milvus-backup_${MB_VER}_Linux_${ARCH}.tar.gz"
URL="https://github.com/zilliztech/milvus-backup/releases/download/v${MB_VER}/$TGZ_NAME"
SHA_TGZ=$(known_sha "$TGZ_NAME"); SHA_BIN=$(known_sha "milvus-backup_${MB_VER}_Linux_${ARCH}/milvus-backup")
if [ -z "$SHA_TGZ" ] || [ -z "$SHA_BIN" ]; then err "milvus-backup-sha256.txt 中没有 $ARCH 的条目（skill 不完整）"; finish 2 none; fi

# 2. master 上已有已知 0.6.1 二进制 → 跳过（仍做一次自检）
if [ "$HAVE" = "$SHA_BIN" ]; then
  if rssh "cd /tmp && '$DEST' --help 2>&1 | head -1 | grep -q '^$MB_VER '" </dev/null; then
    VERIFIED=yes; echo "master 上已有 milvus-backup $MB_VER（sha256 与官方一致），跳过安装"
    finish 0 skipped
  fi
fi

# 3. 本机校验用户提供的文件
GOT=$(sha256_of "$FROM")
KNAME=$(known_name "$GOT")
if head -c 2 "$FROM" | od -An -tx1 | tr -d ' \n' | grep -q '^1f8b$'; then KIND=tgz; else KIND=bin; fi
if [ -n "$KNAME" ]; then
  VERIFIED=yes
  case "$KNAME" in *.tar.gz) KIND=tgz ;; *) KIND=bin ;; esac
  FARCH=$(echo "$KNAME" | sed -nE 's/.*_Linux_(x86_64|arm64).*/\1/p')
  if [ "$FARCH" != "$ARCH" ]; then
    err "文件是 $FARCH 版（$KNAME），master 是 $ARCH。请下载 $URL（sha256 $SHA_TGZ）"
    finish 3 none
  fi
  echo "本地文件 sha256 与官方 $KNAME 一致"
else
  VERIFIED=no
  FVER=$(basename "$FROM" | sed -n 's/^milvus-backup_\([0-9][0-9A-Za-z.+-]*\)_.*/\1/p')
  if [ -n "$FVER" ] && [ "$FVER" != "$MB_VER" ]; then
    if [ "$ALLOW" != 1 ]; then
      err "文件版本是 $FVER，本 skill 只验证过 milvus-backup $MB_VER，拒绝使用。请下载 $URL（sha256 $SHA_TGZ）"
      finish 7 none
    fi
    echo "WARN: 版本 $FVER 未经验证（用户已明确选择仍然使用）"
  fi
  if [ "$ALLOW" != 1 ]; then
    err "sha256 不符：$FROM 的 sha256=$GOT，不在已知 $MB_VER 清单中（期望 tarball $SHA_TGZ 或二进制 $SHA_BIN）。文件可能被篡改、下载不完整或不是 $ARCH 版，拒绝使用。请从 $URL 重新下载"
    finish 4 none
  fi
  echo "WARN: sha256=$GOT 未经验证（用户已明确选择仍然使用）"
  if [ "$KIND" = bin ]; then
    EM=$(od -An -tu2 -j18 -N2 "$FROM" 2>/dev/null | tr -d ' \n')
    case "$EM:$ARCH" in 62:x86_64|183:arm64) ;; 62:*|183:*) err "二进制架构（e_machine=$EM）与 master $ARCH 不符"; finish 3 none ;; *) ;; esac
  fi
fi

# 4. 传输（临时文件名不匹配 milvus-backup_*_Linux_*.tar.gz，避免被脚本误用）
UP="$WB/.mb-install-$$.up"
rssh "mkdir -p '$WB' && chmod 700 '$WB'" </dev/null || { err "无法创建 $WB"; finish 5 none; }
# master 关闭了 sftp 子系统时新版 scp 会失败，回退为经 ssh 直接写入（同一连接，内容同样校验 sha256）
if ! scp -q "${OPTS[@]}" "$FROM" "$TARGET:$UP" </dev/null 2>/dev/null; then
  if ! rssh "cat > '$UP'" < "$FROM"; then
    rssh "rm -f '$UP'" </dev/null >/dev/null 2>&1
    err "传输失败（scp 与 ssh 均失败）"; finish 5 none
  fi
fi

# 5. master 端：传输校验 → 解压/放置 → 架构、二进制 sha256、--help 自检 → 替换
# 注：本 heredoc 位于 $( ) 内，case 分支一律写成 (pattern)，否则 macOS 自带 bash 3.2 解析报 syntax error near `;;`
OUT=$(rssh "bash -s" <<REMOTE 2>&1
set -u
UP='$UP'; DEST='$DEST'; WB='$WB'; TMPD="\$WB/.mb-install-$$.d"; ALLOW='$ALLOW'
cleanup(){ rm -rf "\$UP" "\$TMPD"; }
trap cleanup EXIT
s=\$(sha256sum "\$UP" | awk '{print \$1}')
[ "\$s" = '$GOT' ] || { echo "REMOTE_ERR 5 传输后 sha256 不一致: \$s"; exit 5; }
mkdir -p "\$TMPD" || { echo "REMOTE_ERR 5 无法创建临时目录"; exit 5; }
if [ '$KIND' = tgz ]; then
  tar -xzf "\$UP" -C "\$TMPD" milvus-backup || { echo "REMOTE_ERR 5 解压失败（tarball 里应有 milvus-backup）"; exit 5; }
else
  cp "\$UP" "\$TMPD/milvus-backup" || { echo "REMOTE_ERR 5 复制失败"; exit 5; }
fi
em=\$(od -An -tu2 -j18 -N2 "\$TMPD/milvus-backup" 2>/dev/null | tr -d ' \n')
case "\$em:$ARCH" in (62:x86_64|183:arm64) ;; (*) echo "REMOTE_ERR 3 二进制架构（e_machine=\$em）与 master $ARCH 不符或不是 ELF"; exit 3 ;; esac
b=\$(sha256sum "\$TMPD/milvus-backup" | awk '{print \$1}')
if [ "\$b" != '$SHA_BIN' ]; then
  [ "\$ALLOW" = 1 ] || { echo "REMOTE_ERR 4 二进制 sha256 不符: \$b（期望 $SHA_BIN）"; exit 4; }
  echo "WARN: 二进制 sha256=\$b 未经验证"
fi
chmod 755 "\$TMPD/milvus-backup"
h=\$(cd "\$TMPD" && ./milvus-backup --help 2>&1 | head -1)
case "\$h" in ('$MB_VER '*) ;;
  ([0-9]*' '*) [ "\$ALLOW" = 1 ] || { echo "REMOTE_ERR 7 版本不是 $MB_VER: \$h"; exit 7; }; echo "WARN: 版本 \$h 未经验证" ;;
  (*) echo "REMOTE_ERR 6 --help 自检失败: \$h"; exit 6 ;;
esac
if [ -e "\$DEST" ]; then mv -f "\$DEST" "\$DEST.bak-\$(date +%Y%m%d%H%M%S)" && echo "已把原有 \$DEST 改名为 .bak-*"; fi
mv -f "\$TMPD/milvus-backup" "\$DEST" || { echo "REMOTE_ERR 5 写入 \$DEST 失败"; exit 5; }
echo "REMOTE_OK \$h"
REMOTE
)
RRC=$?
echo "$OUT" | grep -v '^REMOTE_' || true
if [ $RRC -ne 0 ] || ! echo "$OUT" | grep -q '^REMOTE_OK'; then
  E=$(echo "$OUT" | sed -n 's/^REMOTE_ERR \([0-9]*\) .*/\1/p' | head -1)
  err "$(echo "$OUT" | sed -n 's/^REMOTE_ERR [0-9]* //p' | head -1)"
  case "$E" in 3|4|6|7) finish "$E" none ;; esac
  finish 5 none
fi
echo "milvus-backup $(echo "$OUT" | sed -n 's/^REMOTE_OK //p') 已安装到 $DEST"
finish 0 installed
