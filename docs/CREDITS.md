# Credits

auto-fix_Win is written by **raven575, Wrench of TEAM Auto-Fixer & Inkwell of TEAM Creative "Herd of Helpers"**.

Wrench and Inkwell are Claude, an AI model by Anthropic, which helped write the code.

auto-fix_Win uses the [MIT License](../LICENSE), Copyright (c) 2026 raven575. It is provided "as is", without warranty of any kind. The same list is in the tool: main menu **5 (A)bout and credits**.

This page is a good-faith list of the work auto-fix_Win relies on. It is not legal advice.

## Parts of Windows this tool uses

All of these come with Windows 10 and 11. Copyright for each: **Microsoft Corporation**. auto-fix_Win calls them; it does not copy or ship any of them, so their use is covered by the Windows license on that PC.

| Part | How auto-fix_Win uses it | Why this and not something else |
| --- | --- | --- |
| Windows PowerShell 5.1 (`powershell.exe`) | Runs the whole tool | On every Windows 10 and 11 PC, so there is nothing to install |
| Command Prompt (`cmd.exe`) | Runs `AutoFix.bat`, the double-click launcher | A `.bat` file opens with a double-click and can ask for administrator rights once |
| Filter Manager control (`fltmc.exe`) | The launcher runs it only to test for administrator rights | It succeeds only for an administrator and changes nothing |
| Windows Event Log | Reads the System, Application, Setup, Windows Update and four app logs, read-only (`Get-WinEvent`) | Built in, with fast filters, on both PowerShell versions; `wevtutil` would need text parsing |
| Reliability Monitor | Reads the stability score and the crash and install records (`Win32_ReliabilityStabilityMetrics`, `Win32_ReliabilityRecords`) | Holds install results that the event logs can miss |
| Device Manager data | Finds devices with a problem code (`Win32_PnPEntity`) | The same codes Device Manager shows |
| Windows system information | The Windows version for the report; serial numbers are read only so they can be hidden (`Win32_OperatingSystem`, `Win32_BIOS`, `Win32_BaseBoard`, `Win32_DiskDrive`) | Built in; serial numbers are never stored |
| Windows crash and repair logs | Read-only, never moved or deleted: `Report.wer`, `Minidump`, `MEMORY.DMP`, `LiveKernelReports`, `CBS.log`, `dism.log`, `setupapi.dev.log` | They hold the evidence of what went wrong |
| System Restore and Volume Shadow Copy | Offers a restore point before a repair and checks that it was made (`SystemRestore`, `Win32_ShadowCopy`) | The WMI method works in PowerShell 5.1 and 7; `Checkpoint-Computer` is only in 5.1 |
| System File Checker (`sfc.exe`) | `sfc /scannow` in the repair menu | Microsoft's own tool for checking and repairing protected Windows files |
| DISM (`dism.exe`) | CheckHealth, ScanHealth, RestoreHealth and StartComponentCleanup in the repair menu | Microsoft's own tool; SFC copies its clean files from the store DISM repairs |
| Windows Update | Only for DISM RestoreHealth, only with the Online switch on, and always announced first | The one place auto-fix_Win is approved to connect to |
| Shutdown (`shutdown.exe`) | The optional restart after repairs, with a countdown you can cancel | Built in and can be cancelled (`shutdown /a`) |
| Task Kill (`taskkill.exe`) | Stops a stalled SFC or DISM step, and only after you say yes | Stops the whole process tree |
| Windows power management | Keeps the PC awake while a long repair runs (`SetThreadExecutionState`) | Changes no power setting and ends with the tool |
| .NET Framework | Starting programs, the HTML report and text matching | Comes with Windows PowerShell |
| Your web browser | Opens the HTML report when you ask | The report is a plain file; auto-fix_Win does not choose or ship a browser |

## Optional

| Part | Copyright and license | Use |
| --- | --- | --- |
| PowerShell 7 (`pwsh`) | Microsoft Corporation, MIT License | The tool also runs on it, but never needs it |

## Used only to build and test it

These run in GitHub's test system or on a developer's PC. They are not part of the download. Licenses read from each project's LICENSE file on 2026-10-25.

| Tool | Copyright and license | Use |
| --- | --- | --- |
| Pester | Pester team, Apache License 2.0 | Runs the automated tests |
| PSScriptAnalyzer | Microsoft Corporation, MIT License | Checks the code for common mistakes |
| PowerShell Gallery | Microsoft Corporation | Where the tests download Pester and PSScriptAnalyzer |
| GitHub Actions | GitHub, Inc. | Runs every test on a clean Windows machine, under PowerShell 5.1 and 7 |
| actions/checkout and actions/upload-artifact | GitHub, Inc. and contributors, MIT License | Copy the code in and save the test results |

## Earlier work it builds on

- **SFC + DISM Repair Tool v1.1** by raven575, kept unchanged in [`reference/sfc-dism-v1.1`](../reference/sfc-dism-v1.1). The repair menu, time estimates and stall watchdog started there.

## Trademarks

Microsoft, Windows, PowerShell and Windows Update are trademarks of the Microsoft group of companies. GitHub is a trademark of GitHub, Inc. Claude is a trademark of Anthropic. auto-fix_Win is not made, endorsed or supported by Microsoft, GitHub or Anthropic.
