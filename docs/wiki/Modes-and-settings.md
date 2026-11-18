# Modes and settings

| | Standard (default) | Technician (opt-in) |
|---|---|---|
| Who | Anyone | Experienced users and IT |
| Changes | Explains each step, asks Y/N before each one | One plan screen for the whole run: Enter starts, Esc goes back |
| Extra tools | Network tools, saved drive passwords, Clean up, Office and Outlook | Adds the domain tools, sign-in source check, local admin, leave Azure AD, profile move, Winsock reset, ISO repair source |
| Always | Anything that deletes data, is permanent or goes online warns first, in both modes | |

Switching to Technician shows a warning and needs **Y**.

**Settings** (main menu, Se(t)tings) stores only these in `settings.json` next to the tool:
- Mode and screen style (**Branded** default, or **Plain**; `-Plain` for one run).
- Show sensitive data on screen: off.
- Save reports without redaction: off; warns, and asks again at every save.
- Go online when a step needs it: off; lists the only places it may contact (today: Windows Update, for DISM RestoreHealth).

A damaged `settings.json` is renamed to `settings.json.bad` and the tool asks for the mode again.
