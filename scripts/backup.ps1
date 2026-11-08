# 安卓手机 -> 电脑 无线备份（adb over TCP + tar 原始字节流）
#
# 为什么不用 adb pull：这台电脑上 adb 创建不了任何非 ASCII 文件名，
# 遇到中文目录会报 Illegal byte sequence 并把整个目录中断。
# tar 走 exec-out 原始字节流，再由 extract_tar.py 按 UTF-8 解包，中文名完全正确。
#
# 用法：
#   backup.ps1 setup            重建无线连接（需要插一下数据线）
#   backup.ps1 full             全量备份 /sdcard（排除 Android）
#   backup.ps1 dir Pictures     只备份某个顶层目录
#   backup.ps1 status           列出历史备份
# 可选： -Dest D:\PhoneBackup\2026-11-08   -Dev 192.168.31.200:5555   -Exclude Android

param(
    [Parameter(Position = 0)]
    [string]$Mode = "full",
    [Parameter(Position = 1)]
    [string]$Target = "",
    [string]$Dev = "",
    [string]$Dest = "",
    [string]$Exclude = "Android"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$SkillRoot = Split-Path -Parent $PSScriptRoot
$StateFile = Join-Path $SkillRoot ".state.json"
$DefaultDestRoot = "D:\PhoneBackup"

function Say([string]$msg) { Write-Host $msg }

# ---------- 工具发现 ----------
function Find-Adb {
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter adb.exe -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($p) { return $p.FullName }
    throw "找不到 adb.exe。先跑： winget install --id Google.PlatformTools"
}

function Find-Py {
    foreach ($c in @("python.exe", "python3.exe")) {
        $x = Get-Command $c -ErrorAction SilentlyContinue
        if ($x) { return $x.Source }
    }
    foreach ($p in @("C:\Espressif\tools\python\python.exe",
                     "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
                     "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw "找不到 python.exe（只用到标准库 tarfile）"
}

$Adb = Find-Adb
$Py = Find-Py
$Extractor = Join-Path $PSScriptRoot "extract_tar.py"

# ---------- 设备 ----------
function Get-Devices {
    $out = & $Adb devices 2>$null
    $list = @()
    foreach ($line in $out) {
        if ($line -match '^(\S+)\s+device') { $list += $Matches[1] }
    }
    return $list
}

function Get-Wireless {
    return (Get-Devices | Where-Object { $_ -like "*:*" } | Select-Object -First 1)
}

function Get-Usb {
    return (Get-Devices | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1)
}

function Get-PhoneWifiIp([string]$serial) {
    $r = & $Adb -s $serial shell "ip -4 addr show wlan0 2>/dev/null | grep inet" 2>$null
    if ($r -match '(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Use-Wireless {
    $w = Get-Wireless
    if ($w) { Say "无线设备： $w"; return $w }

    $u = Get-Usb
    if (-not $u) {
        throw "既没有无线设备也没有 USB 设备。确认手机开了 USB 调试、和电脑在同一 WiFi，或先把数据线插上。"
    }
    Say "只有 USB 设备 $u，切到无线模式 ..."
    & $Adb -s $u tcpip 5555 | Out-Null
    Start-Sleep -Seconds 3
    $ip = Get-PhoneWifiIp $u
    if (-not $ip) { throw "拿不到手机 wlan0 的 IP，确认手机连着 WiFi。" }
    & $Adb connect "${ip}:5555" | Out-Null
    Start-Sleep -Seconds 2
    $w = "${ip}:5555"
    if (-not ((Get-Devices) -contains $w)) { throw "adb connect $w 失败。" }
    Say "已切到无线： $w"
    return $w
}

function Resolve-Device {
    if ($Dev -and ((Get-Devices) -contains $Dev)) { return $Dev }
    if (-not $Dev -and (Test-Path $StateFile)) {
        try {
            $st = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.lastDevice -and ((Get-Devices) -contains $st.lastDevice)) { return $st.lastDevice }
        } catch { }
    }
    return (Use-Wireless)
}

function Save-State([string]$dev) {
    @{ lastDevice = $dev; updated = (Get-Date).ToString("s") } |
        ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------- 计量 ----------
function Get-RemoteMB([string]$dev, [string]$remote) {
    $r = & $Adb -s $dev shell "du -sm '$remote' 2>/dev/null" 2>$null
    $t = ($r | Out-String).Trim()
    if ($t -match '^(\d+)') { return [int]$Matches[1] }
    return -1
}

function Get-RemoteCount([string]$dev, [string]$remote) {
    $r = & $Adb -s $dev shell "find '$remote' -type f 2>/dev/null | wc -l" 2>$null
    $t = ($r | Out-String).Trim()
    if ($t -match '^(\d+)') { return [int]$Matches[1] }
    return -1
}

function Get-LocalCount([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    return (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue).Count
}

# ---------- 传输 ----------
function Stream-Tar {
    param([string]$Device, [string]$Spec, [string]$TarPath, [string]$Exc)

    $remoteCmd = "cd /sdcard && tar -cf - "
    if ($Spec -eq ".") {
        if ($Exc) { $remoteCmd += "--exclude='$Exc' " }
        $remoteCmd += "."
    } else {
        $remoteCmd += "'$Spec'"
    }
    $remoteCmd += " 2>/dev/null"

    $tmpErr = "$TarPath.err"
    $cmdline = "`"$Adb`" -s $Device exec-out `"$remoteCmd`" > `"$TarPath`" 2>`"$tmpErr`""

    $job = Start-Job -ScriptBlock { param($c) cmd.exe /c $c } -ArgumentList $cmdline
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = 0
    while ($job.State -eq 'Running') {
        Start-Sleep -Seconds 10
        if (Test-Path $TarPath) {
            $mb = [int][math]::Round((Get-Item $TarPath).Length / 1MB)
            if ($mb - $last -ge 200) {
                Say ("    ... {0} MB / {1:N1} 分钟" -f $mb, $sw.Elapsed.TotalMinutes)
                $last = $mb
            }
        }
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $sw.Stop()

    if (-not (Test-Path $TarPath)) { throw "tar 流没有产出文件：$TarPath" }
    if ((Test-Path $tmpErr) -and (Get-Item $tmpErr).Length -gt 0) {
        $errs = Get-Content $tmpErr -Tail 5
        if ($errs) {
            Say "  tar 告警（多数是无权限目录，可忽略）："
            $errs | ForEach-Object { Say ("    " + $_) }
        }
    }
    Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue

    $sizeMB = [math]::Round((Get-Item $TarPath).Length / 1MB, 1)
    return [pscustomobject]@{
        MB      = $sizeMB
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Backup-One {
    param([string]$Device, [string]$Spec, [string]$DestDir, [string]$Exc)

    $staging = Join-Path $DestDir "_staging"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $safeName = if ($Spec -eq ".") { "sdcard" } else { ($Spec -replace '[\\/:*?"<>|]', '_') }
    $tarPath = Join-Path $staging "$safeName.tar"

    $remotePath = if ($Spec -eq ".") { "/sdcard" } else { "/sdcard/$Spec" }
    $remoteMB = Get-RemoteMB $Device $remotePath
    Say ("  tar 流 {0}  约 {1} MB" -f $remotePath, $remoteMB)

    $t = Stream-Tar -Device $Device -Spec $Spec -TarPath $tarPath -Exc $Exc
    $speed = if ($t.Seconds -gt 0) { [math]::Round($t.MB / $t.Seconds, 1) } else { 0 }
    Say ("  收到 {0} MB / {1:N0} 秒 (约 {2} MB/s)，解包..." -f $t.MB, $t.Seconds, $speed)

    & $Py $Extractor $tarPath $DestDir 2>&1 | ForEach-Object { Say ("  " + $_) }
    Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
    Remove-Item $staging -Force -Recurse -ErrorAction SilentlyContinue
    return $t
}

# ---------- 主流程 ----------
$mode = $Mode.ToLower()

if ($mode -eq "status") {
    if (-not (Test-Path $DefaultDestRoot)) { Say "还没有任何备份（$DefaultDestRoot 不存在）"; exit 0 }
    Get-ChildItem $DefaultDestRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
        $s = Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        Say ("{0}  {1,6} 文件  {2,8:N2} GB  {3}" -f $_.Name, $s.Count, ($s.Sum / 1GB), $_.FullName)
    }
    exit 0
}

if ($mode -eq "setup") {
    & $Adb start-server 2>&1 | Out-Null
    $w = Use-Wireless
    Save-State $w
    & $Adb -s $w shell "svc power stayon true" 2>&1 | Out-Null
    Say "无线已就绪： $w （屏幕常亮已打开）"
    exit 0
}

if ($mode -ne "full" -and $mode -ne "dir") {
    Say "用法： backup.ps1 [setup | full | dir <目录名> | status]"
    exit 2
}

$device = Resolve-Device
Save-State $device
Say "设备： $device"

if (-not $Dest) { $Dest = Join-Path $DefaultDestRoot (Get-Date -Format "yyyy-MM-dd") }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
& $Adb -s $device shell "svc power stayon true" 2>&1 | Out-Null

if ($mode -eq "full") {
    $specs = @(".")
} else {
    if (-not $Target) { throw "dir 模式要指定目录名，例如： backup.ps1 dir Pictures" }
    $exists = (& $Adb -s $device shell "[ -d '/sdcard/$Target' ] && echo yes" 2>$null | Out-String).Trim()
    if ($exists -ne "yes") { throw "手机上不存在 /sdcard/$Target" }
    $specs = @($Target)
}

$total = [Diagnostics.Stopwatch]::StartNew()
foreach ($spec in $specs) {
    Backup-One -Device $device -Spec $spec -DestDir $Dest -Exc $Exclude | Out-Null
}
$total.Stop()

Say ""
Say "校验（文件数）"
$ok = $true
if ($mode -eq "full") {
    $tops = & $Adb -s $device shell "find /sdcard -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's#.*/##'" 2>$null
    $tops = $tops | Where-Object { $_ -and $_ -ne $Exclude -and -not $_.StartsWith(".") }
} else {
    $tops = @($Target)
}
foreach ($t in $tops) {
    $local = Join-Path $Dest $t
    $rc = Get-RemoteCount $device "/sdcard/$t"
    $lc = Get-LocalCount $local
    if ($rc -eq $lc) {
        Say ("  {0,-14} 手机 {1,6}  电脑 {2,6}  一致" -f $t, $rc, $lc)
    } else {
        Say ("  {0,-14} 手机 {1,6}  电脑 {2,6}  差 {3}" -f $t, $rc, $lc, ($rc - $lc))
        $ok = $false
    }
}

$sum = Get-ChildItem $Dest -Recurse -File -ErrorAction SilentlyContinue |
       Measure-Object -Property Length -Sum
Say ""
Say ("完成 {0} 文件 / {1:N2} GB / 用时 {2:N1} 分钟" -f $sum.Count, ($sum.Sum / 1GB), $total.Elapsed.TotalMinutes)
Say "路径： $Dest"
if (-not $ok) {
    Say "!! 有目录文件数对不上，重跑： backup.ps1 dir <目录名>"
    exit 1
}
