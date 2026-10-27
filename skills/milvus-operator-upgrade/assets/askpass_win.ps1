# Windows SSH_ASKPASS 助手（未实测）：由 askpass_win.cmd 在 ssh.exe 的子进程里调用，agent 不得直接运行、包装或重定向。
# 密码来源：connect.ps1 只在 ssh 子进程环境里放入 MILVUS_ASKPASS_BLOB = DPAPI(当前用户) 加密的 SecureString 文本；
# 这里解密后只写到 stdout 交给 ssh。不写日志；只在 MILVUS_ASKPASS_STATUS 文件里写 ok（不含密码）。主机指纹确认等其他提示一律拒绝（退出 1）。
$ErrorActionPreference = 'Stop'
Set-PSDebug -Off
$prompt = ($args -join ' ')
if ($prompt -match 'yes/no|fingerprint') { exit 1 }
$blob = $env:MILVUS_ASKPASS_BLOB
if ([string]::IsNullOrEmpty($blob)) { exit 1 }
$bstr = [IntPtr]::Zero
try {
    $sec = ConvertTo-SecureString -String $blob
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $out = [Console]::OpenStandardOutput()
    $bytes = [Text.Encoding]::UTF8.GetBytes([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) + "`n")
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
    [Array]::Clear($bytes, 0, $bytes.Length)
    if ($env:MILVUS_ASKPASS_STATUS) { try { Set-Content -LiteralPath $env:MILVUS_ASKPASS_STATUS -Value 'ok' -Encoding ASCII } catch { } }
    exit 0
} catch {
    exit 1
} finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
