@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

set "targetRoot=D:\MiniMaxH3"
if not exist "%targetRoot%\" if not exist "%targetRoot%\downloads\" if not exist "%targetRoot%\runtime\" if not exist "%targetRoot%\ComfyUI\" (
    echo.
    echo 您还没有在 D:\MiniMaxH3 配置第一步安装环境。
    pause
    exit /b 2
)

set "installer="
for /d %%D in ("%~dp0..\*") do (
    if exist "%%~fD\Start-Installer.bat" set "installer=%%~fD\Start-Installer.bat"
)
if not defined installer (
    echo Could not find the first-step installer:
    echo Please keep both installer step folders together.
    pause
    exit /b 1
)

echo Close any currently stuck MiniMax H3 installer window first.
echo Starting the installer with the China PyPI mirror and retry settings...
call "%installer%"
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" (
    echo.
    echo The installer returned exit code %exitCode%.
    pause
)
exit /b %exitCode%
