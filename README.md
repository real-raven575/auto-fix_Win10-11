# auto-fix_Win10-11

Auto-Fixer is a PowerShell app that reads a Windows PC's existing logs, finds crashes and failures, explains them in plain English, and runs safe, reversible fixes with the user's approval. It shows a live activity list, a progress bar and a time estimate the whole way through.

## Status

**M1: scan and report.** Read-only. It reads nine log sources, matches them against ten issue signatures and writes a JSON and HTML report. Fixes arrive in M3; the menu-driven CLI with ASCII styling arrives in M2.

## Run it

From an elevated PowerShell window (Windows PowerShell 5.1 or PowerShell 7) on Windows 10 or 11:

```powershell
.\Start-AutoFixer.ps1            # last 14 days
.\Start-AutoFixer.ps1 -Days 30 -Open
.\Start-AutoFixer.ps1 -Redact    # masks user and machine names in the report
```

Without admin rights the scan still runs, but skips crash dumps, CBS/DISM and the device install log. Reports are saved to `%ProgramData%\AutoFixer\Runs\<run id>\`.

## What it reads

| Source | Collector |
| --- | --- |
| System and Application event logs | `Collectors/EventLogs.ps1` |
| Setup and Windows Update event logs | `Collectors/EventLogs.ps1` |
| Reliability Monitor stability index | `Collectors/SystemState.ps1` |
| Crash dumps (`Minidump`, `MEMORY.DMP`) | `Collectors/SystemState.ps1` |
| Devices with a problem code | `Collectors/SystemState.ps1` |
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
