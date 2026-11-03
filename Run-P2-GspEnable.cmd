@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-P2.ps1" -Mode Apply %*
set "kitExit=%ERRORLEVEL%"
exit /b %kitExit%
