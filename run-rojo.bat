@echo off
setlocal

rem Always serve this project, even when the launcher is opened from elsewhere.
cd /d "%~dp0"

set "ROJO_COMMAND="
where rojo >nul 2>&1
if not errorlevel 1 set "ROJO_COMMAND=rojo"

rem Fall back to the current machine's standalone Rojo installation.
if not defined ROJO_COMMAND if exist "C:\Rojo\rojo.exe" set "ROJO_COMMAND=C:\Rojo\rojo.exe"

if not defined ROJO_COMMAND (
    echo [ERROR] Rojo was not found.
    echo Install Rojo or add rojo.exe to PATH, then run this file again.
    pause
    exit /b 1
)

title MyRobloxGame - Rojo Server
echo Starting Rojo for MyRobloxGame...
echo In Roblox Studio, connect the Rojo plugin to localhost:34872.
echo Press Ctrl+C to stop the server.
echo.

"%ROJO_COMMAND%" serve "%~dp0default.project.json"
set "ROJO_EXIT_CODE=%errorlevel%"

if not "%ROJO_EXIT_CODE%"=="0" (
    echo.
    echo [ERROR] Rojo stopped with exit code %ROJO_EXIT_CODE%.
    pause
)

exit /b %ROJO_EXIT_CODE%
