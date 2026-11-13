@echo off
setlocal
rem Auto-Fixer WINDOW launcher (the GUI). Asks for administrator rights once, then
rem opens the Auto-Fixer window with the Windows PowerShell 5.1 built into Windows
rem 10 and 11. AutoFix.bat still opens the console menu.
rem Nothing to install. -ExecutionPolicy Bypass applies to this one run only.
rem One hop on purpose: this file never starts itself again and never hides a
rem window, so the start looks to security products like what it is.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "AF_PS=%PS%"
set "AF_SCRIPT=%~dp0Start-AutoFixer.ps1"

rem CI cannot show a window, so it only checks that the files load.
if defined AUTOFIX_CI (
    "%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%AF_SCRIPT%" -Gui -GuiCheckOnly
    exit /b
)

rem A remote tool's background mode or a service runs as SYSTEM, where nobody can
rem see a window. Stop here instead of opening one that no one can use.
"%SystemRoot%\System32\whoami.exe" /user | "%SystemRoot%\System32\find.exe" /i "S-1-5-18" >nul
if not errorlevel 1 goto background

rem fltmc only succeeds for an administrator.
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto run

echo.
echo   Auto-Fixer asks for administrator rights to read crash dumps, the CBS and
echo   DISM logs and the device install log. The scan only reads logs and changes
echo   nothing. Windows will ask you once.
rem Wait for a key so this text can be read before the Windows prompt covers it.
echo.
echo   Press any key to continue. Windows will then ask for administrator rights.
pause >nul
rem Start the window itself as administrator: no second copy of this file.
"%PS%" -NoProfile -Command "try { $a = '-NoProfile -STA -ExecutionPolicy Bypass -File ' + [char]34 + $env:AF_SCRIPT + [char]34 + ' -Gui'; Start-Process -FilePath $env:AF_PS -ArgumentList $a -Verb RunAs -WindowStyle Minimized -ErrorAction Stop; exit 0 } catch { exit 1 }"
if not errorlevel 1 exit /b 0

echo.
echo   Continuing without administrator rights. Crash dumps, the CBS and DISM logs
echo   and the device install log will be skipped.
echo   Press any key to continue.
pause >nul

:run
rem -STA: WPF windows need a single-threaded PowerShell. Its console starts
rem minimized (not hidden) and shows any error; a message box says it too.
start "Auto-Fixer" /min "%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%AF_SCRIPT%" -Gui
exit /b 0

:background
echo.
echo   Auto-Fixer's window cannot open in a background or SYSTEM session, because
echo   nobody can see it there. Run AutoFix-GUI.bat in the signed-in user's visible
echo   session instead, or use AutoFix.bat for a console scan.
exit /b 2
