# Troubleshooting and FAQ

**Windows says "Windows protected your PC".** The files came from the internet. Click **More info > Run anyway**, or right-click the ZIP > Properties > tick **Unblock** before unzipping. (AutoFix.bat already bypasses the PowerShell execution policy for its own run.) <!-- not yet tested on a VM -->

**Everything says *Skipped*.** You said No to the administrator prompt. Close and run AutoFix.bat again, and say Yes.

**DISM RestoreHealth fails with 0x800F081F.** The repair source is missing. In Repair, press **V**: it names the cause and the next step. Turning on *Go online when a step needs it* lets DISM use Windows Update.

**It says a restart is pending (0x800F0922 / 0x800F082F).** Restart, then run the step again.

**No restore point was made.** Windows allows one per 24 hours, and System Protection may be off. Auto-Fixer says which, and never turns System Protection on for you.

**A step seems stuck.** After 10 minutes with no activity it asks *S = stop, W = keep waiting*. It never stops a step on its own.

**Join domain or Leave domain says it needs Windows PowerShell 5.1.** Start through AutoFix.bat; PowerShell 7 does not have those commands.

**Mail dates says to close Outlook.** An administrator window cannot talk to an Outlook you started. Close Outlook and try again.

**Can I use it on a customer's PC?** Yes, with the owner's OK. It is read-only until you approve a change, redacts personal data, and keeps its logs on that PC.

**Where do I report a problem?** Open an issue on the GitHub repo. Remove anything personal first; the logs are already redacted.
