# SFC + DISM Repair Tool v1.1 (reference copy)

This is raven575's SFC + DISM Repair Tool v1.1 (dated 2026-10-23), kept exactly as delivered. auto-fix_Win starts from it. The first auto-fix_Win release with changes will be 1.2.

**Do not edit these files.** Improvements go into auto-fix_Win's own SFC and DISM fixes. `Tests/Reference.Tests.ps1` fails if either file changes, and `.gitattributes` stops Git from converting their Windows line endings.

| File | Size | SHA-256 |
|---|---|---|
| `SfcDismTool.ps1` | 29,385 bytes | `ef51fba8fbe5d1af8e20f4b9933b4781b6bd60ed6316f5b70b5a51f1a7f541a2` |
| `Run-SfcDismTool.bat` | 332 bytes | `7ca53bdcfeac1a8723fecbefc467e34ce0b6e0dc1aebef1ce87e2ef69ce6b57e` |

## What it does

The script runs `sfc /scannow` and the DISM `/Online /Cleanup-Image` commands (CheckHealth, ScanHealth, RestoreHealth and StartComponentCleanup):

- **One-key menu.** A single key runs one command, runs all six steps, or opens a sequence you choose.
- **Progress.** It shows overall and per-step progress, with time elapsed and time left.
- **Stall watchdog.** It stops a step only after 10 minutes with no output and no Windows servicing activity.
- **Logs.** It writes a plain text log per run and a `history.csv` that teaches it time estimates.
- **Toggles.** LOGS, PAUSE, RETURN and REBOOT. REBOOT is off by default.

Start it with `Run-SfcDismTool.bat`. The script asks for administrator rights itself.

## Known gaps, to be fixed in auto-fix_Win 1.2

These are measured against the project's locked rules. They are fixed in the new code, not here.

1. Logs record the computer name and user name. The log file name and `history.csv` also contain the computer name.
2. Logs are saved next to the script, so a run from a USB stick takes them off the PC.
3. DISM RestoreHealth reaches Windows Update without saying where or why first.
4. No restore point is offered before repairs.
5. The stall watchdog stops DISM without asking first.
6. `taskkill.exe` and `shutdown.exe` are called by bare name instead of full path.
7. One key starts a repair right away, with no "this changes your system" confirmation.
