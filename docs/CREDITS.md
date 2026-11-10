# Credits

Auto-Fixer is written by **raven575, Wrench of TEAM Auto-Fixer & Inkwell of TEAM Creative "Herd of Helpers"**.

Wrench and Inkwell are Claude, an AI model by Anthropic, which helped write the code.

Auto-Fixer uses the [MIT License](../LICENSE), Copyright (c) 2026 raven575. It is provided "as is", without warranty of any kind. The same list is in the tool: main menu **9 (A)bout and credits**.

This page is a good-faith list of the work Auto-Fixer relies on. It is not legal advice.

## Parts of Windows this tool uses

All of these come with Windows 10 and 11. Copyright for each: **Microsoft Corporation**. Auto-Fixer calls them; it does not copy or ship any of them, so their use is covered by the Windows license on that PC.

| Part | How Auto-Fixer uses it | Why this and not something else |
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
| Windows Update | Only for DISM RestoreHealth, only with the Online switch on, and always announced first | The one place Auto-Fixer is approved to connect to |
| File Explorer (`explorer.exe`) | Opens this PC's logs folder when you press X on any menu (main menu 7) | Only opens the folder; nothing is changed |
| Shutdown (`shutdown.exe`) | The optional restart after repairs, with a countdown you can cancel | Built in and can be cancelled (`shutdown /a`) |
| Task Kill (`taskkill.exe`) | Stops a stalled SFC or DISM step, and only after you say yes | Stops the whole process tree |
| Credential Manager (`cmdkey.exe`) | Lists saved network-drive passwords by server name and removes the ones you pick (`cmdkey /list`, `cmdkey /delete`) | Microsoft's own tool for saved Windows passwords; it never shows a password |
| Net (`net.exe`) | `net use \\server\share /delete` drops a share connection with no drive letter and no open files, after its saved password is removed | So Windows stops using the old login; mapped drives are never removed |
| SMB client | Read-only: mapped drives and open share connections (`Get-SmbMapping`, `Get-SmbConnection`) | Shows open files, so a busy connection is never dropped |
| Disk Cleanup (`cleanmgr.exe`) | Clean up > Disk Cleanup: `cleanmgr /sagerun` with only the items you tick, in Auto-Fixer's own settings slot, emptied again afterwards | Microsoft's own cleaner knows what each item may remove; error reports and crash dumps stay locked because the scan reads them |
| Optimize Drives (`defrag.exe`) | Clean up > Optimize drives: `defrag X: /L` (TRIM) for SSDs, `defrag X: /D` for hard drives, after a Y | The engine behind Windows' own Optimize Drives; it prints a % for the progress bar. An SSD is never defragged |
| File system utility (`fsutil.exe`) | Reads whether TRIM is on (`fsutil behavior query DisableDeleteNotify`); Technician mode can turn it back on | The documented switch for TRIM on NTFS |
| Storage cmdlets | Read-only: `Get-Volume`, `Get-Partition`, `Get-PhysicalDisk` for drive letters, free space and SSD or hard drive | Built into Windows; nothing to install |
| Task Scheduler | Technician mode: `Enable-ScheduledTask` turns the weekly Optimize Drives task back on, after a Y | Windows' own task; Auto-Fixer creates no tasks |
| Kerberos list (`klist.exe`) | `klist purge` on a domain PC, after a password is removed, only if you say yes | Clears only your own sign-in tickets; Windows gets new ones at next use |
| Domain controller locator (`nltest.exe`) | Read-only: `nltest /dsgetdc` checks that Windows can find a domain controller | The same locator Windows uses to sign in |
| Device registration (`dsregcmd.exe`) | Read-only: `dsregcmd /status` checks whether the PC is joined to Azure AD (Entra ID) | Windows cannot join a domain while it is; Auto-Fixer stops early and never disconnects it |
| Windows Time (`w32tm.exe`) | Read-only: `w32tm /stripchart` compares the clock with the domain controller | Domain sign-in fails when the clock is more than 5 minutes off |
| DNS client | Read-only: finds a domain's controllers (`Resolve-DnsName`, SRV records), and the DNS lookup network tool | The first thing a domain join needs |
| Classic Outlook | Office and Outlook > Mail dates: opens temp copies of your PSTs in the background for a moment (Outlook's own `AddStore` and `RemoveStore`), reads the mail count and dates, then closes Outlook and deletes the copies, after a Y | Only Outlook can read a PST; working on copies means your own files are never opened or changed |
| Ping (`ping.exe`) | Network tools: `ping -n 4` to the gateway, a DNS server or a target you type, announced first | The standard first test of a connection |
| Trace route (`tracert.exe`) | Network tools: `tracert -d -h 30 -w 1000` to a target you pick, announced first; Esc stops it | Shows where along the way a connection stops |
| IP configuration (`ipconfig.exe`) | Network tools: `ipconfig /flushdns` and `ipconfig /release` + `/renew`, each after Y/N | Microsoft's own tool for the DNS cache and DHCP addresses |
| Network shell (`netsh.exe`) | Technician: `netsh winsock reset` and `netsh int ip reset`, after a red warning and Y/N | The documented reset for a broken network stack; needs a restart |
| Network cmdlets | `Get-NetIPConfiguration`, `Get-NetTCPConnection` (read-only) and `Restart-NetAdapter` (Technician, after Y/N) | Built into Windows 8 and later |
| Local account cmdlets | `Get-LocalUser`, `Get-LocalGroupMember`, `New-LocalUser`, `Add-LocalGroupMember`, `Set-LocalUser`, `Enable-LocalUser` list local admins, create one or reset a password, each only after you say yes | Built into Windows PowerShell 5.1; the password goes from a hidden prompt to Windows and is never saved or logged |
| User profile provider | Technician: `Win32_UserProfile.ChangeOwner` hands a profile to another account on the same PC, after a restore point, a registry backup and Y/N | Built into Windows since Vista SP1; nothing is copied, and a replaced profile is never deleted |
| Registry editor (console) (`reg.exe`) | `reg export` of the profile's ProfileList key before a profile move | So the move can be checked or undone by hand |
| Settings: Access work or school (`ms-settings:workplace`) | Opened so you can disconnect an Azure AD (Entra ID) only PC, after the warnings | Microsoft documents this page, not a script, for that unjoin; `dsregcmd /debug /leave` is used only on hybrid PCs |
| Domain join cmdlets | `Add-Computer`, `Remove-Computer` and `Test-ComputerSecureChannel` join, leave and repair the trust, each only after you say yes | Built into Windows PowerShell 5.1; the password goes into Windows' own sign-in prompt |
| Message (`msg.exe`) | `Tools\Retry-StoreAppUpdates.ps1` in Background Mode: a pop-up that warns the signed-in user before a Store app is force-closed | Built into Windows Pro and Enterprise; with no way to warn, the app is left open |
| Microsoft Store and its device management bridge (`MDM_EnterpriseModernAppManagement_AppManagement01`, `ms-windows-store:`) | `Tools\Retry-StoreAppUpdates.ps1`: asks the Store to check for and install app updates, after a Y or `-Go YES`; this uses the internet (Microsoft Store servers) | The same check as pressing Get updates in the Store; the bridge works as SYSTEM, so a normal administrator gets the Store page instead |
| Windows power management | Keeps the PC awake while a long repair runs (`SetThreadExecutionState`) | Changes no power setting and ends with the tool |
| .NET Framework | Starting programs, the HTML report and text matching | Comes with Windows PowerShell |
| Your web browser | Opens the HTML report when you ask | The report is a plain file; Auto-Fixer does not choose or ship a browser |

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

Microsoft, Windows, PowerShell and Windows Update are trademarks of the Microsoft group of companies. GitHub is a trademark of GitHub, Inc. Claude is a trademark of Anthropic. Auto-Fixer is not made, endorsed or supported by Microsoft, GitHub or Anthropic.
