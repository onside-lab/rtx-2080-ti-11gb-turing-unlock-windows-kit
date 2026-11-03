@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Inspect-P3Usb.ps1"  %*
set "kitExit=%ERRORLEVEL%"
exit /b %kitExit%
