#!/bin/bash
# macOS SSH_ASKPASS 助手：由 ssh 自己调用（connect.sh 设置 SSH_ASKPASS），agent 不得直接运行、包装或重定向本脚本。
# 弹出系统密码框（隐藏输入），用户输入的内容只经 stdout 交给 ssh；不写文件、不写日志、不进变量。
# 退出码：0 已输入；1 取消/超时/无法弹窗。可选 MILVUS_ASKPASS_STATUS=<文件>：只写入 ok|cancel|nogui（不含密码）。
set +x
set -u
status() { [ -n "${MILVUS_ASKPASS_STATUS:-}" ] && printf '%s\n' "$1" > "$MILVUS_ASKPASS_STATUS" 2>/dev/null; return 0; }
prompt="${1:-Password:}"
case "$prompt" in
  *yes/no*|*fingerprint*) status nogui; exit 1 ;;   # 主机指纹确认不走弹窗，由 connect.sh 处理
esac
command -v osascript >/dev/null 2>&1 || { status nogui; exit 1; }
exec 3>&1
# stdout(fd3) 直接交给 ssh；只捕获 stderr 判断是取消还是无法弹窗
err=$(osascript - "$prompt" 2>&1 >&3 3>&- <<'APPLESCRIPT'
on run argv
  set p to item 1 of argv
  tell me to activate
  set r to display dialog ("Milvus 升级：登录 K8s master" & return & return & p) default answer "" with hidden answer with title "SSH 登录" buttons {"取消", "登录"} default button "登录" cancel button "取消" with icon caution giving up after 120
  if gave up of r then error "timeout" number -128
  return text returned of r
end run
APPLESCRIPT
)
rc=$?
exec 3>&-
if [ "$rc" -eq 0 ]; then status ok; exit 0; fi
case "$err" in
  *-128*) status cancel ;;
  *) status nogui ;;
esac
exit 1
