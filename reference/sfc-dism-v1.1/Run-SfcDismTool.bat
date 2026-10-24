@echo off
rem SFC + DISM Repair Tool launcher. Keep this file next to SfcDismTool.ps1 and double-click it.
rem The script asks for administrator rights itself (one UAC prompt).
title SFC + DISM Repair Tool
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0SfcDismTool.ps1"
