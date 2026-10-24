# auto-fix_Win10-11

auto-fix_Win is a PowerShell app that reads a Windows PC's existing logs, finds crashes and failures, explains them in plain English, and runs safe, reversible fixes with the user's approval. It shows a live activity list, a progress bar and a time estimate the whole way through.

## Status

**M1: scan and report.** Read-only. It reads nine log sources, matches them against issue signatures and writes a JSON and HTML report.

**M2: menu and user modes.** A console menu, a first-launch choice between Standard and Technician mode, and `settings.json`. Fixes arrive in M3.

## Run it

Easiest: double-click **`AutoFix.bat`**. It asks for administrator rights once and opens the menu with the Windows PowerShell 5.1 built into Windows 10 and 11. If you say No to the Windows prompt, it still runs and the scan skips the admin-only sources. Nothing to install.

The menu: **1** Scan this PC, **2** Open last report, **3** Settings, **Q** Quit. Use the arrow keys and Enter, or press the key.

- **First launch** asks for the mode. **Standard** (press Enter) is recommended: it explains each step and asks before any change. **Technician** is for experienced users and runs repairs such as SFC and DISM with one key (from M3); it shows a warning and needs **Y**. Steps that delete data, are permanent or go online warn in both modes.
- **Settings** changes the mode and two switches, both off by default: show sensitive data on screen (no prompt), and save reports without redaction (warns, and every scan asks Y/N again before saving real values).
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
