@echo off
rem ===========================================================
rem  ATK Battery Tray - clean restart / repair
rem
rem  Thorough cleanup so stale or hung instances cannot keep
rem  holding status.txt:
rem    1. kill every powershell running our scripts
rem    2. kill ATKBattery.exe if present
rem    3. wait for handles to be released
rem    4. remove / rename state files that are still locked
rem    5. start the plugin again without a console window
rem ===========================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo [1/5] Stopping plugin processes...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$k=0; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -and ($_.CommandLine -match 'atk-tray\.ps1' -or $_.CommandLine -match 'atk-worker\.ps1') } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Host ('      killed pid=' + $_.ProcessId); $k++ } catch { Write-Host ('      cannot kill pid=' + $_.ProcessId) } }; Write-Host ('      total killed: ' + $k)"

echo [2/5] Killing ATKBattery.exe if running...
taskkill /f /im ATKBattery.exe >nul 2>&1
if errorlevel 1 (echo       not running) else (echo       killed)

echo [3/5] Waiting for file handles...
timeout /t 4 /nobreak >nul

echo [4/5] Clearing state files...
if exist "status.txt.tmp" del /q "status.txt.tmp" >nul 2>&1
if exist "refresh.req"    del /q "refresh.req" >nul 2>&1
if exist "status.txt" (
    del /q "status.txt" >nul 2>&1
    if exist "status.txt" (
        echo       still locked, renaming out of the way...
        ren "status.txt" "status.stale.txt" >nul 2>&1
    )
)
if exist "status.txt" (
    echo       WARNING: status.txt is still locked
) else (
    echo       cleared
)

echo [5/5] Starting plugin without window...
if exist "launch-hidden.vbs" (
    start "" wscript.exe "%~dp0launch-hidden.vbs"
    echo       via launch-hidden.vbs
) else (
    start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0atk-tray.ps1"
    echo       via powershell directly
)

echo.
echo Done. Check the notification area in a few seconds.
timeout /t 5 /nobreak >nul
exit /b 0
