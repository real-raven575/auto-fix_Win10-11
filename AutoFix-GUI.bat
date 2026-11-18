@echo off
setlocal
rem Auto-Fixer WINDOW launcher (the GUI). Asks for administrator rights once, then
rem opens the Auto-Fixer window with the Windows PowerShell 5.1 built into Windows
rem 10 and 11. AutoFix.bat still opens the console menu.
rem Nothing to install. -ExecutionPolicy Bypass applies to this one run only.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

rem CI only checks the files, so it never asks for administrator rights.
if defined AUTOFIX_CI goto run
rem fltmc only succeeds for an administrator. --elevated stops a second request.
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto run
if /i "%~1"=="--elevated" goto noadmin

echo.
echo   Auto-Fixer asks for administrator rights to read crash dumps, the CBS and
echo   DISM logs and the device install log. The scan only reads logs and changes
echo   nothing. Windows will ask you once.
rem Wait for a key so this text can be read before the Windows prompt covers it.
if not defined AUTOFIX_CI (
    echo.
    echo   Press any key to continue. Windows will then ask for administrator rights.
    pause >nul
)
set "AF_SELF=%~f0"
"%PS%" -NoProfile -Command "try { Start-Process -FilePath $env:AF_SELF -ArgumentList '--elevated' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
if not errorlevel 1 exit /b 0

:noadmin
echo.
echo   Continuing without administrator rights. Crash dumps, the CBS and DISM logs
echo   and the device install log will be skipped.
if not defined AUTOFIX_CI (
    echo   Press any key to continue.
    pause >nul
)

:run
rem -STA: WPF windows need a single-threaded PowerShell. The PowerShell console is
rem hidden; if the window cannot open, a message box says why.
rem CI cannot show a window, so it only checks that the files load.
if defined AUTOFIX_CI (
    "%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-AutoFixer.ps1" -Gui -GuiCheckOnly
    exit /b
)
start "Auto-Fixer" "%PS%" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-AutoFixer.ps1" -Gui
exit /b 0
