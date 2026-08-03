@echo off
setlocal
cd /d "%~dp0"

rem PowerShell builds and installs the local Edit-mode Studio plugin.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-pose-tuner.ps1"
set "TUNER_EXIT_CODE=%errorlevel%"

if not "%TUNER_EXIT_CODE%"=="0" (
    echo.
    echo [ERROR] Pose tuner installation stopped with exit code %TUNER_EXIT_CODE%.
    pause
)

exit /b %TUNER_EXIT_CODE%
