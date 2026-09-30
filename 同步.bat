@echo off
chcp 65001 >nul
setlocal
set REPO=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%tools\sync.ps1" %*
echo.
pause