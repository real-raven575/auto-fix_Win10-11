# auto-fix_Win10-11

Auto-Fixer is a PowerShell app that reads a Windows PC's existing logs, finds crashes and failures, explains them in plain English, and runs safe, reversible fixes with the user's approval. It shows a live activity list, a progress bar and a time estimate the whole way through.

## Status

**M1: scan and report.** Read-only. It reads nine log sources, matches them against issue signatures and writes a JSON and HTML report.

**M2: menu and user modes.** A console menu, a first-launch choice between Standard and Technician mode, and `settings.json`.

**Release 1.2: SFC and DISM repairs.** Main menu item 2 brings in raven575's SFC + DISM Repair Tool v1.1 (kept unchanged in `reference/`), with the gaps from its review fixed. See [Repair system files](#repair-system-files).

**Network and domain (next version).** Main menu item 3 clears saved network-drive passwords and checks, joins, repairs or leaves a domain. See [Network and domain](#network-and-domain).

**Clean up (next version).** Main menu item 4 runs Windows' own Disk Cleanup for your files and system files, and TRIM for SSDs or defrag for hard drives. See [Clean up](#clean-up).

## Run it

Easiest: double-click **`AutoFix.bat`**. It asks for administrator rights once and opens the menu with the Windows PowerShell 5.1 built into Windows 10 and 11. If you say No to the Windows prompt, it still runs and the scan skips the admin-only sources. Nothing to install: Standard mode only ever uses what comes with Windows. Technician mode has optional **online add-ons** that may download Microsoft tools, only when you turn them on in Settings (see below).

The menu: **1** Run a (s)can, **2** (R)epair Windows files (SFC and DISM), **3** (N)etwork and domain, **4** (C)lean up, **5** (O)ffice and Outlook, **6** View the last re(p)ort, **7** Open the logs folder in E(x)plorer, **8** Se(t)tings, **9** (A)bout and credits, (Q)uit (press Q; only items 1 to 9 have a number key). Every menu works the same way: use the arrow keys and Enter, press the item's number, or press the letter shown in brackets. **(Q)uit** is in every menu; below the main menu it asks "Are you sure?" first. **Esc** goes back in every menu (the same as **B**), quits from the main menu, and means No at any Y/N question.

- **First launch** asks for the mode. **Standard** (press Enter) is recommended: it explains each step and asks before any change. **Technician** is for experienced users and runs repairs such as SFC and DISM from one plan screen; it shows a warning and needs **Y**. Steps that delete data, are permanent or go online warn in both modes.
- **Screen style.** Branded is the default: the Auto-Fixer banner, a start screen and Wrench art. **Plain** shows the same screens without the art; pick it under Settings or start with `-Plain` for one run. With `NO_COLOR` set, or a console without VT support, the screens are drawn Plain without the background pattern. A window smaller than 80x25, redirected output or `TERM=dumb` gets the simple text screens.
- **Settings** changes the mode, the screen style and the switches, all off by default: show sensitive data on screen (no prompt), save reports without redaction (warns, and every scan asks Y/N again before saving real values), go online when a step needs it (warns and lists the only places it may contact), and, in Technician mode only, **online add-ons (Microsoft tools)**.
- **Online add-ons** (Technician only, off by default) let an add-on step download a Microsoft tool that Windows does not have and go online. Turning it on warns, lists every place an add-on may contact and needs **Y**; it also turns *Go online* on. Turning *Go online* off, or going back to Standard mode, turns the add-ons off. Each download and connection is announced and asks Y/N again. Places: Microsoft's AzCopy download (`aka.ms` and the Microsoft server it forwards to), Microsoft 365 import storage (`<name>.blob.core.windows.net`), Microsoft sign-in and Exchange Online (`login.microsoftonline.com`, `outlook.office365.com`), the PowerShell Gallery (`www.powershellgallery.com`), the Office Deployment Tool (`www.microsoft.com`, `download.microsoft.com`), Microsoft Get Help (`aka.ms` and the Microsoft server it forwards to), Office activation (Microsoft's activation servers, through Office's own `OSPP.VBS`) and an Office download link you type (its server is shown first). With the switch off, an add-on step shows a note and offers to open Settings; nothing is downloaded.
- **Viewing results.** Main menu **6** shows the newest scan right in the console, with no web browser needed (handy over remote sessions): a summary with the count at each severity, the findings worst first, and for each one its explanation, suggested fixes and evidence. The same menu opens the saved report in a browser or picks one of the last 9 scans. After a scan, press **V** to view its results straight away. The viewer reads the saved scan file only (`AF-...-scan.json`, or `results.json` from older versions), so it shows exactly what was saved, redacted unless you chose otherwise.
- Choices are saved in `settings.json` next to `Start-AutoFixer.ps1`. It holds only the mode, the screen style and the switches, never names, serials or keys. A damaged file is renamed to `settings.json.bad` and you are asked for the mode again.

Or from an elevated PowerShell window (Windows PowerShell 5.1 or PowerShell 7) on Windows 10 or 11:

```powershell
.\Start-AutoFixer.ps1                          # the menu
.\Start-AutoFixer.ps1 -Plain                   # the menu in the Plain look, this run only
.\Start-AutoFixer.ps1 -NoMenu                  # one scan of the last 14 days, no menu
.\Start-AutoFixer.ps1 -NoMenu -Days 30 -Open
.\Start-AutoFixer.ps1 -NoMenu -ShowSensitive   # real values on screen only, no prompt
.\Start-AutoFixer.ps1 -NoMenu -SaveSensitive   # real values in saved reports, after a one-key Y/N "are you sure?" warning
.\Start-AutoFixer.ps1 -ShowLastReport          # the newest saved scan as plain text, then exit (Enter-PSSession, scripts)
.\Start-AutoFixer.ps1 -ShowLastReport -RunId 20261029-233547Z
```

`-NoMenu` ignores `settings.json` and uses only the options given. With redirected input (scripts, CI) it scans once even without `-NoMenu`.

**Sensitive data is redacted everywhere by default**, on screen and in saved files: user, PC and domain names, serial numbers and service tags (BIOS, motherboard and disks), profile folder names in paths, email, IP and MAC addresses, account SIDs and product keys. Each value becomes a stable placeholder such as `<IP-1>`, so the same address shows the same placeholder across a report, but the real value is never stored.

Without admin rights the scan still runs, but skips crash dumps, CBS/DISM and the device install log. Reports are saved in this PC's folder (see [Where logs are saved](#where-logs-are-saved)).

## Repair system files

Main menu **2**. It needs administrator rights; without them every step shows *Skipped*.

| Key | Step | Changes the PC? |
| --- | --- | --- |
| K | `DISM /Online /Cleanup-Image /CheckHealth` | No |
| N | `DISM /Online /Cleanup-Image /ScanHealth` | No |
| S | `sfc /scannow` | Yes, replaces damaged system files |
| R | `DISM /Online /Cleanup-Image /RestoreHealth` | Yes, repairs the component store |
| C | `DISM /Online /Cleanup-Image /StartComponentCleanup` | Yes, removes old component versions (cannot be undone) |
| V | DISM version and repair source check | No (Technician: can run R from a checked ISO) |
| A | Run all: SFC, CheckHealth, ScanHealth, RestoreHealth, ComponentCleanup, SFC | Yes |

- **Read-only steps** start on one key.
- **Steps that change the PC** never start from one stray key. Standard mode says what each one changes and asks Y/N before it. Technician mode shows one plan for the whole run: Enter starts, Esc goes back.
- **Restore point.** Before the first step that changes the PC, it asks Y/N to create one. If Windows refuses (one per 24 hours, or System Protection is off), it says why, shows how many restore points and shadow copies Windows lists, and asks whether to go on. It never turns System Protection on.
- **Internet.** With the Online switch off (the default), RestoreHealth runs with `/LimitAccess` and uses only files already on the PC. With it on, the screen first says *Connecting to Windows Update (Microsoft) to download clean copies of damaged system files.* Standard mode then asks Y/N. Windows Update is the only approved destination.
- **DISM version and repair source (V).** Read-only and offline. Shows the Windows build, the DISM that runs (always `System32\dism.exe`), the repair-source policy, WSUS, and the last error in `dism.log`, then names the cause and the next step. RestoreHealth runs the same check first and, if it fails, says why (0x800F081F source missing, 0x800F0906 download failed, 0x800F0954 blocked by policy, 0x800F0922/0x800F082F restart pending). Most "DISM version mismatch" failures are really a repair source older than the PC; Windows Update always has the files for the PC's exact build. In Technician mode V can also read a mounted Windows ISO (`dism /Get-WimInfo`), pick the matching edition, warn when it is another build or older than the PC's updates, and, after Y/N, run RestoreHealth with `/Source:wim:<path>:<index> /LimitAccess`. Auto-Fixer never downloads or ships Windows files: they are Microsoft's and not ours to share.
- **Results.** SFC and DISM can exit with code 0 and still report damage, so the summary reads their words too. *ISSUES* means damage was found but not fixed, and the next step is named (usually R, then S again). SFC repairs offer a restart. If RestoreHealth fails during a run, it stops and asks Y/N before the remaining steps, because Cleanup and SFC often fail right after it; restarting and running R on its own works better.
- **Progress.** A framed panel under the activity list shows one overall bar, the current step and its real percentage, time elapsed and time left. It is redrawn in place and takes the mode colour; redirected output gets the activity lines only. Estimates learn from the last 5 clean runs on this PC.
- **Stall watchdog.** After 10 minutes with no output and no Windows servicing activity (CBS.log, dism.log, TiWorker, TrustedInstaller, DismHost), it asks *S = stop this step, W = keep waiting*. It never stops a step on its own.
- **Restart.** If a step needs one, the end screen offers it: Y/N in Standard mode, R in Technician mode. There is a live 60 second countdown: R restarts at once, and C, Esc or any other key cancels it.
- **Logs** stay on this PC, in `AF-<pc id>-<time>-repair.log` in this PC's folder, with every step's exit code. They are always redacted and never contain the PC or user name. `repair-history.csv` holds only the step, its seconds, its exit code and the date.

## Where logs are saved

Everything Auto-Fixer writes for a PC goes in one folder, `%ProgramData%\AutoFixer\Runs\PC-<pc id>\`, and every file name carries the PC id and the UTC date and time, so files from several PCs can sit side by side and no two share a name:

```
PC-K7Q2M9\
  AF-K7Q2M9-20261029-233547Z-scan.json     scan results (the viewer reads this)
  AF-K7Q2M9-20261029-233547Z-scan.html     the same scan, for a web browser
  AF-K7Q2M9-20261029-234210Z-repair.log    SFC and DISM
  AF-K7Q2M9-20261030-002040Z-domain.log    domain tools (also -network, -nettools, -localadmin, -azuread, -profile)
  AF-K7Q2M9-20261030-221500Z-cleanup.log   Disk Cleanup and Optimize drives
  repair-history.csv                       time estimates
```

- **Open it with one key.** Press **X** on any menu (main menu **7**, Open the logs folder in E(x)plorer) and File Explorer opens right in this PC's folder. If it isn't there yet, it is made empty first, the same folder the next scan or repair would make. The key bar at the bottom shows `[X] Logs`.
- **The PC id** is 6 random letters and digits, made on first run and kept in `%ProgramData%\AutoFixer\pc-id.txt`. It is not made from the PC name, serial number, user or any Windows id, so it gives nothing away, and every copy of Auto-Fixer on that PC uses the same one. Reinstalling Windows or deleting that file gives a new id. It is also printed at the top of each log and report.
- **Times are UTC** (the `Z`), so PCs in different time zones still sort correctly. If two files would get the same name in the same second, the second gets `-2` after the time; nothing is overwritten.
- **Older versions** saved each run in its own `Runs\<time>\` folder. Those folders are left exactly as they are, and Reports still lists their scans. Windows' own logs (CBS.log, dism.log, event logs, crash dumps) are only read, never moved or renamed.

## Network and domain

Main menu **3**. Everything here is built into Windows. The domain tools and saved passwords talk only to your own network (DNS and the domain controller); only the network tools' ping, trace route, DNS lookup and port test reach a target you pick, and they say where first. Names of servers, domains, PCs and accounts are redacted on screen (unless *Show sensitive data* is on) and always in the log, `AF-<pc id>-<time>-network.log`, `-nettools.log` or `-domain.log` in this PC's folder.

| Key | Item | Mode | Changes the PC? |
|---|---|---|---|
| W | Network tools | Both | Only flush DNS and release/renew, after Y; Technician adds adapter restart and the Winsock reset |
| C | Clear saved drive passwords | Both | Yes, after Y |
| D | Domain check | Technician | No |
| J | Join a domain | Technician | Yes, after Y, needs a restart |
| T | Repair domain trust | Technician | Yes, after Y |
| L | Leave the domain | Technician | Yes, after Y, needs a restart |
| U | User: local admin | Technician | Yes, after Y |
| A | Leave Azure AD | Technician | Yes, after Y |
| P | Move a user profile | Technician | Yes, after backups and Y |
| S | Sign-in source | Technician | No |

Standard mode shows the network tools and the saved drive passwords; every domain tool is Technician only, because a wrong domain change can lock users out of a PC.

- **Network tools** (W) is its own menu: **S** status (adapter, IP, gateway, DNS, DHCP), **P** ping (`ping -n 4`), **T** trace route (`tracert -d`, Esc stops it), **N** netstat (listening programs and open connections with their program names), **L** DNS lookup (`Resolve-DnsName`), **O** port test (one TCP port, 2 seconds), **F** flush DNS (`ipconfig /flushdns`, Y/N) and **R** release/renew IP (`ipconfig /release` and `/renew`, admin, Y/N, warns in a Remote Desktop session). Technician mode adds **A** restart an adapter (`Restart-NetAdapter`, Y/N) and **W** reset Winsock and TCP/IP (`netsh winsock reset`, `netsh int ip reset`, red warning, shows any static IP to write down first, needs a restart). Ping, trace route, lookup and port test go to your router, your DNS server or a name you type, and the screen says where before anything is sent. A typing mistake asks again, up to 3 tries. Each tool ends with "Run it again?".

- **Clear saved drive passwords** lists the network-server passwords in Credential Manager (`cmdkey /list`) for the Windows account running Auto-Fixer, with the drive letters that use them. Pick one by its number, or **A** for all. After a Y it removes them (`cmdkey /delete`) and drops connections that have no drive letter and no open files. Mapped drives and busy connections stay; Windows uses the old login there until you sign out or restart. On a domain PC it also offers `klist purge`. Web, Microsoft account, Office and Remote Desktop passwords are never listed. Windows cannot undo a removed password, and the warning says so.
- **Domain check** is read-only: domain or workgroup, whether the edition can join (Home cannot), DNS records for the domain controllers, `nltest /dsgetdc`, the Kerberos, LDAP and SMB ports, the clock (sign-in fails past 5 minutes), and on a domain PC the trust (`Test-ComputerSecureChannel`, needs administrator rights).
- **Sign-in source** (S) is read-only and answers "does this PC sign in through the on-prem domain or Microsoft 365?": the PC name, the join type from `dsregcmd /status` (on-prem AD, Entra ID, hybrid, a work account only, or not joined), the kind of account running Auto-Fixer (domain, cloud `AzureAD\...` or local), the domain controller that signed that account in (`LOGONSERVER`, its IP from DNS) and the one the PC uses now (`nltest /dsgetdc:`, name and IP). nltest and the DNS lookup run only on a domain PC and never reach the internet. When no domain controller answers it shows nltest's exit code and what it means. Log: `-signin.log`.
- **Join a domain** guides you instead of stopping: on a PC that is already on a domain it offers to move it to the new domain in one step (`Add-Computer` with an account on the old domain); on a PC joined to Azure AD (Entra ID, read-only check with `dsregcmd /status`) it offers Leave Azure AD first, then a restart. Ask IT first on a work PC. It runs the same checks next and stops on any FAIL. The one exception is a clock that is off on purpose (some lab servers): when the clock is the only FAIL, it says the join may still fail (Kerberos allows 5 minutes) and asks "Continue anyway?". It asks for the domain, an optional new PC name and an optional OU (press Enter for the default, or type a short name such as Laptops and it fills in the full path for a Y/N). A typing mistake asks again, up to 3 tries. Domains that DNS and the domain locator found are saved on that PC only (`C:\ProgramData\AutoFixer\known-domains.txt`, up to 6 names, nothing else), and Join and Domain check offer them as a numbered list next time, with T to type a new one and F to forget the list. The list shows real names even with redaction on; logs and reports stay redacted. Then it warns that you need a domain account that can add computers and a local administrator password you know, each with a Y/N. The password goes into Windows' own sign-in prompt and is never stored or logged. After the join it offers to open Settings > Accounts > Access work or school, where you add your work or school account (Outlook, Teams, OneDrive); that account can sit alongside a domain join, an Azure AD join cannot. It never restarts by itself: it asks "Restart now?".
- **User: local admin** lists every local account (admin or not admin); accounts are picked by number, and S shows their real names on that screen only. It creates a new local admin, makes an existing local account an admin, or resets a local account's password (typed twice in hidden prompts, never saved or logged), each after a Y/N. It can turn a disabled account back on.
- **Leave Azure AD** takes a PC off Azure AD (Entra ID) after a red warning; with no usable local admin it offers the local admin screen first, and "Are you sure?". On a hybrid PC (domain + Azure AD) it runs `dsregcmd /debug /leave`. On an Azure AD only PC it first needs a working local admin, then opens Settings > Access work or school, the way Microsoft documents it, and checks `dsregcmd /status` again afterwards. Ask IT before using it on a work PC.
- **Move a user profile** hands one profile (Desktop, Documents, browser and app settings) to another account on the same PC with Windows' own `Win32_UserProfile.ChangeOwner`, so nothing is copied or downloaded. Pick the profile by number (S shows real names on that screen), then the new owner: a local account, **N** to make a new local account first, or **T** to type one such as CONTOSO\user. A profile that is in use, or belongs to the account running Auto-Fixer, is refused, so sign in as a different admin first. It makes a restore point and a `reg export` of the profile's registry key (`AF-<pc id>-<time>-profile-backup.reg` in this PC's folder, next to its log), shows a red warning (Microsoft says some apps may need reinstalling or a new sign-in), and asks "Are you sure?". If the new owner already has a profile it asks before replacing it, and the replaced one stays on disk, never deleted. Leave the domain, Leave Azure AD and Join remind you to use it after the restart. To undo, move it back.
- **Repair domain trust** fixes "The trust relationship between this workstation and the primary domain failed" with `Test-ComputerSecureChannel -Repair`, then tests again. No restart needed.
- **Leave the domain** moves the PC to WORKGROUP with `Remove-Computer`, after the local administrator warning.
- Join, trust repair and leave need administrator rights and Windows PowerShell 5.1 (`AutoFix.bat` starts it); PowerShell 7 does not have these cmdlets and says so.

## Office and Outlook

Main menu **5**, classic Outlook only (New Outlook has no OST or PST files). Inventory and mail dates only read; Back up PSTs only copies. Purview PST Import and Remove or install Office are Technician only. Names, email addresses and paths are redacted on screen (unless *Show sensitive data* is on) and always in the log, `AF-<pc id>-<time>-outlook.log` in this PC's folder. Built from TEAM 9to5's Outlook tools (WORK-0033).

- **(I)nventory of OST and PST files.** Every `.ost` and `.pst` for the Windows account running Auto-Fixer: size, last change, whether it is open now, and which Outlook profile uses it. *ACTIVE* = a profile uses it and it changed in the last 14 days; *ATTACHED, idle* = a profile uses it but it has not changed for longer; *NOT attached* = no profile uses it (often an old copy). Over 45 GB is flagged: Outlook's default limit is 50 GB. Changes nothing.
- **Mail (d)ates in each PST.** The mail count and the oldest and newest mail in each PST in Outlook's folder and in Documents. Close Outlook first: an administrator window cannot talk to an Outlook you started. After a Y it copies each PST to a temp folder, opens the copies in classic Outlook in the background, reads them, closes Outlook and deletes the copies. Your own PST files are never opened. Not enough free space (the copies may use at most 80% of it) stops it before anything is copied.
- **Bac(k) up PSTs.** Both modes. Lists the Windows users in `C:\Users` with PST files (Outlook's folder, Documents, OneDrive Documents), you pick one, then type a backup folder or press Enter for `C:\PSTBackup-<date>`. Shows every file, the size and the free space, and asks Y/N. Each copy is checked against its original with SHA-256 and the hashes are saved in `hashes-sha256.txt` beside the copies. Two PSTs with the same name are kept as `name.pst` and `name-2.pst`. Close Outlook first. Undo: delete the backup folder.
- **(P)urview PST Import (Microsoft 365).** Technician only. Puts the backed-up PST copies into a user's Online Archive through Microsoft Purview, with nothing for the user to do. Its own menu: **(G)uide** (the steps and what you need) and **(M)apping file** (skips duplicate PSTs by SHA-256 and writes `C:\PSTImport\pst-mapping.csv`) use stock Windows. **Pre-(c)heck the mailbox**, **Add the import (r)ole**, **(U)pload PST copies** and **(A)fter the import** are online add-ons: they need the Exchange Online module or Microsoft AzCopy, and run only with Settings > Online add-ons on. The upload link (SAS URL) is read hidden and is never shown, logged or saved. Microsoft turns retention hold on during an import and may raise the max receive size; the pre-check saves both and *After the import* puts them back and removes the temporary role group. **U(n)do** removes the role group, deletes `C:\PSTImport` (AzCopy included) or explains how to remove imported mail. Logs: `AF-<pc id>-<time>-purview.log`.
- **Remove or install (O)ffice.** Technician only, classic Office (Microsoft 365 Apps, Visio, Project); Teams is always kept. Built from TEAM 9to5's Office remove and install kit (WORK-0018), which 9to5 tested. Its own menu:
  - **(T)est run** backs up the Office registry keys and each signed-in user's Office settings to `C:\ProgramData\AutoFixer\Office\backup-<time>`, then lists what removal would do. Changes nothing else.
  - **(R)emove Office** asks Y/N twice, makes the same backup (no backup = it stops), closes the Office apps and runs Office's own uninstaller silently (only if Microsoft signed it). It then removes Office add-in hooks (not Teams) and each signed-in user's Office sign-in key, and renames (never deletes) the licence and cache folders to `<name>.AutoFixer-old-<time>`. Teams is checked before and after. Online add-ons: if Office is still listed, the Office Deployment Tool's *Remove All*; and Microsoft Get Help's Office scrub for MSI Office and leftovers. With the switch off they are skipped with a note. Restart before installing.
  - **Pick the installer (s)ource** lists mounted Office discs and the ISOs in each user's Downloads, Documents and Desktop (OneDrive too), the Public folders, `C:\temp`, `C:\Install` and `C:\Software`, or takes a typed path, and mounts an ISO. **(U)nmount** unmounts it again.
  - **(D)ownload an installer** is an online add-on: an https link you type, the server shown first; a setup program must be signed by Microsoft.
  - **(I)nstall Office** runs `setup.exe` from the picked source after Y/N, only if Microsoft signed it. Entering a product key and activating are online add-ons.
  - **(L)icence and activation** shows each installed key's last 5 characters and its licence status (Office's own `OSPP.VBS /dstatus`). Activating again, a new key and removing an old key are online add-ons. A product key is read hidden and is never shown, logged or saved.
  - Logs: `AF-<pc id>-<time>-office.log`.

## Clean up

Main menu **4**, both modes. Each tool shows what it will do and asks Y/N before anything is removed or changed. Both need administrator rights (`AutoFix.bat` asks once). The log is `AF-<pc id>-<time>-cleanup.log` in this PC's folder.

**Disk Cleanup** lists every Disk Cleanup item on this PC with its size where Auto-Fixer can measure it, under *Your files* and *System files*. Use the arrow keys and **Space** (or the item's number) to tick, **A** for every item without a warning, **N** for none, **Enter** to go on.

- Ticked at the start: only items that lose nothing (temporary files older than 7 days, thumbnails, Delivery Optimization files and similar).
- **!** marks an item with a note to read first, such as *Windows Update Cleanup* (installed updates can no longer be uninstalled). **!!** items ask again by name before they run: *Recycle Bin*, *Downloads folder*, *Previous Windows installation(s)* (no going back to the old Windows), *Windows ESD installation files* and *File History versions*. Saying No leaves just that item out.
- Locked, never removed here: Windows error reports, crash dumps and setup and upgrade logs, because the scan reads them; and old driver packages, because Disk Cleanup keeps no copy.
- After a Y it runs `cleanmgr /sagerun:<slot>` with only your ticks. Auto-Fixer uses its own slot (42, or the next free one), so choices you saved yourself with `cleanmgr /sageset` stay as they are, and the slot is emptied again afterwards, even if the run stops. The result shows free space on the Windows drive before and after.

**Optimize drives** lists each fixed drive as SSD, hard drive or unknown type.

- **SSD:** *TRIM now* (`defrag X: /L`). Nothing is moved or deleted. **An SSD is never offered a defrag.**
- **Hard drive:** *Defrag* (`defrag X: /D`), with a time estimate and a warning when a laptop is on battery.
- **Unknown type** (common in virtual machines, RAID and USB boxes): TRIM only.
- Technician mode also offers to turn TRIM back on if it was turned off (`fsutil behavior set DisableDeleteNotify 0`) and to turn Windows' weekly Optimize Drives task back on if it was disabled.

## What it reads

| Source | Collector |
| --- | --- |
| System and Application event logs | `Collectors/EventLogs.ps1` |
| Setup and Windows Update event logs | `Collectors/EventLogs.ps1` |
| Reliability Monitor stability index | `Collectors/SystemState.ps1` |
| Crash dumps (`Minidump`, `MEMORY.DMP`) | `Collectors/SystemState.ps1` |
| Devices with a problem code | `Collectors/SystemState.ps1` |
| Live kernel reports (hangs Windows recovered from) | `Collectors/SystemState.ps1` |
| Applications and Services logs: WLAN-AutoConfig, Kernel-PnP, Diagnostics-Performance, Windows Defender | `Collectors/EventLogs.ps1` |
| Windows Error Reporting `Report.wer` files | `Collectors/TextLogs.ps1` |
| `CBS.log` and `dism.log` | `Collectors/TextLogs.ps1` |
| `setupapi.dev.log` | `Collectors/TextLogs.ps1` |

## Adding an issue signature

Drop a JSON file in `AutoFixer/Signatures/`. Example:

```json
{
  "id": "SIG-DISK-001",
  "title": "Disk is reporting read or write errors",
  "severity": "High",
  "match": {
    "any": [{ "source": "System", "provider": "disk", "eventId": [7, 51, 153] }],
    "minCount": 3,
    "withinDays": 14
  },
  "explain": "Windows logged {count} disk errors since {firstSeen}.",
  "fixes": ["FIX-CHKDSK-SCAN"]
}
```

Conditions can test `source`, `provider`, `eventId`, `level`, `messageRegex`, `messageNotRegex` and `field` (`{ "name": ..., "regex": ... }`). Use `any` (one condition is enough) or `all` (every condition must be seen). `explain` can use `{count}`, `{firstSeen}`, `{lastSeen}` and `{provider}`.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester ./Tests
```

CI runs PSScriptAnalyzer, Pester and a real read-only scan on `windows-latest`, under both Windows PowerShell 5.1 and PowerShell 7.

## About and credits

Main menu **9** shows who wrote Auto-Fixer, its license (MIT, Copyright (c) 2026 raven575) and every part of Windows it uses, with the maker's copyright and how the tool uses it. The same list is in [docs/CREDITS.md](docs/CREDITS.md). A test fails if the code starts running a Windows program that is not credited there.
