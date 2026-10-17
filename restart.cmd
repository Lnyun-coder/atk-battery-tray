@echo off
rem ============================================================
rem  ATK Battery Tray - clean restart
rem  Kills stale instances, clears state files, starts fresh.
rem ============================================================
setlocal
cd /d "%~dp0"

echo [1/4] Stopping any running plugin instances...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'atk-tray\.ps1|atk-worker\.ps1' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Host ('  killed pid=' + $_.ProcessId) } catch { } }"

echo [2/4] Waiting for handles to release...
timeout /t 3 /nobreak >nul

echo [3/4] Clearing state files...
if exist "status.txt"   del /q "status.txt"
if exist "refresh.req"  del /q "refresh.req"

echo [4/4] Starting plugin...
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0atk-tray.ps1" -LauncherMode

echo.
echo Done. The tray icon should appear in a few seconds.
timeout /t 4 /nobreak >nul
exit /b 0
