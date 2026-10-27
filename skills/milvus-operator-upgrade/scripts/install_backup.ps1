<#
Windows 版：把用户自己下载到本机的 milvus-backup（tarball 或二进制）校验后装到 master 工作目录（本脚本不联网下载，不碰 k8s）。未实测于 Windows。
前提：已用 connect.ps1 建立连接。mode=tmpkey 时把输出的 SSH_KEY 传给 -Key；mode=key 时不传。
（connect.ps1 返回 25 改用 WSL 时，请在 WSL 里运行 scripts/install_backup.sh。）
用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\install_backup.ps1 [-Key <SSH_KEY>] [-Port N] [-Workdir /root/milvus-upgrade] [-AllowUnverified] <master|user@master> -From <本地 tarball 或二进制>
  -AllowUnverified 仅当用户在选项里明确选择「仍然使用（未经验证）」时才加。
输出最后一行：BACKUP_INSTALL rc=N path=<路径> action=installed|skipped|none arch=<arch> verified=yes|no|-
退出码与 install_backup.sh 相同：0 成功/已存在；1 ssh 不通；2 参数/本地文件不存在；3 架构不支持或不符；4 sha256 不在已知清单；
5 传输/解压/远端校验失败；6 自检失败；7 版本不是 0.6.1。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Master,
    [string]$From = '',
    [string]$Key = '',
    [int]$Port = 0,
    [string]$Workdir = '/root/milvus-upgrade',
    [switch]$AllowUnverified
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$MbVer = '0.6.1'
$SumsFile = Join-Path $PSScriptRoot 'milvus-backup-sha256.txt'
$Known = @{}
$script:Arch = '?'; $script:Dest = '-'; $script:Verified = '-'

function Finish([int]$rc, [string]$action) {
    Write-Output "BACKUP_INSTALL rc=$rc path=$($script:Dest) action=$action arch=$($script:Arch) verified=$($script:Verified)"
    exit $rc
}
if ([string]::IsNullOrWhiteSpace($Master) -or [string]::IsNullOrWhiteSpace($From)) { Write-Output '用法：install_backup.ps1 [-Key <SSH_KEY>] [-Port N] [-Workdir DIR] [-AllowUnverified] <master> -From <本地文件>'; exit 2 }
if ($Master -notmatch '^[A-Za-z0-9._@:-]+$') { Write-Output 'master 地址含非法字符'; exit 2 }
if ($Workdir -notmatch '^/[A-Za-z0-9._/-]+$' -or $Workdir.Contains('..')) { Write-Output '-Workdir 必须是合法的绝对路径'; exit 2 }
$Workdir = $Workdir.TrimEnd('/')
if ($Key -and -not (Test-Path -LiteralPath $Key)) { Write-Output "密钥文件不存在: $Key"; exit 2 }
$Target = if ($Master.Contains('@')) { $Master } else { "root@$Master" }
if (-not (Test-Path -LiteralPath $SumsFile)) { Write-Output 'BACKUP_INSTALL_ERROR 缺少 scripts\milvus-backup-sha256.txt（skill 不完整，请重新安装 skill）'; Finish 2 'none' }
foreach ($l in Get-Content -LiteralPath $SumsFile -Encoding UTF8) {
    if ($l -match '^([0-9a-f]{64})\s+(\S+)\s*$') { $Known[$Matches[1]] = $Matches[2] }
}
if (-not (Test-Path -LiteralPath $From -PathType Leaf)) { Write-Output "BACKUP_INSTALL_ERROR 本地文件不存在或不可读: $From（请确认用户给出的路径）"; Finish 2 'none' }
$From = (Resolve-Path -LiteralPath $From).Path

$Opts = '-o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR '
if ($Port -gt 0) { $Opts += "-o Port=$Port " }
if ($Key) { $Opts += "-i `"$Key`" -o IdentitiesOnly=yes " }
$SshExe = (Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
$ScpExe = (Get-Command scp -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $SshExe -or -not $ScpExe) { Write-Output 'BACKUP_INSTALL_ERROR 本机没有 OpenSSH 客户端（ssh/scp）'; Finish 1 'none' }

function Invoke-Native {
    # stdin 可以是文本（远端脚本，统一 LF）或本地文件（流式写入）
    param([string]$File, [string]$Arguments, [string]$StdinText = $null, [string]$StdinFile = $null, [int]$TimeoutSec = 600)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    try {
        if ($StdinFile) {
            $fs = [IO.File]::OpenRead($StdinFile)
            try { $fs.CopyTo($p.StandardInput.BaseStream) } finally { $fs.Close() }
        } elseif ($null -ne $StdinText) {
            $b = (New-Object Text.UTF8Encoding($false)).GetBytes(($StdinText -replace "`r`n", "`n"))
            $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
        }
    } catch { }
    try { $p.StandardInput.Close() } catch { }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = 124; Out = ''; Err = 'timed out' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}
function Invoke-Remote([string]$Script, [int]$TimeoutSec = 120) { Invoke-Native $SshExe.Source "$Opts$Target bash -s" -StdinText $Script -TimeoutSec $TimeoutSec }

# 1. 架构 + 现有二进制
$probe = @'
uname -m
f='__WB__/milvus-backup'; [ -d "$f" ] && f="$f/milvus-backup"
echo "DEST $f"
if [ -f "$f" ]; then echo "HAVE $(sha256sum "$f" | awk '{print $1}')"; fi
'@ -replace '__WB__', $Workdir
$r = Invoke-Remote $probe 30
if ($r.ExitCode -ne 0) { Write-Output "BACKUP_INSTALL_ERROR 无法通过 ssh 连接 $Target（先运行 connect.ps1 建立连接）: $($r.Err.Trim())"; Finish 1 'none' }
$lines = @($r.Out -split "`r?`n")
$m = $lines[0].Trim()
foreach ($l in $lines) { if ($l -like 'DEST *') { $script:Dest = $l.Substring(5).Trim() } }
$have = ''; foreach ($l in $lines) { if ($l -like 'HAVE *') { $have = $l.Substring(5).Trim() } }
switch -Regex ($m) {
    '^(x86_64|amd64)$' { $script:Arch = 'x86_64' }
    '^(aarch64|arm64)$' { $script:Arch = 'arm64' }
    default { $script:Arch = $(if ($m) { $m } else { '?' }); Write-Output "BACKUP_INSTALL_ERROR master 架构 $m 不受支持（milvus-backup 官方 Linux 包只有 x86_64 / arm64）"; Finish 3 'none' }
}
if ($script:Dest -ne "$Workdir/milvus-backup" -and $script:Dest -ne "$Workdir/milvus-backup/milvus-backup") { Write-Output "BACKUP_INSTALL_ERROR 远端返回异常: $($r.Out)"; Finish 5 'none' }
function Get-KnownSha([string]$name) { foreach ($k in $Known.Keys) { if ($Known[$k] -eq $name) { return $k } }; return '' }
$TgzName = "milvus-backup_${MbVer}_Linux_$($script:Arch).tar.gz"
$Url = "https://github.com/zilliztech/milvus-backup/releases/download/v$MbVer/$TgzName"
$exp = @{ Tgz = (Get-KnownSha $TgzName); Bin = (Get-KnownSha "milvus-backup_${MbVer}_Linux_$($script:Arch)/milvus-backup") }
if (-not $exp.Tgz -or -not $exp.Bin) { Write-Output "BACKUP_INSTALL_ERROR milvus-backup-sha256.txt 中没有 $($script:Arch) 的条目（skill 不完整）"; Finish 2 'none' }

# 2. master 上已有已知 0.6.1 二进制 → 跳过
if ($have -eq $exp.Bin) {
    $r = Invoke-Remote ("cd /tmp && '" + $script:Dest + "' --help 2>&1 | head -1 | grep -q '^" + $MbVer + " '") 30
    if ($r.ExitCode -eq 0) { $script:Verified = 'yes'; Write-Output "master 上已有 milvus-backup $MbVer（sha256 与官方一致），跳过安装"; Finish 0 'skipped' }
}

# 3. 本机校验用户提供的文件
$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $From).Hash.ToLower()
$fs = [IO.File]::OpenRead($From); $hdr = New-Object byte[] 20; $n = $fs.Read($hdr, 0, 20); $fs.Close()
$kind = if ($n -ge 2 -and $hdr[0] -eq 0x1f -and $hdr[1] -eq 0x8b) { 'tgz' } else { 'bin' }
if ($Known.ContainsKey($got)) {
    $kname = $Known[$got]; $script:Verified = 'yes'
    $kind = if ($kname -like '*.tar.gz') { 'tgz' } else { 'bin' }
    $farch = if ($kname -match '_Linux_(x86_64|arm64)') { $Matches[1] } else { '?' }
    if ($farch -ne $script:Arch) { Write-Output "BACKUP_INSTALL_ERROR 文件是 $farch 版（$kname），master 是 $($script:Arch)。请下载 $Url（sha256 $($exp.Tgz)）"; Finish 3 'none' }
    Write-Output "本地文件 sha256 与官方 $kname 一致"
} else {
    $script:Verified = 'no'
    $base = Split-Path -Leaf $From
    if ($base -match '^milvus-backup_([0-9][0-9A-Za-z.+-]*)_' -and $Matches[1] -ne $MbVer) {
        $fver = $Matches[1]
        if (-not $AllowUnverified) { Write-Output "BACKUP_INSTALL_ERROR 文件版本是 $fver，本 skill 只验证过 milvus-backup $MbVer，拒绝使用。请下载 $Url（sha256 $($exp.Tgz)）"; Finish 7 'none' }
        Write-Output "WARN: 版本 $fver 未经验证（用户已明确选择仍然使用）"
    }
    if (-not $AllowUnverified) { Write-Output "BACKUP_INSTALL_ERROR sha256 不符：$From 的 sha256=$got，不在已知 $MbVer 清单中（期望 tarball $($exp.Tgz) 或二进制 $($exp.Bin)）。文件可能被篡改、下载不完整或不是 $($script:Arch) 版，拒绝使用。请从 $Url 重新下载"; Finish 4 'none' }
    Write-Output "WARN: sha256=$got 未经验证（用户已明确选择仍然使用）"
    if ($kind -eq 'bin' -and $n -ge 20 -and $hdr[0] -eq 0x7f) {
        $em = [int]$hdr[18] + 256 * [int]$hdr[19]
        if (($em -eq 62 -and $script:Arch -ne 'x86_64') -or ($em -eq 183 -and $script:Arch -ne 'arm64')) { Write-Output "BACKUP_INSTALL_ERROR 二进制架构（e_machine=$em）与 master $($script:Arch) 不符"; Finish 3 'none' }
    }
}
$local = $From

# 4. 传输（scp 失败时回退为 ssh 直接写入）
$up = "$Workdir/.mb-install-$PID.up"
$r = Invoke-Remote "mkdir -p '$Workdir' && chmod 700 '$Workdir'" 30
if ($r.ExitCode -ne 0) { Write-Output "BACKUP_INSTALL_ERROR 无法创建 ${Workdir}: $($r.Err.Trim())"; Finish 5 'none' }
$r = Invoke-Native $ScpExe.Source "-q $Opts`"$local`" `"${Target}:$up`"" -TimeoutSec 900
if ($r.ExitCode -ne 0) {
    $r = Invoke-Native $SshExe.Source "$Opts$Target `"cat > '$up'`"" -StdinFile $local -TimeoutSec 900
    if ($r.ExitCode -ne 0) { [void](Invoke-Remote "rm -f '$up'" 30); Write-Output 'BACKUP_INSTALL_ERROR 传输失败（scp 与 ssh 均失败）'; Finish 5 'none' }
}

# 5. master 端：传输校验 → 解压/放置 → 架构、二进制 sha256、--help 自检 → 替换
$remote = @'
set -u
UP='__UP__'; DEST='__DEST__'; TMPD='__WB__/.mb-install-__PID__.d'; ALLOW='__ALLOW__'
cleanup(){ rm -rf "$UP" "$TMPD"; }
trap cleanup EXIT
s=$(sha256sum "$UP" | awk '{print $1}')
[ "$s" = '__GOT__' ] || { echo "REMOTE_ERR 5 传输后 sha256 不一致: $s"; exit 5; }
mkdir -p "$TMPD" || { echo "REMOTE_ERR 5 无法创建临时目录"; exit 5; }
if [ '__KIND__' = tgz ]; then
  tar -xzf "$UP" -C "$TMPD" milvus-backup || { echo "REMOTE_ERR 5 解压失败（tarball 里应有 milvus-backup）"; exit 5; }
else
  cp "$UP" "$TMPD/milvus-backup" || { echo "REMOTE_ERR 5 复制失败"; exit 5; }
fi
em=$(od -An -tu2 -j18 -N2 "$TMPD/milvus-backup" 2>/dev/null | tr -d ' \n')
case "$em:__ARCH__" in 62:x86_64|183:arm64) ;; *) echo "REMOTE_ERR 3 二进制架构（e_machine=$em）与 master __ARCH__ 不符或不是 ELF"; exit 3 ;; esac
b=$(sha256sum "$TMPD/milvus-backup" | awk '{print $1}')
if [ "$b" != '__BIN__' ]; then
  [ "$ALLOW" = 1 ] || { echo "REMOTE_ERR 4 二进制 sha256 不符: $b（期望 __BIN__）"; exit 4; }
  echo "WARN: 二进制 sha256=$b 未经验证"
fi
chmod 755 "$TMPD/milvus-backup"
h=$(cd "$TMPD" && ./milvus-backup --help 2>&1 | head -1)
case "$h" in '__VER__ '*) ;;
  [0-9]*' '*) [ "$ALLOW" = 1 ] || { echo "REMOTE_ERR 7 版本不是 __VER__: $h"; exit 7; }; echo "WARN: 版本 $h 未经验证" ;;
  *) echo "REMOTE_ERR 6 --help 自检失败: $h"; exit 6 ;;
esac
if [ -e "$DEST" ]; then mv -f "$DEST" "$DEST.bak-$(date +%Y%m%d%H%M%S)" && echo "已把原有 $DEST 改名为 .bak-*"; fi
mv -f "$TMPD/milvus-backup" "$DEST" || { echo "REMOTE_ERR 5 写入 $DEST 失败"; exit 5; }
echo "REMOTE_OK $h"
'@
$allowVal = if ($AllowUnverified) { '1' } else { '0' }
$remote = $remote.Replace('__UP__', $up).Replace('__DEST__', $script:Dest).Replace('__WB__', $Workdir).Replace('__PID__', [string]$PID).Replace('__GOT__', $got).Replace('__KIND__', $kind).Replace('__ARCH__', $script:Arch).Replace('__BIN__', $exp.Bin).Replace('__VER__', $MbVer).Replace('__ALLOW__', $allowVal)
$r = Invoke-Remote $remote 300
$ok = ''; $err = ''; $erc = 5
foreach ($l in @($r.Out -split "`r?`n")) {
    if ($l -like 'REMOTE_OK *') { $ok = $l.Substring(10) }
    elseif ($l -match '^REMOTE_ERR (\d+) (.*)$') { $erc = [int]$Matches[1]; $err = $Matches[2] }
    elseif ($l.Trim()) { Write-Output $l }
}
if ($r.ExitCode -ne 0 -or -not $ok) {
    Write-Output "BACKUP_INSTALL_ERROR $err $($r.Err.Trim())"
    if (@(3, 4, 6, 7) -contains $erc) { Finish $erc 'none' } else { Finish 5 'none' }
}
Write-Output "milvus-backup $ok 已安装到 $($script:Dest)"
Finish 0 'installed'
