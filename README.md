# auto-fix_Win10-11

auto-fix_Win is a PowerShell app that reads a Windows PC's existing logs, finds crashes and failures, explains them in plain English, and runs safe, reversible fixes with the user's approval. It shows a live activity list, a progress bar and a time estimate the whole way through.

## Status

**M1: scan and report.** Read-only. It reads nine log sources, matches them against issue signatures and writes a JSON and HTML report.

**M2: menu and user modes.** A console menu, a first-launch choice between Standard and Technician mode, and `settings.json`.

**Release 1.2: SFC and DISM repairs.** Main menu item 4 brings in raven575's SFC + DISM Repair Tool v1.1 (kept unchanged in `reference/`), with the gaps from its review fixed. See [Repair system files](#repair-system-files).

## Run it

Easiest: double-click **`AutoFix.bat`**. It asks for administrator rights once and opens the menu with the Windows PowerShell 5.1 built into Windows 10 and 11. If you say No to the Windows prompt, it still runs and the scan skips the admin-only sources. Nothing to install.

The menu: **1** (S)can this PC, **2** (O)pen last report, **3** Se(t)tings, **4** (R)epair system files (SFC and DISM), **5** (Q)uit. Every menu works the same way: use the arrow keys and Enter, press the item's number, or press the letter shown in brackets. **(Q)uit** is in every menu; below the main menu it asks "Are you sure?" first. **Esc** goes back in every menu (the same as **B**), quits from the main menu, and means No at any Y/N question.

- **First launch** asks for the mode. **Standard** (press Enter) is recommended: it explains each step and asks before any change. **Technician** is for experienced users and runs repairs such as SFC and DISM from one plan screen; it shows a warning and needs **Y**. Steps that delete data, are permanent or go online warn in both modes.
- **Settings** changes the mode and three switches, all off by default: show sensitive data on screen (no prompt), save reports without redaction (warns, and every scan asks Y/N again before saving real values), and go online when a step needs it (warns and lists the only places it may contact).
- Choices are saved in `settings.json` next to `Start-AutoFixer.ps1`. It holds only the mode and the switches, never names, serials or keys. A damaged file is renamed to `settings.json.bad` and you are asked for the mode again.

Or from an elevated PowerShell window (Windows PowerShell 5.1 or PowerShell 7) on Windows 10 or 11:

```powershell
.\Start-AutoFixer.ps1                          # the menu
.\Start-AutoFixer.ps1 -NoMenu                  # one scan of the last 14 days, no menu
.\Start-AutoFixer.ps1 -NoMenu -Days 30 -Open
.\Start-AutoFixer.ps1 -NoMenu -ShowSensitive   # real values on screen only, no prompt
.\Start-AutoFixer.ps1 -NoMenu -SaveSensitive   # real values in saved reports, after a one-key Y/N "are you sure?" warning
```

`-NoMenu` ignores `settings.json` and uses only the options given. With redirected input (scripts, CI) it scans once even without `-NoMenu`.

**Sensitive data is redacted everywhere by default**, on screen and in saved files: user, PC and domain names, serial numbers and service tags (BIOS, motherboard and disks), profile folder names in paths, email, IP and MAC addresses, account SIDs and product keys. Each value becomes a stable placeholder such as `<IP-1>`, so the same address shows the same placeholder across a report, but the real value is never stored.

Without admin rights the scan still runs, but skips crash dumps, CBS/DISM and the device install log. Reports are saved to `%ProgramData%\AutoFixer\Runs\<run id>\`.

## Repair system files

Main menu **4**. It needs administrator rights; without them every step shows *Skipped*.

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
- **Progress.** Overall and per-step bars show real percentages, with time elapsed and time left. Estimates learn from the last 5 clean runs on this PC.
- **Stall watchdog.** After 10 minutes with no output and no Windows servicing activity (CBS.log, dism.log, TiWorker, TrustedInstaller, DismHost), it asks *S = stop this step, W = keep waiting*. It never stops a step on its own.
- **Restart.** If a step needs one, the end screen offers it: Y/N in Standard mode, R in Technician mode. There is a 60 second countdown, and any key cancels it.
- **Logs** stay on this PC, in `%ProgramData%\AutoFixer\Runs\<time>\repair.log`, with every step's exit code. They are always redacted and never contain the PC or user name. `repair-history.csv` holds only the step, its seconds, its exit code and the date.

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
