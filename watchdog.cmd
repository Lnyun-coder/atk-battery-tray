@echo off
rem ATK Battery Tray watchdog launcher
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0watchdog.ps1"
