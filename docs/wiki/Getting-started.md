# Getting started

1. Download the repo as a ZIP from GitHub (green **Code** button > **Download ZIP**) and unzip it anywhere, such as your Desktop.
2. Double-click **AutoFix.bat**. Say **Yes** to the Windows administrator prompt. (Saying No still works; admin-only parts show *Skipped*.)
3. First launch asks for a mode. Press **Enter** for **Standard** (recommended).
4. Press **1** to run the read-only scan. It changes nothing.
5. When it finishes, press **V** to read the results on screen.
6. Pick a fix only if a finding suggests one. Anything that changes the PC explains itself and asks Y/N first, and offers a restore point before repairs.

Prefer a window? Double-click **AutoFix-GUI.bat** instead. It follows your Windows light or dark mode, accent colour and high contrast theme, and runs the read-only scan, the last report, the logs folder, Settings and About. Repairs and other changes still run from AutoFix.bat for now.

Keys that work everywhere (AutoFix.bat): arrow keys + Enter, the item's number or the letter in brackets, **Esc** = back, **X** = open this PC's logs folder, **Q** = quit.

Needs: Windows 10 or 11 and the Windows PowerShell 5.1 built into it. Nothing to install.
