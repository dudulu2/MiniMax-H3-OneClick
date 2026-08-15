@echo off
setlocal
cd /d "%~dp0"

rem Always use the China PyPI mirror for this plugin installation process.
set "PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple"
set "PIP_DEFAULT_TIMEOUT=120"
set "PIP_RETRIES=3"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Step2-Runtime.ps1" -Phase Pre
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" goto :failed

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ComfyUI-Plugins-Safe.ps1" -AutoConfirm
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" goto :failed

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Step2-Runtime.ps1" -Phase Post
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" goto :failed

exit /b 0

:failed
echo.
echo Plugin installation or runtime verification failed. Review the message and log path printed above.
pause
exit /b %exitCode%
