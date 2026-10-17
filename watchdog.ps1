# ATK 电量插件守护进程
#
# 作用：每 30 秒检查一次托盘进程是否还活着，不在就自动拉起来。
#   托盘进程会被某些外部因素终止（系统清理工具、Explorer 重启等），
#   手动重启很烦，所以用这个守护脚本兜底。
#
# 用法：双击 watchdog.cmd 启动守护（它自己常驻，托盘图标由它拉起）

$ErrorActionPreference = 'Continue'

$dir = $PSScriptRoot
$trayScript = Join-Path $dir 'atk-tray.ps1'
$logFile = Join-Path $dir 'watchdog.log'

if (-not (Test-Path $trayScript)) {
    Write-Host "找不到 atk-tray.ps1，路径: $trayScript" -ForegroundColor Red
    exit 1
}

function Write-WLog {
    param([string]$msg)
    try {
        $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
        Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Test-TrayRunning {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine -like '*atk-tray.ps1*') { return $true }
        }
    } catch { }
    return $false
}

Write-WLog '守护进程启动'
Write-Host 'ATK 电量插件守护进程已启动，每 30 秒检查一次。按 Ctrl+C 退出。' -ForegroundColor Cyan

$restarts = 0
while ($true) {
    if (-not (Test-TrayRunning)) {
        $restarts++
        Write-WLog "检测到托盘未运行，第 $restarts 次拉起"
        Write-Host ("[{0:HH:mm:ss}] 托盘未运行，正在拉起…" -f (Get-Date)) -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $trayScript, '-LauncherMode'
            )
        } catch {
            Write-WLog "拉起失败: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 8      # 给托盘一点启动时间，避免重复拉起
    }
    Start-Sleep -Seconds 30
}
