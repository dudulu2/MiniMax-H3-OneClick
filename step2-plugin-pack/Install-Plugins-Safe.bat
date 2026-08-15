@echo off
setlocal
cd /d "%~dp0"

set "NO_PAUSE=0"
if /I "%~1"=="--no-pause" set "NO_PAUSE=1"

rem Use the China PyPI mirror as the first network fallback. Local wheels are
rem attempted before this source by Install-Step2-Dependencies-LocalFirst.ps1.
set "PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple"
set "PIP_DEFAULT_TIMEOUT=120"
set "PIP_RETRIES=3"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"
set "PIP_PREFER_BINARY=1"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Step2-Runtime.ps1" -Phase Pre
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" goto :failed

rem Try the bundled dependency wheelhouse completely offline first. Exit code 2
rem means the wheelhouse is missing/incomplete and is an expected network-fallback
rem condition. Any other non-zero code is a real pre-install failure.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Step2-Dependencies-LocalFirst.ps1"
set "localWheelExit=%ERRORLEVEL%"
if "%localWheelExit%"=="0" (
    set "PIP_FIND_LINKS=%~dp0wheels\dependencies"
    echo Local Step 2 dependency wheelhouse is ready; local wheels have priority.
) else if "%localWheelExit%"=="2" (
    echo Local Step 2 dependency wheelhouse is unavailable or incomplete; continuing with mirror fallback.
) else (
    set "exitCode=%localWheelExit%"
    goto :failed
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ComfyUI-Plugins-Safe.ps1" -AutoConfirm
set "installExit=%ERRORLEVEL%"

rem Always run postflight after the plugin installer was invoked. Besides runtime
rem verification, it detects soft failures from the installer log and restores
rem previous plugin backups after copy failures where possible.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Step2-Runtime.ps1" -Phase Post
set "postExit=%ERRORLEVEL%"

if not "%installExit%"=="0" (
    set "exitCode=%installExit%"
    goto :failed
)
if not "%postExit%"=="0" (
    set "exitCode=%postExit%"
    goto :failed
)

exit /b 0

:failed
echo.
echo Plugin installation or runtime verification failed. Review the message and log path printed above.
if "%NO_PAUSE%"=="0" pause
exit /b %exitCode%
