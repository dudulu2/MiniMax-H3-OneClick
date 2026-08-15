@echo off
setlocal
cd /d "%~dp0"
title MiniMax H3 One-Click Installer

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0OneClick-Install.ps1"
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo MiniMax H3 installation did not complete. Review the popup and logs above.
    echo Exit code: %EXITCODE%
    echo.
    pause
)

exit /b %EXITCODE%
