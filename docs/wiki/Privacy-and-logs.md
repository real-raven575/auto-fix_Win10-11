# Privacy and logs

- 🙈 **Redacted by default**, on screen and in every file: user, PC and domain names, serial numbers and service tags, profile folder names, email, IP and MAC addresses, account SIDs, product keys. Each becomes a stable placeholder such as `<IP-1>`; the real value is never stored.
- 🏠 **Logs stay on this PC** in `%ProgramData%\AutoFixer\Runs\PC-<id>\`. Press **X** on any menu to open it. Nothing is sent anywhere unless you share it yourself.
- 🎲 **The PC id** is 6 random letters and digits, not made from any name, serial or Windows id.
- 🚫 **No telemetry, tracking or phone home.** The tool only goes online when a step needs it, only to approved places, and says where and why first.
- 📖 Windows' own logs (event logs, CBS.log, dism.log, crash dumps) are only read, never moved, changed or deleted.

Full details: README, [Where logs are saved](https://github.com/real-raven575/auto-fix_Win10-11#where-logs-are-saved).
