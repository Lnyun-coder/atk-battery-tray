@echo off
rem ATK Battery Tray launcher
rem Double-click to start
cd /d "%~dp0"
start "" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0atk-tray.ps1"
exit /b 0
