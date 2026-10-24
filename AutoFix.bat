@echo off
setlocal
rem auto-fix_Win launcher. Asks for administrator rights once, then runs the
rem read-only scan with the Windows PowerShell 5.1 built into Windows 10 and 11.
rem Nothing to install. -ExecutionPolicy Bypass applies to this one run only.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem fltmc only succeeds for an administrator. --elevated stops a second request.
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto run
if /i "%~1"=="--elevated" goto noadmin

echo.
echo   auto-fix_Win asks for administrator rights to read crash dumps, the CBS and
echo   DISM logs and the device install log. The scan only reads logs and changes
echo   nothing. Windows will ask you once.
set "AF_SELF=%~f0"
"%PS%" -NoProfile -Command "try { Start-Process -FilePath $env:AF_SELF -ArgumentList '--elevated' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
if not errorlevel 1 exit /b 0

:noadmin
echo.
echo   Continuing without administrator rights. Crash dumps, the CBS and DISM logs
echo   and the device install log will be skipped.

:run
set "OPEN=-Open"
if defined AUTOFIX_CI set "OPEN="
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-AutoFixer.ps1" %OPEN%
set "RC=%ERRORLEVEL%"
if not defined AUTOFIX_CI (
    echo.
    pause
)
exit /b %RC%
