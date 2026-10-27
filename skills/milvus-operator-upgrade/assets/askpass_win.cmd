@echo off
rem Windows SSH_ASKPASS 助手入口：由 ssh.exe 自己调用（connect.ps1 只在子进程环境里设置），agent 不得直接运行、包装或重定向。
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0askpass_win.ps1" %*
exit /b %ERRORLEVEL%
