@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Verify-P2.ps1"  %*
set "kitExit=%ERRORLEVEL%"
exit /b %kitExit%
