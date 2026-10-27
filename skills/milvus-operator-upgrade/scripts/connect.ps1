<#
Windows 版连接脚本（未实测）。在本机建立到 K8s master 的 SSH 登录，供后续 ssh/scp 使用。不含任何密码/IP。
顺序：本机已有密钥 / 上次的临时密钥 → 检测到 WSL 时建议改用 WSL 里的 connect.sh（-NoWsl 跳过）
     → 生成临时 ed25519 密钥 + 系统密码框（遮蔽输入）一次性装公钥 → 打印手动命令。
Win32-OpenSSH 不支持 ControlMaster，所以用“临时密钥”代替；结束时必须运行 -Close 删除。

用法（agent 在 PowerShell 里运行）：
  powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\connect.ps1 [-Port N] [-AcceptNewHostKey] [-NoWsl] <master|user@master>
  ... connect.ps1 -Check  <master>     只确认连接
  ... connect.ps1 -Close  <master>     从 master 的 authorized_keys 删除临时公钥那一行，并删除本机临时密钥
  ... connect.ps1 -Manual <master>     只打印手动命令
输出：成功时 SSH_OPTS=... 与 CONNECT_RESULT rc=0 mode=key|tmpkey
退出码：0 已连接；10 取消/超时；11 密码连续 3 次错误；20 需要手动；21 需确认主机指纹；22 主机指纹已变化；
       23 助手哈希不符；25 建议改用 WSL；30 网络/SSH 错误；2 参数错误；1 -Check 未连接 / -Close 未完成。
安全：密码只在本进程内存（SecureString），经 DPAPI(当前用户) 加密后只放进 ssh 子进程的环境变量，
     由 assets\askpass_win.cmd → askpass_win.ps1 解密交给 ssh；从不打印、不写文件、不放命令行参数。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Master,
    [switch]$Check,
    [switch]$Close,
    [switch]$Manual,
    [switch]$AcceptNewHostKey,
    [switch]$NoWsl,
    [switch]$Force,
    [int]$Port = 0
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Set-PSDebug -Off
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---- 助手脚本 sha256（发布时生成，改动助手后必须同步更新这里和 SKILL.md）----
$ExpectedSha = [ordered]@{
    'askpass_win.cmd' = '204a735f0a248e7974289746a5cd6403829b6d3a115f5526636d5b7e207b01bc'
    'askpass_win.ps1' = '218b2b511f80991adf0140043243a4383b9a7fdd12af1516c71e3817b2532a70'
}

$SkillDir = Split-Path -Parent $PSScriptRoot
$Assets = Join-Path $SkillDir 'assets'

function Finish([int]$rc, [string]$mode) {
    Write-Output "CONNECT_RESULT rc=$rc mode=$mode"
    exit $rc
}

if ([string]::IsNullOrWhiteSpace($Master)) { Write-Output '用法：connect.ps1 [-Check|-Close|-Manual] [-Port N] [-AcceptNewHostKey] [-NoWsl] <master>'; exit 2 }
if ($Master -notmatch '^[A-Za-z0-9._@:-]+$') { Write-Output 'master 地址含非法字符'; exit 2 }
$Target = if ($Master.Contains('@')) { $Master } else { "root@$Master" }
$RUser = $Target.Split('@')[0]
$RHost = $Target.Substring($Target.IndexOf('@') + 1)
$RPort = if ($Port -gt 0) { $Port } else { 22 }
$PortArg = if ($Port -gt 0) { "-o Port=$Port " } else { '' }
$HkArg = if ($AcceptNewHostKey) { '-o StrictHostKeyChecking=accept-new ' } else { '-o StrictHostKeyChecking=yes ' }
$HkTxt = if ($AcceptNewHostKey) { '-o StrictHostKeyChecking=accept-new ' } else { '' }
$Base = "-o ConnectTimeout=8 -o LogLevel=ERROR $PortArg$HkArg"

$safe = ("{0}_{1}_{2}" -f $RUser, $RHost, $RPort) -replace '[^A-Za-z0-9._-]', '_'
$StateDir = Join-Path ([IO.Path]::GetTempPath()) ("milvus-upgrade-ssh\" + $safe)
$KeyFile = Join-Path $StateDir 'id_ed25519'
$TagFile = Join-Path $StateDir 'tag.txt'

function Invoke-Native {
    # 用原始参数字符串启动外部程序，避免 PowerShell 5.1/7 对空参数和引号的处理差异；环境变量只给这个子进程。
    param([string]$File, [string]$Arguments, [hashtable]$ChildEnv = @{}, [int]$TimeoutSec = 90)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in $ChildEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ChildEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try { $p.StandardInput.Close() } catch { }
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = 124; Out = ''; Err = 'timed out' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}

function Get-Category([string]$err) {
    if ($err -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key for .* has changed') { return 'hostkey_changed' }
    if ($err -match 'Host key verification failed|No .*host key is known') { return 'hostkey_unknown' }
    if ($err -match 'Permission denied|Too many authentication failures') { return 'auth' }
    if ($err -match 'timed out|No route to host|Connection refused|Could not resolve|not known|Network is unreachable|Connection closed|Connection reset') { return 'network' }
    if ([string]::IsNullOrWhiteSpace($err)) { return 'none' }
    return 'other'
}

function Stop-OnFatal([string]$cat, [string]$err) {
    switch ($cat) {
        'hostkey_changed' { Write-Output $err; Write-Output 'CONNECT_ERROR master 的主机指纹与 known_hosts 不一致，可能有中间人或主机已重装。已停止，请人工核对。'; Finish 22 'none' }
        'hostkey_unknown' {
            Write-Output "HOSTKEY_UNKNOWN host=$RHost port=$RPort"
            if ($script:KeyScan) {
                $ks = Invoke-Native $script:KeyScan "-T 8 -p $RPort $RHost" -TimeoutSec 20
                $tmp = [IO.Path]::GetTempFileName()
                try {
                    [IO.File]::WriteAllText($tmp, $ks.Out)
                    $fp = Invoke-Native $script:KeyGen "-lf `"$tmp`"" -TimeoutSec 20
                    foreach ($l in ($fp.Out -split "`r?`n")) { if ($l.Trim()) { Write-Output "HOSTKEY_FP $l" } }
                } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
            Write-Output '本机 known_hosts 里没有该 master 的主机指纹。请与集群管理员核对上面的指纹，确认后加 -AcceptNewHostKey 重跑。'
            Finish 21 'none'
        }
        'network' { Write-Output $err; Write-Output "CONNECT_ERROR 无法连到 ${RHost}:$RPort（网络/端口/域名问题）。"; Finish 30 'none' }
    }
}

function Get-Tool([string]$name) {
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Write-Ok([string]$mode) {
    if ($mode -eq 'tmpkey') {
        Write-Output ("SSH_KEY=$KeyFile")
        Write-Output ("SSH_OPTS=-i `"$KeyFile`" -o IdentitiesOnly=yes -o BatchMode=yes $PortArg").TrimEnd()
    } else {
        Write-Output ("SSH_OPTS=-o BatchMode=yes $PortArg").TrimEnd()
    }
    Finish 0 $mode
}

function Test-Key([string]$extra) {
    return Invoke-Native $script:Ssh "${Base}-o BatchMode=yes $extra$Target true" -TimeoutSec 30
}

function Get-Tag {
    if (-not (Test-Path -LiteralPath $TagFile)) { return $null }
    $t = (Get-Content -LiteralPath $TagFile -Raw).Trim()
    if ($t -notmatch '^milvus-upgrade-tmp-\d{14}-[0-9a-f]{6}$') { return $null }
    return $t
}

function New-TempKey {
    if ((Test-Path -LiteralPath $KeyFile) -and (Get-Tag)) { return }
    if (Test-Path -LiteralPath $StateDir) { Remove-Item -LiteralPath $StateDir -Recurse -Force }
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    try {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Invoke-Native 'icacls.exe' "`"$StateDir`" /inheritance:r /grant:r `"${me}:(OI)(CI)F`" /grant:r `"SYSTEM:(OI)(CI)F`"" -TimeoutSec 30 | Out-Null
    } catch { }
    $tag = 'milvus-upgrade-tmp-{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $r = Invoke-Native $script:KeyGen "-q -t ed25519 -N `"`" -C $tag -f `"$KeyFile`"" -TimeoutSec 30
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$KeyFile.pub")) {
        Write-Output $r.Err
        Write-Output 'CONNECT_ERROR ssh-keygen 生成临时密钥失败'
        Finish 30 'none'
    }
    Set-Content -LiteralPath $TagFile -Value $tag -Encoding ASCII
}

function Get-InstallRemoteCmd {
    $pub = (Get-Content -LiteralPath "$KeyFile.pub" -Raw).Trim()
    if ($pub -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+ milvus-upgrade-tmp-\d{14}-[0-9a-f]{6}$') { Write-Output 'CONNECT_ERROR 临时公钥格式异常'; Finish 30 'none' }
    # 远端：确保文件以换行结尾，再追加这一行（行尾注释即唯一标记，-Close 按它删除）
    return 'umask 077; mkdir -p ~/.ssh; f=~/.ssh/authorized_keys; if [ -s $f ] && [ $(tail -c1 $f | wc -l) -eq 0 ]; then echo >> $f; fi; echo ''' + $pub + ''' >> $f'
}

function Write-Manual([string]$reason) {
    Write-Output "CONNECT_MANUAL reason=$reason"
    if ($script:Ssh -and (Test-Path -LiteralPath "$KeyFile.pub")) {
        $cmd = Get-InstallRemoteCmd
        Write-Output '无法自动弹出密码框。请打开你自己的 PowerShell 窗口，运行下面这一条命令，按提示输入 master 的密码（输入时不显示）：'
        Write-Output ''
        Write-Output ("  ssh $PortArg$HkTxt$Target '" + $cmd.Replace("'", "''") + "'")
        Write-Output ''
        Write-Output '它只把一把临时公钥（行尾带 milvus-upgrade-tmp-… 标记）加到 master 的 root 授权列表，结束时 agent 会运行 -Close 删除。'
    } else {
        Write-Output '本机没有可用的 OpenSSH 客户端：请在「设置 → 应用 → 可选功能」安装「OpenSSH 客户端」后让 agent 重试。'
    }
    Write-Output '如果装有 WSL，也可以在 WSL 终端里运行：'
    Write-Output ("  ssh -fN -o ControlMaster=yes -o 'ControlPath=~/.ssh/cm-%r@%h:%p' -o ControlPersist=2h $PortArg$HkTxt$Target")
    Write-Output '（之后 agent 的所有 ssh/scp 都要在 WSL 里执行。）完成后回到对话，选择「已登录」。密码不要发到对话里。'
    Finish 20 'none'
}

function Show-PasswordDialog([string]$prompt) {
    # 返回 SecureString；取消/超时返回 $null；无法显示窗口时抛异常
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SSH 登录（Milvus 升级）'
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.TopMost = $true
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $prompt
    $label.SetBounds(12, 12, 396, 40)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.UseSystemPasswordChar = $true
    $tb.SetBounds(12, 60, 396, 24)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '登录'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK; $ok.SetBounds(232, 106, 84, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $cancel.SetBounds(324, 106, 84, 28)
    $form.Controls.AddRange(@($label, $tb, $ok, $cancel))
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 120000
    $timer.Add_Tick({ $timer.Stop(); $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
    $form.Add_Shown({ $form.Activate(); $tb.Focus(); $timer.Start() })
    try {
        $res = $form.ShowDialog()
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $sec = New-Object System.Security.SecureString
        foreach ($ch in $tb.Text.ToCharArray()) { $sec.AppendChar($ch) }
        $tb.Text = ''
        $sec.MakeReadOnly()
        return $sec
    } finally {
        $timer.Dispose(); $form.Dispose()
    }
}

# ---------------- 准备 ----------------
$script:Ssh = Get-Tool 'ssh.exe'
$script:KeyGen = Get-Tool 'ssh-keygen.exe'
$script:KeyScan = Get-Tool 'ssh-keyscan.exe'

# ---------------- -Close ----------------
if ($Close) {
    $tag = Get-Tag
    if (-not $tag -or -not (Test-Path -LiteralPath $KeyFile)) {
        if (Test-Path -LiteralPath $StateDir) { Remove-Item -LiteralPath $StateDir -Recurse -Force }
        Write-Output '没有需要清理的临时密钥。'
        Finish 0 'closed'
    }
    $done = $false
    if ($script:Ssh) {
        $rm = 'f=~/.ssh/authorized_keys; if [ -f $f ]; then grep -v -F ''' + $tag + ''' $f > $f.milvus-tmp; rc=$?; if [ $rc -le 1 ]; then cat $f.milvus-tmp > $f; fi; rm -f $f.milvus-tmp; echo REMAIN=$(grep -c -F ''' + $tag + ''' $f); else echo REMAIN=0; fi'
        $r = Invoke-Native $script:Ssh "${Base}-o BatchMode=yes -i `"$KeyFile`" -o IdentitiesOnly=yes $Target `"$rm`"" -TimeoutSec 60
        if ($r.ExitCode -eq 0 -and $r.Out -match 'REMAIN=0') { $done = $true }
    }
    if ($done -or $Force) {
        Remove-Item -LiteralPath $StateDir -Recurse -Force
        if ($done) { Write-Output "已从 master 删除临时公钥（$tag），并删除本机临时密钥。"; Finish 0 'closed' }
        Write-Output "警告：未能确认 master 上已删除 $tag 那一行；本机私钥已删除（该行已无法再被使用），可让管理员手动删除。"
        Finish 1 'none'
    }
    Write-Output "CONNECT_ERROR 未能从 master 删除临时公钥（$tag）。本机临时密钥已保留，修复网络后重跑 -Close；"
    Write-Output "或在你自己的终端运行：ssh $PortArg$Target `"sed -i '/$tag/d' ~/.ssh/authorized_keys`" ，再运行 -Close -Force。"
    Finish 1 'none'
}

# ---------------- -Check ----------------
if ($Check) {
    if ($script:Ssh) {
        if ((Test-Path -LiteralPath $KeyFile) -and (Get-Tag)) {
            if ((Test-Key "-i `"$KeyFile`" -o IdentitiesOnly=yes ").ExitCode -eq 0) { Write-Ok 'tmpkey' }
        }
        $r = Test-Key ''
        if ($r.ExitCode -eq 0) { Write-Ok 'key' }
        Write-Output ('未连接：' + (($r.Err -split "`r?`n" | Select-Object -First 3) -join ' '))
    } else { Write-Output '未连接：本机没有 ssh.exe' }
    Finish 1 'none'
}

# ---------------- 连接 ----------------
foreach ($name in $ExpectedSha.Keys) {
    $f = Join-Path $Assets $name
    $got = if (Test-Path -LiteralPath $f) { (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLowerInvariant() } else { '' }
    if ($got -ne $ExpectedSha[$name]) {
        Write-Output "CONNECT_ERROR 助手脚本 assets\$name 的 sha256 不符（期望 $($ExpectedSha[$name])，实际 $got），拒绝使用。请重新安装 skill。"
        Finish 23 'none'
    }
}
if (-not $script:Ssh -or -not $script:KeyGen) { Write-Manual 'no_openssh' }

# 1) 上次的临时密钥 / 本机已有密钥
if ((Test-Path -LiteralPath $KeyFile) -and (Get-Tag)) {
    if ((Test-Key "-i `"$KeyFile`" -o IdentitiesOnly=yes ").ExitCode -eq 0) { Write-Ok 'tmpkey' }
}
$r = Test-Key ''
if ($r.ExitCode -eq 0) { Write-Ok 'key' }
Stop-OnFatal (Get-Category $r.Err) $r.Err

# 2) WSL 建议
if (-not $NoWsl -and -not $Manual) {
    $wsl = Get-Tool 'wsl.exe'
    if ($wsl) {
        $w = Invoke-Native $wsl '-l -q' -TimeoutSec 20
        $names = ($w.Out -replace "`0", '').Trim()
        if ($w.ExitCode -eq 0 -and $names) {
            $full = (Resolve-Path -LiteralPath $SkillDir).Path
            $wslSkill = '/mnt/' + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')
            Write-Output 'CONNECT_HINT wsl=available'
            Write-Output '检测到 WSL。推荐在 WSL 里建立复用连接（之后 agent 的所有 ssh/scp 都在 WSL 里执行）：'
            Write-Output ("  wsl -e bash '$wslSkill/scripts/connect.sh' $PortArg$Target" -replace '-o Port=', '--port ')
            Write-Output '若 WSL 里返回 20（无法弹窗）或不想用 WSL，改为运行：connect.ps1 -NoWsl <master>'
            Finish 25 'wsl'
        }
    }
}

# 3) 临时密钥 + 密码框
New-TempKey
if ($Manual) { Write-Manual 'requested' }
$askpass = Join-Path $Assets 'askpass_win.cmd'
$remote = Get-InstallRemoteCmd
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $sec = Show-PasswordDialog ("请输入 $Target 的密码（只用于一次性安装临时公钥，120 秒内）")
    } catch {
        Write-Manual 'popup_unavailable'
    }
    if ($null -eq $sec) { Write-Output '已取消输入密码。'; Finish 10 'none' }
    $statusFile = [IO.Path]::GetTempFileName()
    try {
        $childEnv = @{
            'SSH_ASKPASS'           = $askpass
            'SSH_ASKPASS_REQUIRE'   = 'force'
            'DISPLAY'               = 'localhost:0'
            'MILVUS_ASKPASS_BLOB'   = (ConvertFrom-SecureString -SecureString $sec)
            'MILVUS_ASKPASS_STATUS' = $statusFile
        }
        $r = Invoke-Native $script:Ssh "${Base}-o NumberOfPasswordPrompts=1 -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive $Target `"$remote`"" -ChildEnv $childEnv -TimeoutSec 60
        $childEnv.Clear()
        $st = (Get-Content -LiteralPath $statusFile -Raw -ErrorAction SilentlyContinue)
        $st = if ($st) { $st.Trim() } else { '' }
    } finally {
        $sec.Dispose(); $sec = $null
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }
    if ($r.ExitCode -eq 0 -and (Test-Key "-i `"$KeyFile`" -o IdentitiesOnly=yes ").ExitCode -eq 0) { Write-Ok 'tmpkey' }
    $cat = Get-Category $r.Err
    Stop-OnFatal $cat $r.Err
    if ($st -eq 'ok' -and $cat -eq 'auth') { Write-Output "密码不正确（第 $attempt/3 次）。"; continue }
    if ($st -ne 'ok') { Write-Output (($r.Err -split "`r?`n" | Select-Object -First 3) -join ' '); Write-Manual 'askpass_not_used' }
    Write-Output (($r.Err -split "`r?`n" | Select-Object -First 5) -join ' ')
    Write-Manual 'install_failed'
}
Write-Output 'CONNECT_ERROR 密码连续 3 次错误。'
Finish 11 'none'
