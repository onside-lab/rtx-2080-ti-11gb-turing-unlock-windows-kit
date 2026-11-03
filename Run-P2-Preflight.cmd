@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Set-GspMode.ps1" -Preflight %*
set "kitExit=%ERRORLEVEL%"
exit /b %kitExit%
