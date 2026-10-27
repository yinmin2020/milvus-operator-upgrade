#!/bin/bash
# 在本机（Mac/Linux）建立到 K8s master 的 SSH 连接，供后续 ssh/scp 复用。不含任何密码/IP。
# 顺序：已有 ControlMaster → 密钥(BatchMode) → 系统弹窗输入密码(ControlMaster) → 打印手动命令。
#
# 用法：
#   connect.sh [--port N] [--accept-new-hostkey] <master|user@master>   建立连接（默认用户 root）
#   connect.sh --check  [--port N] <master>                              只确认连接是否可用
#   connect.sh --close  [--port N] <master>                              关闭 ControlMaster（结束时必须执行）
#   connect.sh --manual [--port N] <master>                              只打印手动登录命令
# 输出：成功时打印 SSH_OPTS=... 与 CONNECT_RESULT rc=0 mode=key|controlmaster
# 退出码：0 已连接；10 用户取消/弹窗超时；11 密码连续 3 次错误；20 需要用户手动登录；
#         21 首次连接需确认主机指纹；22 主机指纹已变化（停止）；23 助手脚本哈希不符；
#         30 网络/SSH 错误；2 参数错误；1 --check 未连接。
# 安全：密码只由 ssh 通过 SSH_ASKPASS 助手读取，本脚本从不读取、打印、记录密码，也不把密码放进参数。
set +x
umask 077   # 不用 set -u：macOS 自带 bash 3.2 对空数组会误报

# ---- 助手脚本 sha256（发布时生成，改动助手后必须同步更新这里和 SKILL.md）----
EXPECTED_SHA256_ASKPASS_MAC="da5dcd82e5a18cf8e329516a9641030a85ae95424ac3a3e71710a8736abadff5"
EXPECTED_SHA256_ASKPASS_LINUX="506b212a432a25df55e57cb974a9aaa4a5ccc9c4cff6f6ca4f0efa187f68903c"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ASSETS="$(cd "$SCRIPT_DIR/.." && pwd)/assets"
# shellcheck disable=SC2088  # 字面量 ~ 由 ssh 自己展开，用于展示给用户的命令
CP_LITERAL='~/.ssh/cm-%r@%h:%p'
CP="$CP_LITERAL"   # 交给 ssh 自己展开 ~（与用户在终端里手动运行的命令一致）

ACTION=connect; ACCEPT_NEW=0; PORT=""; TARGET=""
usage() { sed -n '2,15p' "$0" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --check) ACTION=check ;;
    --close) ACTION=close ;;
    --manual) ACTION=manual ;;
    --accept-new-hostkey) ACCEPT_NEW=1 ;;
    --port) shift; PORT="${1:-}" ;;
    -h|--help) usage ;;
    -*) echo "未知参数: $1" >&2; usage ;;
    *) [ -z "$TARGET" ] || usage; TARGET="$1" ;;
  esac
  shift
done
[ -n "$TARGET" ] || usage
case "$TARGET" in *[!A-Za-z0-9._@:-]*) echo "master 地址含非法字符" >&2; exit 2 ;; esac
case "$PORT" in ""|*[!0-9]*) [ -z "$PORT" ] || { echo "端口必须是数字" >&2; exit 2; } ;; esac
case "$TARGET" in *@*) ;; *) TARGET="root@$TARGET" ;; esac

finish() { # rc mode
  echo "CONNECT_RESULT rc=$1 mode=$2"
  exit "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 -r "$1" | awk '{print $1}'; fi
}
verify_assets() {
  local f exp got
  for f in askpass_mac.sh:$EXPECTED_SHA256_ASKPASS_MAC askpass_linux.sh:$EXPECTED_SHA256_ASKPASS_LINUX; do
    exp=${f#*:}; f=${f%%:*}
    got=$(sha256_of "$ASSETS/$f" 2>/dev/null || true)
    if [ "$got" != "$exp" ]; then
      echo "CONNECT_ERROR 助手脚本 assets/$f 的 sha256 不符（期望 $exp，实际 ${got:-无}），拒绝使用。请重新安装 skill。" >&2
      finish 23 none
    fi
  done
}

PORT_OPTS=(); PORT_TXT=""
if [ -n "$PORT" ]; then PORT_OPTS=(-o "Port=$PORT"); PORT_TXT=" -o Port=$PORT"; fi
if [ "$ACCEPT_NEW" = 1 ]; then HK_OPTS=(-o StrictHostKeyChecking=accept-new); HK_TXT=" -o StrictHostKeyChecking=accept-new"
else HK_OPTS=(-o StrictHostKeyChecking=yes); HK_TXT=""; fi
SSH_BASE=(-o ConnectTimeout=8 -o LogLevel=ERROR "${PORT_OPTS[@]}" "${HK_OPTS[@]}")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/milvus-connect.XXXXXX") || exit 30
mk_tmp() { mktemp "$WORK/f.XXXXXX"; }
trap 'rm -rf "$WORK"' EXIT

command -v ssh >/dev/null 2>&1 || { echo "CONNECT_ERROR 本机没有 ssh 客户端" >&2; finish 30 none; }
ssh_cfg() { ssh -G "${PORT_OPTS[@]}" -o ControlPath="$CP" "$TARGET" </dev/null 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }
R_HOST=$(ssh_cfg hostname); R_PORT=$(ssh_cfg port); R_USER=$(ssh_cfg user)
R_HOST=${R_HOST:-${TARGET#*@}}; R_PORT=${R_PORT:-22}; R_USER=${R_USER:-root}
SOCK=$(ssh_cfg controlpath)
case "$SOCK" in
  /*%*|/*~*|"") SSH_HOME=$(eval echo "~$(id -un)"); SOCK="$SSH_HOME/.ssh/cm-$R_USER@$R_HOST:$R_PORT" ;;
  /*) ;;
  *) SSH_HOME=$(eval echo "~$(id -un)"); SOCK="$SSH_HOME/.ssh/cm-$R_USER@$R_HOST:$R_PORT" ;;
esac
SSH_DIR=$(dirname "$SOCK")
mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

cm_alive() { ssh "${PORT_OPTS[@]}" -o ControlPath="$CP" -O check "$TARGET" >/dev/null 2>&1; }

print_ok() { # mode
  echo "SSH_OPTS=-o ControlPath=$CP_LITERAL -o BatchMode=yes$PORT_TXT"
  echo "用法示例：ssh -o ControlPath=$CP_LITERAL -o BatchMode=yes$PORT_TXT $TARGET '<命令>'；scp 同样加这些 -o 选项。"
  finish 0 "$1"
}

print_manual() { # reason
  cat <<MANUAL
CONNECT_MANUAL reason=$1
无法自动弹出密码框。请在你自己的终端（Mac：「终端」App；Linux：任意终端）里运行下面这一条命令，
按提示输入 master 的密码（输入时不显示）。命令成功后会立即返回，连接在后台保持 2 小时：

  ssh -fN -o ControlMaster=yes -o 'ControlPath=$CP_LITERAL' -o ControlPersist=2h$PORT_TXT$HK_TXT $TARGET

完成后回到对话，选择「已登录」。密码不要发到对话里。
（Windows 用户请改用 scripts/connect.ps1，它会给出 Windows 的命令。）
MANUAL
  finish 20 none
}

classify_err() { # errfile -> prints category
  local e; e=$(cat "$1" 2>/dev/null)
  case "$e" in
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key for"*"has changed"*) echo hostkey_changed ;;
    *"Host key verification failed"*|*"No "*"host key is known"*) echo hostkey_unknown ;;
    *"Permission denied"*|*"Too many authentication failures"*) echo auth ;;
    *"timed out"*|*"No route to host"*|*"Connection refused"*|*"Could not resolve"*|*"not known"*|*"Network is unreachable"*|*"Connection closed"*|*"Connection reset"*) echo network ;;
    "") echo none ;;
    *) echo other ;;
  esac
}

hostkey_unknown() {
  echo "HOSTKEY_UNKNOWN host=$R_HOST port=$R_PORT"
  if command -v ssh-keyscan >/dev/null 2>&1; then
    ssh-keyscan -T 8 -p "$R_PORT" "$R_HOST" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | while read -r line; do echo "HOSTKEY_FP $line"; done
  fi
  echo "本机 known_hosts 里没有该 master 的主机指纹。请与集群管理员核对上面的指纹，确认后加 --accept-new-hostkey 重跑。"
  finish 21 none
}

handle_fatal() { # category errfile
  case "$1" in
    hostkey_changed) cat "$2" >&2; echo "CONNECT_ERROR master 的主机指纹与 known_hosts 不一致，可能有中间人或主机已重装。已停止，请人工核对。" >&2; finish 22 none ;;
    hostkey_unknown) hostkey_unknown ;;
    network) cat "$2" >&2; echo "CONNECT_ERROR 无法连到 $R_HOST:$R_PORT（网络/端口/域名问题）。" >&2; finish 30 none ;;
  esac
}

key_ok() { ssh "${SSH_BASE[@]}" -o BatchMode=yes -o ControlMaster=no -o ControlPath=none "$TARGET" true </dev/null >/dev/null 2>"$1"; }

# ---------------- 动作 ----------------
case "$ACTION" in
  close)
    if cm_alive; then
      ssh "${PORT_OPTS[@]}" -o ControlPath="$CP" -O exit "$TARGET" >/dev/null 2>&1 || true
      sleep 1
      if cm_alive; then echo "CONNECT_ERROR ControlMaster 仍在运行" >&2; finish 30 none; fi
      echo "已关闭到 $TARGET 的复用连接。"
    else
      echo "没有需要关闭的复用连接。"
    fi
    [ -S "$SOCK" ] && rm -f "$SOCK"
    finish 0 closed ;;
  manual) print_manual requested ;;
  check)
    if cm_alive; then print_ok controlmaster; fi
    e=$(mk_tmp)
    if key_ok "$e"; then print_ok key; fi
    echo "未连接：$(head -n 3 "$e" | tr '\n' ' ')" >&2
    finish 1 none ;;
esac

# connect
verify_assets
if cm_alive; then echo "复用已有连接。"; print_ok controlmaster; fi
[ -S "$SOCK" ] && rm -f "$SOCK"   # 残留的失效 socket

# 1) 密钥
e=$(mk_tmp)
if key_ok "$e"; then
  # 顺便开一个后台复用连接加速后续 ssh/scp；失败不影响
  ssh "${SSH_BASE[@]}" -fN -o BatchMode=yes -o ControlMaster=yes -o ControlPath="$CP" -o ControlPersist=2h \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "$TARGET" </dev/null >/dev/null 2>&1 || true
  print_ok key
fi
cat_=$(classify_err "$e"); handle_fatal "$cat_" "$e"

# 2) 弹窗（需要 OpenSSH >= 8.4 的 SSH_ASKPASS_REQUIRE）
ver=$(ssh -V 2>&1 | sed -n 's/.*OpenSSH_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -n1)
read -r vmaj vmin <<<"${ver:-0 0}"
if [ "${vmaj:-0}" -lt 8 ] || { [ "${vmaj:-0}" -eq 8 ] && [ "${vmin:-0}" -lt 4 ]; }; then
  echo "本机 OpenSSH 版本 ${vmaj:-?}.${vmin:-?} < 8.4，不支持自动弹窗。"
  print_manual ssh_too_old
fi
ENV_DISPLAY=()
case "$(uname -s)" in
  Darwin)
    HELPER="$ASSETS/askpass_mac.sh"
    command -v osascript >/dev/null 2>&1 || print_manual no_osascript
    ENV_DISPLAY=(DISPLAY="${DISPLAY:-:0}") ;;
  Linux)
    HELPER="$ASSETS/askpass_linux.sh"
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then print_manual no_gui; fi
    have=0
    for c in zenity kdialog ssh-askpass ksshaskpass; do command -v "$c" >/dev/null 2>&1 && have=1; done
    for c in /usr/lib/ssh/ssh-askpass /usr/libexec/openssh/ssh-askpass /usr/lib/openssh/gnome-ssh-askpass /usr/libexec/openssh/gnome-ssh-askpass; do [ -x "$c" ] && have=1; done
    [ "$have" = 1 ] || print_manual no_askpass_program ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "当前是 Windows（Git Bash/MSYS）。请改用 PowerShell 运行 scripts/connect.ps1。"
    print_manual windows_use_ps1 ;;
  *) print_manual unsupported_os ;;
esac
[ -x "$HELPER" ] || chmod 755 "$HELPER" 2>/dev/null || print_manual helper_not_executable

echo "即将弹出系统密码框，请在弹窗里输入 master 的密码（120 秒内）。"
for attempt in 1 2 3; do
  st=$(mk_tmp); e=$(mk_tmp)
  env SSH_ASKPASS="$HELPER" SSH_ASKPASS_REQUIRE=force MILVUS_ASKPASS_STATUS="$st" "${ENV_DISPLAY[@]}" \
    ssh "${SSH_BASE[@]}" -fN -o ControlMaster=yes -o ControlPath="$CP" -o ControlPersist=2h \
        -o NumberOfPasswordPrompts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
        "$TARGET" </dev/null >/dev/null 2>"$e"
  rc=$?
  s=$(head -n1 "$st" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && cm_alive; then print_ok controlmaster; fi
  case "$s" in
    cancel) echo "已取消输入密码。"; finish 10 none ;;
    nogui)  print_manual popup_unavailable ;;
  esac
  cat_=$(classify_err "$e"); handle_fatal "$cat_" "$e"
  if [ "$s" = ok ] && [ "$cat_" = auth ]; then
    echo "密码不正确（第 $attempt/3 次）。"
    continue
  fi
  if [ -z "$s" ] && [ "$cat_" = auth ]; then
    echo "CONNECT_ERROR master 没有请求密码（可能禁用了密码登录），也不接受本机密钥。" >&2
    finish 30 none
  fi
  head -n 5 "$e" >&2
  print_manual popup_failed
done
echo "CONNECT_ERROR 密码连续 3 次错误。" >&2
finish 11 none
