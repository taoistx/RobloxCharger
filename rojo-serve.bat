@echo off
setlocal

cd /d "%~dp0"
rojo serve default.project.json

if errorlevel 1 (
    echo.
    echo Rojo server failed to start. Make sure Rojo is installed and available in PATH.
    pause
)

endlocal
