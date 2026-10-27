#!/bin/bash
# Linux SSH_ASKPASS 助手：由 ssh 自己调用（connect.sh 设置 SSH_ASKPASS），agent 不得直接运行、包装或重定向本脚本。
# 依次尝试 zenity --password、kdialog --password、系统 ssh-askpass；需要 DISPLAY 或 WAYLAND_DISPLAY。
# 用户输入的内容只经 stdout 交给 ssh；不写文件、不写日志、不进变量。
# 退出码：0 已输入；1 取消/超时/无法弹窗。可选 MILVUS_ASKPASS_STATUS=<文件>：只写入 ok|cancel|nogui（不含密码）。
set +x
set -u
status() { [ -n "${MILVUS_ASKPASS_STATUS:-}" ] && printf '%s\n' "$1" > "$MILVUS_ASKPASS_STATUS" 2>/dev/null; return 0; }
prompt="${1:-Password:}"
case "$prompt" in
  *yes/no*|*fingerprint*) status nogui; exit 1 ;;
esac
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then status nogui; exit 1; fi
title="SSH 登录（Milvus 升级）"
text="登录 K8s master：$prompt"
exec 3>&1
if command -v zenity >/dev/null 2>&1; then
  err=$(zenity --password --title="$title" --timeout=120 2>&1 >&3 3>&-); rc=$?
elif command -v kdialog >/dev/null 2>&1; then
  err=$(kdialog --title "$title" --password "$text" 2>&1 >&3 3>&-); rc=$?
else
  sys=""
  for c in /usr/lib/ssh/ssh-askpass /usr/libexec/openssh/ssh-askpass /usr/lib/openssh/gnome-ssh-askpass /usr/libexec/openssh/gnome-ssh-askpass /usr/bin/ssh-askpass /usr/bin/ksshaskpass; do
    [ -x "$c" ] && { sys="$c"; break; }
  done
  [ -n "$sys" ] || { exec 3>&-; status nogui; exit 1; }
  err=$("$sys" "$text" 2>&1 >&3 3>&-); rc=$?
fi
exec 3>&-
if [ "$rc" -eq 0 ]; then status ok; exit 0; fi
case "$err" in
  *"annot open display"*|*"ould not connect to display"*|*"ailed to connect to"*|*qt.qpa*|*"no display"*) status nogui ;;
  *) status cancel ;;
esac
exit 1
