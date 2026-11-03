@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Collect-P3Return.ps1"  %*
set "kitExit=%ERRORLEVEL%"
exit /b %kitExit%
