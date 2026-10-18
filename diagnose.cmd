@echo off
rem ATK Battery Tray - compatibility diagnostic
rem Shows all HID interfaces and raw protocol replies.
rem Copy the whole output and send it to the developer.
setlocal
cd /d "%~dp0"
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0atk-tray.ps1" -Diagnose
echo.
pause
