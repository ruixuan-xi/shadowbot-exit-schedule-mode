@echo off
rem ============================================================
rem  ShadowBot - Exit Schedule Mode (one click)
rem  Entry point. Real logic lives in exit-schedule-mode.ps1
rem
rem  Usage:
rem    exit-schedule-mode.bat           -> run, show result, auto-close on success
rem    exit-schedule-mode.bat /quiet    -> run minimized, no window, popup on failure
rem
rem  Exit codes: 0 ok / 1 switch failed / 2 task still running / 3 env error
rem ============================================================

chcp 65001 >nul 2>&1
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%exit-schedule-mode.ps1"

if not exist "%PS1%" (
    echo [ERROR] exit-schedule-mode.ps1 not found next to this bat file.
    echo         Expected: "%PS1%"
    if /i not "%~1"=="/quiet" pause
    exit /b 3
)

set "QARG="
if /i "%~1"=="/quiet" set "QARG=-Quiet"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %QARG%
set "RC=%ERRORLEVEL%"

if /i "%~1"=="/quiet" exit /b %RC%

echo.
echo ----------------------------------------

if "%RC%"=="0" (
    rem 成功：3 秒后自动关窗，不用手动关
    echo This window will close in 3 seconds...
    timeout /t 3 >nul 2>&1 || ping -n 4 127.0.0.1 >nul
) else (
    rem 失败：窗口留着，让人看清原因
    echo Press any key to close this window...
    pause >nul
)
exit /b %RC%
