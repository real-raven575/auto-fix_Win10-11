# auto-fix_Win10-11

Auto-Fixer is a PowerShell app that reads a Windows PC's existing logs, finds crashes and failures, explains them in plain English, and runs safe, reversible fixes with the user's approval. It shows a live activity list, a progress bar and a time estimate the whole way through.

## Status

**M1: scan and report.** Read-only. It reads nine log sources, matches them against issue signatures and writes a JSON and HTML report.

**M2: menu and user modes.** A console menu, a first-launch choice between Standard and Technician mode, and `settings.json`.

**Release 1.2: SFC and DISM repairs.** Main menu item 2 brings in raven575's SFC + DISM Repair Tool v1.1 (kept unchanged in `reference/`), with the gaps from its review fixed. See [Repair system files](#repair-system-files).

**Network and domain (next version).** Main menu item 3 clears saved network-drive passwords and checks, joins, repairs or leaves a domain. See [Network and domain](#network-and-domain).

## Run it

Easiest: double-click **`AutoFix.bat`**. It asks for administrator rights once and opens the menu with the Windows PowerShell 5.1 built into Windows 10 and 11. If you say No to the Windows prompt, it still runs and the scan skips the admin-only sources. Nothing to install.

The menu: **1** Run a (s)can, **2** (R)epair Windows files (SFC and DISM), **3** (N)etwork and domain, **4** Open the last re(p)ort, **5** Se(t)tings, **6** (A)bout and credits, **7** (Q)uit. Every menu works the same way: use the arrow keys and Enter, press the item's number, or press the letter shown in brackets. **(Q)uit** is in every menu; below the main menu it asks "Are you sure?" first. **Esc** goes back in every menu (the same as **B**), quits from the main menu, and means No at any Y/N question.

- **First launch** asks for the mode. **Standard** (press Enter) is recommended: it explains each step and asks before any change. **Technician** is for experienced users and runs repairs such as SFC and DISM from one plan screen; it shows a warning and needs **Y**. Steps that delete data, are permanent or go online warn in both modes.
- **Screen style.** Branded is the default: the Auto-Fixer banner, a start screen and Wrench art. **Plain** shows the same screens without the art; pick it under Settings or start with `-Plain` for one run. With `NO_COLOR` set, or a console without VT support, the screens are drawn Plain without the background pattern. A window smaller than 80x25, redirected output or `TERM=dumb` gets the simple text screens.
- **Settings** changes the mode, the screen style and three switches, all off by default: show sensitive data on screen (no prompt), save reports without redaction (warns, and every scan asks Y/N again before saving real values), and go online when a step needs it (warns and lists the only places it may contact).
- Choices are saved in `settings.json` next to `Start-AutoFixer.ps1`. It holds only the mode, the screen style and the switches, never names, serials or keys. A damaged file is renamed to `settings.json.bad` and you are asked for the mode again.

Or from an elevated PowerShell window (Windows PowerShell 5.1 or PowerShell 7) on Windows 10 or 11:

```powershell
.\Start-AutoFixer.ps1                          # the menu
.\Start-AutoFixer.ps1 -Plain                   # the menu in the Plain look, this run only
.\Start-AutoFixer.ps1 -NoMenu                  # one scan of the last 14 days, no menu
.\Start-AutoFixer.ps1 -NoMenu -Days 30 -Open
.\Start-AutoFixer.ps1 -NoMenu -ShowSensitive   # real values on screen only, no prompt
.\Start-AutoFixer.ps1 -NoMenu -SaveSensitive   # real values in saved reports, after a one-key Y/N "are you sure?" warning
```

`-NoMenu` ignores `settings.json` and uses only the options given. With redirected input (scripts, CI) it scans once even without `-NoMenu`.

**Sensitive data is redacted everywhere by default**, on screen and in saved files: user, PC and domain names, serial numbers and service tags (BIOS, motherboard and disks), profile folder names in paths, email, IP and MAC addresses, account SIDs and product keys. Each value becomes a stable placeholder such as `<IP-1>`, so the same address shows the same placeholder across a report, but the real value is never stored.

Without admin rights the scan still runs, but skips crash dumps, CBS/DISM and the device install log. Reports are saved to `%ProgramData%\AutoFixer\Runs\<run id>\`.

## Repair system files

Main menu **2**. It needs administrator rights; without them every step shows *Skipped*.

| Key | Step | Changes the PC? |
| --- | --- | --- |
| K | `DISM /Online /Cleanup-Image /CheckHealth` | No |
| N | `DISM /Online /Cleanup-Image /ScanHealth` | No |
| S | `sfc /scannow` | Yes, replaces damaged system files |
| R | `DISM /Online /Cleanup-Image /RestoreHealth` | Yes, repairs the component store |
| C | `DISM /Online /Cleanup-Image /StartComponentCleanup` | Yes, removes old component versions (cannot be undone) |
| A | Run all: SFC, CheckHealth, ScanHealth, RestoreHealth, ComponentCleanup, SFC | Yes |

- **Read-only steps** start on one key.
- **Steps that change the PC** never start from one stray key. Standard mode says what each one changes and asks Y/N before it. Technician mode shows one plan for the whole run: Enter starts, Esc goes back.
- **Restore point.** Before the first step that changes the PC, it asks Y/N to create one. If Windows refuses (one per 24 hours, or System Protection is off), it says why, shows how many restore points and shadow copies Windows lists, and asks whether to go on. It never turns System Protection on.
- **Internet.** With the Online switch off (the default), RestoreHealth runs with `/LimitAccess` and uses only files already on the PC. With it on, the screen first says *Connecting to Windows Update (Microsoft) to download clean copies of damaged system files.* Standard mode then asks Y/N. Windows Update is the only approved destination.
- **Results.** SFC and DISM can exit with code 0 and still report damage, so the summary reads their words too. *ISSUES* means damage was found but not fixed, and the next step is named (usually R, then S again). SFC repairs offer a restart.
- **Progress.** Overall and per-step bars show real percentages, with time elapsed and time left. Estimates learn from the last 5 clean runs on this PC.
- **Stall watchdog.** After 10 minutes with no output and no Windows servicing activity (CBS.log, dism.log, TiWorker, TrustedInstaller, DismHost), it asks *S = stop this step, W = keep waiting*. It never stops a step on its own.
- **Restart.** If a step needs one, the end screen offers it: Y/N in Standard mode, R in Technician mode. There is a live 60 second countdown: R restarts at once, and C, Esc or any other key cancels it.
- **Logs** stay on this PC, in `%ProgramData%\AutoFixer\Runs\<time>\repair.log`, with every step's exit code. They are always redacted and never contain the PC or user name. `repair-history.csv` holds only the step, its seconds, its exit code and the date.

## Network and domain

Main menu **3**. Everything here is built into Windows. The domain tools and saved passwords talk only to your own network (DNS and the domain controller); only the network tools' ping, trace route, DNS lookup and port test reach a target you pick, and they say where first. Names of servers, domains, PCs and accounts are redacted on screen (unless *Show sensitive data* is on) and always in the log, `network.log`, `nettools.log` or `domain.log` in a new run folder.

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

Standard mode shows the network tools and the saved drive passwords; every domain tool is Technician only, because a wrong domain change can lock users out of a PC.

- **Network tools** (W) is its own menu: **S** status (adapter, IP, gateway, DNS, DHCP), **P** ping (`ping -n 4`), **T** trace route (`tracert -d`, Esc stops it), **N** netstat (listening programs and open connections with their program names), **L** DNS lookup (`Resolve-DnsName`), **O** port test (one TCP port, 2 seconds), **F** flush DNS (`ipconfig /flushdns`, Y/N) and **R** release/renew IP (`ipconfig /release` and `/renew`, admin, Y/N, warns in a Remote Desktop session). Technician mode adds **A** restart an adapter (`Restart-NetAdapter`, Y/N) and **W** reset Winsock and TCP/IP (`netsh winsock reset`, `netsh int ip reset`, red warning, shows any static IP to write down first, needs a restart). Ping, trace route, lookup and port test go to your router, your DNS server or a name you type, and the screen says where before anything is sent. A typing mistake asks again, up to 3 tries. Each tool ends with "Run it again?".

- **Clear saved drive passwords** lists the network-server passwords in Credential Manager (`cmdkey /list`) for the Windows account running Auto-Fixer, with the drive letters that use them. Pick one by its number, or **A** for all. After a Y it removes them (`cmdkey /delete`) and drops connections that have no drive letter and no open files. Mapped drives and busy connections stay; Windows uses the old login there until you sign out or restart. On a domain PC it also offers `klist purge`. Web, Microsoft account, Office and Remote Desktop passwords are never listed. Windows cannot undo a removed password, and the warning says so.
- **Domain check** is read-only: domain or workgroup, whether the edition can join (Home cannot), DNS records for the domain controllers, `nltest /dsgetdc`, the Kerberos, LDAP and SMB ports, the clock (sign-in fails past 5 minutes), and on a domain PC the trust (`Test-ComputerSecureChannel`, needs administrator rights).
- **Join a domain** guides you instead of stopping: on a PC that is already on a domain it offers to move it to the new domain in one step (`Add-Computer` with an account on the old domain); on a PC joined to Azure AD (Entra ID, read-only check with `dsregcmd /status`) it offers Leave Azure AD first, then a restart. Ask IT first on a work PC. It runs the same checks next and stops on any FAIL. The one exception is a clock that is off on purpose (some lab servers): when the clock is the only FAIL, it says the join may still fail (Kerberos allows 5 minutes) and asks "Continue anyway?". It asks for the domain, an optional new PC name and an optional OU (press Enter for the default, or type a short name such as Laptops and it fills in the full path for a Y/N). A typing mistake asks again, up to 3 tries. Domains that DNS and the domain locator found are saved on that PC only (`C:\ProgramData\AutoFixer\known-domains.txt`, up to 6 names, nothing else), and Join and Domain check offer them as a numbered list next time, with T to type a new one and F to forget the list. The list shows real names even with redaction on; logs and reports stay redacted. Then it warns that you need a domain account that can add computers and a local administrator password you know, each with a Y/N. The password goes into Windows' own sign-in prompt and is never stored or logged. After the join it offers to open Settings > Accounts > Access work or school, where you add your work or school account (Outlook, Teams, OneDrive); that account can sit alongside a domain join, an Azure AD join cannot. It never restarts by itself: it asks "Restart now?".
- **User: local admin** lists every local account (admin or not admin); accounts are picked by number, and S shows their real names on that screen only. It creates a new local admin, makes an existing local account an admin, or resets a local account's password (typed twice in hidden prompts, never saved or logged), each after a Y/N. It can turn a disabled account back on.
- **Leave Azure AD** takes a PC off Azure AD (Entra ID) after a red warning; with no usable local admin it offers the local admin screen first, and "Are you sure?". On a hybrid PC (domain + Azure AD) it runs `dsregcmd /debug /leave`. On an Azure AD only PC it first needs a working local admin, then opens Settings > Access work or school, the way Microsoft documents it, and checks `dsregcmd /status` again afterwards. Ask IT before using it on a work PC.
- **Repair domain trust** fixes "The trust relationship between this workstation and the primary domain failed" with `Test-ComputerSecureChannel -Repair`, then tests again. No restart needed.
- **Leave the domain** moves the PC to WORKGROUP with `Remove-Computer`, after the local administrator warning.
- Join, trust repair and leave need administrator rights and Windows PowerShell 5.1 (`AutoFix.bat` starts it); PowerShell 7 does not have these cmdlets and says so.

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

Main menu **6** shows who wrote Auto-Fixer, its license (MIT, Copyright (c) 2026 raven575) and every part of Windows it uses, with the maker's copyright and how the tool uses it. The same list is in [docs/CREDITS.md](docs/CREDITS.md). A test fails if the code starts running a Windows program that is not credited there.
