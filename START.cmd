@echo off
rem ATK Battery Tray launcher - double-click to start
rem Shows startup messages briefly, then closes.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0atk-tray.ps1" -LauncherMode
exit /b 0
