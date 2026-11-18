# The Online Archive window (TEAM 9to5's script 22 v3.7, WORK-0038, rewritten for Auto-Fixer).
# Runs as the signed-in user with normal rights and classic Outlook open; Invoke-AfOnlineArchive
# starts it. Pages: Push, Undo, Import a PST, Status. Every change previews first and asks Yes.
# Nothing in the mailbox is deleted. Logs of every move go to %LOCALAPPDATA%\AutoFixer\OnlineArchive
# (the user's own folder, so Undo works later); the redacted result goes back to Auto-Fixer.
# Changes from 9to5's v3.7 (review 2026-11-18): the PST-open wait loop now lets the window draw
# and Stop work; a failed import move removes the temporary copy it made in the PST and says so;
# wording says plainly that Outlook writes temporary copies into the PST and that Undo of an import
# goes to the archive's Deleted Items; no team names; the "any mailbox" Exchange check is left out
# (it needs an install and a sign-in, so it comes later as an online add-on).

function Start-AfOnlineArchiveWindow {
    <#
    .SYNOPSIS
        Opens the window and returns the exit code (see $script:AfArchiveExit). With -ResultPath
        the redacted result lines and the code are also saved there as JSON for Auto-Fixer.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'WinForms event handlers read these variables later.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'WinForms event handlers get sender and event arguments.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string] $ResultPath,
        [string] $LogDir = (Join-Path $env:LOCALAPPDATA 'AutoFixer\OnlineArchive')
    )

    $S = @{ Lines = (New-Object System.Collections.ArrayList); Warn = $false; Stopped = $false; Code = 0 }
    $saveResult = {
        if (-not $ResultPath) { return }
        $lines = @($S.Lines.ToArray())
        if (-not $lines.Count) { $lines = @('No changes were made.') }
        try { @{ ExitCode = $S.Code; Lines = $lines } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Verbose ('Result not saved: {0}' -f $_.Exception.Message) }
    }

    if (-not (Get-Process -Name 'outlook' -ErrorAction SilentlyContinue)) {
        $S.Code = 3; [void]$S.Lines.Add('Classic Outlook is not open for this user.'); & $saveResult; return 3
    }
    try { $ns = (New-Object -ComObject Outlook.Application).GetNamespace('MAPI') }
    catch { $S.Code = 3; [void]$S.Lines.Add('Could not reach classic Outlook: ' + $_.Exception.Message); & $saveResult; return 3 }

    $red = New-AfRedactor
    $main = $ns.DefaultStore; $mroot = $main.GetRootFolder()
    Add-AfRedactionName -Redactor $red -Names @([string]$main.DisplayName)
    function Protect-AfArchiveText([string] $Text) { Protect-AfText -Redactor $red -Text $Text }

    # ---- Outlook helpers ----
    function Get-AfArchiveSub($Parent, [string] $Name) { foreach ($x in $Parent.Folders) { if ($x.Name -eq $Name) { return $x } }; $null }
    function Find-AfArchivePath($Root, [string] $Rel) { $f = $Root; foreach ($n in ($Rel -split '\\')) { if (-not $n) { continue }; $f = Get-AfArchiveSub $f $n; if (-not $f) { return $null } }; $f }
    function Get-AfArchiveReceived($It) { $t = $null; try { $t = $It.ReceivedTime } catch { $null = $_ }; if (-not $t -or $t.Year -ge 4500) { try { $t = $It.CreationTime } catch { $null = $_ } }; $t }
    function Test-AfArchiveHidden($F) { try { [bool]$F.PropertyAccessor.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x10F4000B') } catch { $false } }
    function Remove-AfArchiveRef($O) { if ($O) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($O) } catch { $null = $_ } } }
    function Get-AfArchiveStoreSize($St) { try { [int64]$St.PropertyAccessor.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x0E080014') } catch { [int64]-1 } }
    function Find-AfArchiveStoreByFile([string] $Path) { foreach ($st in $ns.Stores) { try { if ([string]$st.FilePath -eq $Path) { return $st } } catch { $null = $_ } }; $null }
    function Get-AfArchiveKeyOf($It) {
        $mid = ''; try { $mid = [string]$It.PropertyAccessor.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x1035001F') } catch { $null = $_ }
        $sub = ''; try { $sub = [string]$It.Subject } catch { $null = $_ }
        Get-AfArchiveMessageKey -MessageId $mid -Received (Get-AfArchiveReceived $It) -Subject $sub
    }

    # The Online Archive store: the one named Online Archive / In-Place Archive, else the user picks.
    $others = @(foreach ($st in $ns.Stores) { if ($st.StoreID -ne $main.StoreID -and -not $st.IsDataFileStore) { $st } })
    $arc = @($others | Where-Object { $_.DisplayName -match '(?i)^(Online Archive|In-Place Archive)' }) | Select-Object -First 1
    Add-AfRedactionName -Redactor $red -Names @($others | ForEach-Object { ([string]$_.DisplayName) -replace '^(?i)(Online Archive|In-Place Archive)\s*-\s*', '' })
    $aroot = $null; if ($arc) { $aroot = $arc.GetRootFolder() }
    $skip = @{}; foreach ($n in 4, 20) { try { $skip[$ns.GetDefaultFolder($n).EntryID] = 1 } catch { $null = $_ } }   # Outbox, Sync Issues
    $S.Folders = @{}; $S.Busy = $false; $S.Cancel = $false; $S.Attached = (New-Object System.Collections.ArrayList)
    $S.WorkDir = Join-Path $LogDir 'pst-backup'

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    function ConvertFrom-AfHex([string] $H) { [Drawing.ColorTranslator]::FromHtml($H) }
    # Auto-Fixer "Workbench" colours (FIXW-0026): walnut header and rail, warm paper, white cards, blue accent.
    $Th = @{ Rail = (ConvertFrom-AfHex '#2f2622'); RailSel = (ConvertFrom-AfHex '#4a3b34'); RailText = (ConvertFrom-AfHex '#e9dfd3'); Bg = (ConvertFrom-AfHex '#faf6ef'); Card = (ConvertFrom-AfHex '#ffffff')
        Text = (ConvertFrom-AfHex '#2a211c'); Dim = (ConvertFrom-AfHex '#6e6258'); Accent = (ConvertFrom-AfHex '#0b74a8'); StatusBg = (ConvertFrom-AfHex '#f1e9dc')
        Group = (ConvertFrom-AfHex '#2f4ab8'); GroupBg = (ConvertFrom-AfHex '#e3e8fb'); Ok = (ConvertFrom-AfHex '#0f6b36'); OkBg = (ConvertFrom-AfHex '#dff3e6'); Warn = (ConvertFrom-AfHex '#7a4b00'); WarnBg = (ConvertFrom-AfHex '#fff1c9'); Chg = (ConvertFrom-AfHex '#9c2414'); ChgBg = (ConvertFrom-AfHex '#fde8e5') }
    $FontUi = New-Object Drawing.Font('Segoe UI', 10.5); $FontBig = New-Object Drawing.Font('Segoe UI Semibold', 15); $FontStep = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
    $FontTag = New-Object Drawing.Font('Segoe UI Semibold', 8.5); $FontMono = New-Object Drawing.Font('Consolas', 9.5)

    function New-AfCtl([string] $Type, [int] $X, [int] $Y, [int] $W, [int] $H, $Text) { $o = New-Object ('System.Windows.Forms.' + $Type); $o.Location = New-Object Drawing.Point($X, $Y); $o.Size = New-Object Drawing.Size($W, $H); if ($null -ne $Text) { $o.Text = $Text }; $o.Font = $FontUi; $o.ForeColor = $Th.Text; $o }
    function New-AfBtn([int] $X, [int] $Y, [int] $W, [string] $Text, [bool] $Primary) { $o = New-AfCtl 'Button' $X $Y $W 34 $Text; $o.FlatStyle = 'Flat'; $o.FlatAppearance.BorderColor = $Th.Accent; $o.UseMnemonic = $true
        if ($Primary) { $o.BackColor = $Th.Accent; $o.ForeColor = $Th.Card; $o.Font = $FontStep } else { $o.BackColor = $Th.Card; $o.ForeColor = $Th.Text }; $o.Cursor = 'Hand'; $o }
    function New-AfTag([int] $X, [int] $Y, [string] $Text, $Ink, $Back) { $o = New-AfCtl 'Label' $X $Y 0 0 $Text; $o.AutoSize = $true; $o.Font = $FontTag; $o.ForeColor = $Ink; $o.BackColor = $Back; $o.Padding = New-Object Windows.Forms.Padding(5, 2, 5, 2); $o }
    function New-AfStepLabel([int] $X, [int] $Y, [int] $W, [string] $Text) { $o = New-AfCtl 'Label' $X $Y $W 22 $Text; $o.Font = $FontStep; $o.ForeColor = $Th.Accent; $o }
    function New-AfList([int] $X, [int] $Y, [int] $W, [int] $H, $Cols) { $o = New-AfCtl 'ListView' $X $Y $W $H $null; $o.View = 'Details'; $o.FullRowSelect = $true; $o.HideSelection = $false
        $o.BackColor = $Th.Card; $o.BorderStyle = 'FixedSingle'; foreach ($c2 in $Cols) { [void]$o.Columns.Add($c2[0], $c2[1]) }; $o }
    function Set-AfBusy([bool] $On, [string] $Msg) { $S.Busy = $On; foreach ($x in $Lock) { $x.Enabled = -not $On }
        $BtnPush.Enabled = (-not $On) -and [bool]$S.Plan -and [bool]$S.Plan.Tot; $BtnUndo.Enabled = (-not $On) -and [bool]$S.UndoPlan -and [bool]$S.UndoTot
        $BtnPstGo.Enabled = (-not $On) -and [bool]$S.PstPlan -and [bool]$S.PstTot; $DatePst.Enabled = (-not $On) -and $ChkPstDate.Checked
        if (-not $arc) { foreach ($x in $NeedArc) { $x.Enabled = $false } }; if ($Msg) { $Status.Text = $Msg }; $BtnStop.Enabled = $On
        if ($On) { $S.Cancel = $false; $Prog.Style = 'Marquee'; $Prog.MarqueeAnimationSpeed = 30 } else { $Prog.Style = 'Continuous' }; $Form.Cursor = $(if ($On) { 'WaitCursor' } else { 'Default' }); [Windows.Forms.Application]::DoEvents() }
    function Set-AfProgress([int] $I, [int] $N, [string] $Msg) { if ($N -le 0) { return }   # bar + 'N of M'; DoEvents every call so Stop can be clicked
        if ($I -eq 1 -or $I -eq $N -or $I % 5 -eq 0) { if ($Prog.Style -ne 'Continuous') { $Prog.Style = 'Continuous' }; $Prog.Maximum = $N; $Prog.Value = [Math]::Min($I, $N); $Status.Text = ('{0}  ({1} of {2})' -f $Msg, $I, $N) }
        [Windows.Forms.Application]::DoEvents() }
    function Show-AfResult([string[]] $Lines, [bool] $Good, [bool] $Stopped) {
        $safe = @($Lines | ForEach-Object { Protect-AfArchiveText $_ })
        $Res.Text = $safe -join "`r`n"; $Res.ForeColor = $(if ($Good) { $Th.Ok } else { $Th.Warn }); $Res.BackColor = $(if ($Good) { $Th.OkBg } else { $Th.WarnBg })
        foreach ($l in $safe) { [void]$S.Lines.Add($l) }
        if ($Stopped) { $S.Stopped = $true } elseif (-not $Good) { $S.Warn = $true }
        try { $null = New-Item -ItemType Directory -Path $LogDir -Force; Add-Content -LiteralPath (Join-Path $LogDir ('result-' + (Get-Date -Format 'yyyyMMdd') + '.txt')) -Value (@('---- ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) + $safe) -Encoding UTF8 } catch { $null = $_ } }
    function Format-AfMb([double] $B) { '{0:N1} MB' -f ($B / 1MB) }
    function Format-AfGb([double] $B) { '{0:N2} GB' -f ($B / 1GB) }
    function Format-AfSizeText([double] $B) { if ($B -ge 1GB) { Format-AfGb $B } else { Format-AfMb $B } }

    $Form = New-Object Windows.Forms.Form
    $Form.Text = 'Auto-Fixer  -  Online Archive'; $Form.ClientSize = New-Object Drawing.Size(1044, 720); $Form.MinimumSize = $Form.Size
    $Form.StartPosition = 'CenterScreen'; $Form.BackColor = $Th.Bg; $Form.Font = $FontUi; $Form.TopMost = $true
    $Form.Add_Shown({ $Form.TopMost = $false; $Form.Activate() })
    $Form.Add_FormClosing({ param($ctl, $ev) if ($S.Busy) { $ev.Cancel = $true; [void][Windows.Forms.MessageBox]::Show('Please wait: mail is moving. Click Stop to end after the current item.', 'Still working') } })

    $Head = New-Object Windows.Forms.Panel; $Head.Size = New-Object Drawing.Size(1044, 70); $Head.Dock = 'Top'; $Head.BackColor = $Th.Rail
    $Grp = New-AfTag 20 10 'OFFICE AND OUTLOOK' $Th.Group $Th.GroupBg
    $Title = New-AfCtl 'Label' 18 30 700 34 'Online Archive'; $Title.Font = $FontBig; $Title.ForeColor = $Th.RailText
    $Head.Controls.AddRange(@($Grp, $Title))
    $Rail = New-Object Windows.Forms.Panel; $Rail.Size = New-Object Drawing.Size(200, 622); $Rail.Dock = 'Left'; $Rail.BackColor = $Th.Rail
    function New-AfRailBtn([int] $Y, [string] $Text) { $o = New-AfCtl 'Button' 0 $Y 200 46 $Text; $o.FlatStyle = 'Flat'; $o.FlatAppearance.BorderSize = 0; $o.TextAlign = 'MiddleLeft'; $o.Padding = New-Object Windows.Forms.Padding(18, 0, 0, 0)
        $o.BackColor = $Th.Rail; $o.ForeColor = $Th.RailText; $o.Font = $FontStep; $o.Cursor = 'Hand'; $o.UseMnemonic = $true; $o }
    $RailPush = New-AfRailBtn 16 '&Push to archive'; $RailUndo = New-AfRailBtn 64 '&Undo a push or import'; $RailPst = New-AfRailBtn 112 '&Import a PST'; $RailStat = New-AfRailBtn 160 'Archive &status'
    $RailNote = New-AfCtl 'Label' 18 226 170 140 "Nothing in the mailbox is deleted.`r`nEvery move is logged and can be undone.`r`nPreview first; nothing moves until you click Yes."; $RailNote.ForeColor = $Th.RailText; $RailNote.Font = $FontTag
    $Rail.Controls.AddRange(@($RailPush, $RailUndo, $RailPst, $RailStat, $RailNote))
    $Bar2 = New-Object Windows.Forms.Panel; $Bar2.Size = New-Object Drawing.Size(1044, 28); $Bar2.Dock = 'Bottom'; $Bar2.BackColor = $Th.StatusBg
    $Status = New-AfCtl 'Label' 12 4 600 20 'Ready.'; $Status.ForeColor = $Th.Dim; $Status.Anchor = 'Left,Right,Top'
    $Who = New-AfCtl 'Label' 600 4 430 20 ('Mailbox: ' + (Protect-AfArchiveText ([string]$main.DisplayName)) + '   |   Names hidden'); $Who.ForeColor = $Th.Dim; $Who.TextAlign = 'MiddleRight'; $Who.Anchor = 'Top,Right'
    $Bar2.Controls.AddRange(@($Who, $Status))
    $Body = New-Object Windows.Forms.Panel; $Body.Size = New-Object Drawing.Size(844, 622); $Body.Dock = 'Fill'; $Body.BackColor = $Th.Bg
    $TabPush = New-Object Windows.Forms.Panel; $TabPush.Location = New-Object Drawing.Point(16, 12); $TabPush.Size = New-Object Drawing.Size(820, 420); $TabPush.Anchor = 'Top,Left,Right,Bottom'; $TabPush.BackColor = $Th.Bg
    function New-AfPage { $o = New-Object Windows.Forms.Panel; $o.Location = $TabPush.Location; $o.Size = $TabPush.Size; $o.Anchor = $TabPush.Anchor; $o.BackColor = $Th.Bg; $o.Visible = $false; $o }
    $TabUndo = New-AfPage; $TabPst = New-AfPage; $TabStat = New-AfPage
    $Prog = New-AfCtl 'ProgressBar' 16 440 820 16 $null; $Prog.Anchor = 'Left,Right,Bottom'
    $Res = New-AfCtl 'TextBox' 16 464 680 92 ''; $Res.Multiline = $true; $Res.ReadOnly = $true; $Res.ScrollBars = 'Vertical'; $Res.Font = $FontMono; $Res.BackColor = $Th.Card; $Res.BorderStyle = 'FixedSingle'; $Res.Anchor = 'Left,Right,Bottom'
    $Res.Text = 'The result of each step shows here (names hidden), ready to paste into a ticket.'
    $BtnCopy = New-AfBtn 706 464 130 '&Copy result' $false; $BtnCopy.Anchor = 'Right,Bottom'
    $BtnStop = New-AfBtn 706 506 130 'Stop' $false; $BtnStop.Anchor = 'Right,Bottom'; $BtnStop.ForeColor = $Th.Chg; $BtnStop.FlatAppearance.BorderColor = $Th.Chg; $BtnStop.Enabled = $false
    $BtnStop.Add_Click({ $S.Cancel = $true; $BtnStop.Enabled = $false; $Status.Text = 'Stopping after the current item...' })
    $BtnCopy.Add_Click({ if ($Res.Text) { try { [Windows.Forms.Clipboard]::SetText($Res.Text); $Status.Text = 'Result copied.' } catch { $Status.Text = 'Could not copy; select the result text and press Ctrl+C.' } } })
    $Body.Controls.AddRange(@($TabPush, $TabUndo, $TabPst, $TabStat, $Prog, $Res, $BtnCopy, $BtnStop))
    $Form.Controls.AddRange(@($Body, $Rail, $Bar2, $Head))
    $Pages = @{ push = $TabPush; undo = $TabUndo; pst = $TabPst; stat = $TabStat }
    $RailBtns = @{ push = $RailPush; undo = $RailUndo; pst = $RailPst; stat = $RailStat }
    $Hints = @{ push = 'Step 1: tick the folders to move.'; undo = 'Step 1: pick a push or import to undo.'; pst = 'Step 1: choose the PST file.'; stat = 'This mailbox, read from Outlook. Changes nothing.' }
    function Show-AfPage([string] $Name) { foreach ($k in @($Pages.Keys)) { $Pages[$k].Visible = ($k -eq $Name); $RailBtns[$k].BackColor = $(if ($k -eq $Name) { $Th.RailSel } else { $Th.Rail }) }; $Status.Text = $Hints[$Name] }
    $RailPush.Add_Click({ if (-not $S.Busy) { Show-AfPage 'push' } }); $RailUndo.Add_Click({ if (-not $S.Busy) { Show-AfPage 'undo' } })
    $RailPst.Add_Click({ if (-not $S.Busy) { Show-AfPage 'pst' } }); $RailStat.Add_Click({ if (-not $S.Busy) { Show-AfPage 'stat' } })

    # ---- Push page ----
    $L1 = New-AfStepLabel 0 0 250 '1. Tick the folders to move from'
    $BtnRef = New-AfBtn 250 0 110 '&Refresh counts' $false; $BtnRef.Height = 24; $BtnRef.Font = $FontTag
    $Tree = New-AfCtl 'TreeView' 0 26 360 360 $null; $Tree.CheckBoxes = $true; $Tree.BackColor = $Th.Card; $Tree.BorderStyle = 'FixedSingle'; $Tree.Anchor = 'Top,Left,Bottom'
    $ChkSub = New-AfCtl 'CheckBox' 0 392 360 24 'Include &subfolders of ticked folders'; $ChkSub.Anchor = 'Left,Bottom'
    $L2 = New-AfStepLabel 380 0 300 '2. Move mail received before'
    $Date = New-AfCtl 'DateTimePicker' 380 28 150 28 $null; $Date.Format = 'Short'; $Date.MaxDate = (Get-Date).Date; $Date.Value = (Get-Date).Date.AddYears(-1)
    $qx = 540
    foreach ($q in @(@('6 months', -6), @('1 year', -12), @('2 years', -24), @('3 years', -36))) {
        $qb = New-AfBtn $qx 26 66 $q[0] $false; $qb.Height = 30; $qb.Font = $FontTag; $qb.Tag = $q[1]; $qb.Add_Click({ param($ctl) $Date.Value = (Get-Date).Date.AddMonths([int]$ctl.Tag) }); $TabPush.Controls.Add($qb); $qx += 70 }
    $L3 = New-AfStepLabel 380 70 300 '3. Options'
    $ChkUnread = New-AfCtl 'CheckBox' 380 94 200 24 'Skip u&nread mail'
    $ChkFlag = New-AfCtl 'CheckBox' 590 94 200 24 'Skip &flagged mail'
    $BtnPrev = New-AfBtn 380 128 150 '4. Pre&view' $false
    $BtnPush = New-AfBtn 540 128 220 '5. Push to &Online Archive' $true; $BtnPush.Enabled = $false
    $TagChg = New-AfTag 766 136 'CHG' $Th.Chg $Th.ChgBg
    $ListP = New-AfList 380 172 440 214 @(@('Folder', 190), @('Items', 60), @('Size', 80), @('In archive', 90)); $ListP.Anchor = 'Top,Left,Right,Bottom'
    $TotalP = New-AfCtl 'Label' 380 392 440 24 'Nothing moves until you click Push, then Yes.'; $TotalP.ForeColor = $Th.Dim; $TotalP.Anchor = 'Left,Right,Bottom'
    $TabPush.Controls.AddRange(@($L1, $BtnRef, $Tree, $ChkSub, $L2, $Date, $L3, $ChkUnread, $ChkFlag, $BtnPrev, $BtnPush, $TagChg, $ListP, $TotalP))

    function Get-AfNodeText($F) { $cnt = 0; try { $cnt = $F.Items.Count } catch { $null = $_ }; $t = '{0}   ({1})' -f $F.Name, $cnt
        $af = $null; if ($aroot) { try { $af = Find-AfArchivePath $aroot (Get-AfArchiveRelPath ([string]$F.FolderPath)) } catch { $null = $_ } }
        if ($af) { $na = 0; try { $na = $af.Items.Count } catch { $null = $_ }; $t += ('   archive: {0}' -f $na) }; $t }
    function Add-AfNode($Nodes, $Folder) {
        foreach ($sf in $Folder.Folders) {
            if ($skip.ContainsKey($sf.EntryID) -or $sf.DefaultItemType -ne 0 -or (Test-AfArchiveHidden $sf)) { continue }
            $nd = $Nodes.Add((Get-AfNodeText $sf)); $nd.Tag = $sf.EntryID; $S.Folders[$sf.EntryID] = $sf
            Add-AfNode $nd.Nodes $sf } }
    function Update-AfCount($Nodes) { foreach ($nd in $Nodes) { $f = $S.Folders[[string]$nd.Tag]; if ($f) { try { $nd.Text = Get-AfNodeText $f } catch { $null = $_ } }; Update-AfCount $nd.Nodes } }
    function Update-AfTree { $Tree.BeginUpdate(); try { Update-AfCount $Tree.Nodes } finally { $Tree.EndUpdate() }; [Windows.Forms.Application]::DoEvents() }
    Add-AfNode $Tree.Nodes $mroot
    foreach ($nd in $Tree.Nodes) { if ($nd.Text -like 'Inbox *') { $nd.Expand() } }
    $BtnRef.Add_Click({ if (-not $S.Busy) { $Status.Text = 'Refreshing counts...'; Update-AfTree; $Status.Text = 'Counts refreshed (mailbox and Online Archive).' } })
    $Tree.Add_AfterCheck({ $BtnPush.Enabled = $false; $S.Plan = $null })
    $Date.Add_ValueChanged({ $BtnPush.Enabled = $false; $S.Plan = $null })
    foreach ($x in @($ChkSub, $ChkUnread, $ChkFlag)) { $x.Add_CheckedChanged({ $BtnPush.Enabled = $false; $S.Plan = $null }) }
    function Get-AfTicked($Nodes) { foreach ($nd in $Nodes) { if ($nd.Checked) { $nd.Tag }; Get-AfTicked $nd.Nodes } }
    function Test-AfItemPick($It, [datetime] $Cut) {
        $ur = $false; $fs = 0; try { $ur = [bool]$It.UnRead } catch { $null = $_ }; try { $fs = [int]$It.FlagStatus } catch { $null = $_ }
        Test-AfArchivePick -Received (Get-AfArchiveReceived $It) -Cutoff $Cut -UnRead $ur -FlagStatus $fs -SkipUnread $ChkUnread.Checked -SkipFlagged $ChkFlag.Checked }

    $BtnPrev.Add_Click({
        $ids = @(Get-AfTicked $Tree.Nodes)
        if (-not $ids.Count) { [void][Windows.Forms.MessageBox]::Show('Tick at least one folder on the left first.', 'Nothing ticked'); return }
        $cut = $Date.Value.Date
        Set-AfBusy $true 'Counting (nothing moves)...'
        $folders = New-Object System.Collections.ArrayList; $seen = @{}
        function Add-AfPickFolder($F) { if ($seen.ContainsKey($F.EntryID) -or $skip.ContainsKey($F.EntryID) -or $F.DefaultItemType -ne 0 -or (Test-AfArchiveHidden $F)) { return }
            $seen[$F.EntryID] = 1; [void]$folders.Add($F); if ($ChkSub.Checked) { foreach ($sf in $F.Folders) { Add-AfPickFolder $sf } } }
        foreach ($id in $ids) { Add-AfPickFolder $S.Folders[$id] }
        $all = 0; foreach ($f in $folders) { $all += $f.Items.Count }
        $plan = @(); $k = 0; $done = 0
        foreach ($f in $folders) { if ($S.Cancel) { break }; $k++; $rel = Get-AfArchiveRelPath ([string]$f.FolderPath); $items = $f.Items; $cnt = $items.Count; $idl = New-Object System.Collections.ArrayList; $bytes = [int64]0
            for ($j = 1; $j -le $cnt; $j++) { if ($S.Cancel) { break }; $done++; Set-AfProgress $done $all ('Counting ' + $rel)
                $it = $null; try { $it = $items.Item($j); if (Test-AfItemPick $it $cut) { [void]$idl.Add($it.EntryID); $bytes += [int64]$it.Size } } catch { $null = $_ } finally { Remove-AfArchiveRef $it } }
            $af = Find-AfArchivePath $aroot $rel
            $plan += [pscustomobject]@{ Idx = $k; Folder = $f; Rel = $rel; Ids = $idl; Bytes = $bytes; SrcBefore = $cnt; ArcBefore = $(if ($af) { $af.Items.Count } else { 0 }); ArcExists = [bool]$af; Dest = $null } }
        if ($S.Cancel) { $ListP.Items.Clear(); $TotalP.Text = 'Preview stopped. Nothing moved.'; $Prog.Value = 0; Set-AfBusy $false 'Stopped. Nothing moved.'; return }
        $ListP.Items.Clear(); $tot = 0; $totB = [int64]0
        foreach ($p in $plan) { $tot += $p.Ids.Count; $totB += $p.Bytes
            $li = New-Object Windows.Forms.ListViewItem($p.Rel); [void]$li.SubItems.Add([string]$p.Ids.Count); [void]$li.SubItems.Add((Format-AfMb $p.Bytes)); [void]$li.SubItems.Add($(if ($p.ArcExists) { 'folder exists' } else { 'new folder' }))
            if (-not $p.Ids.Count) { $li.ForeColor = $Th.Dim }; [void]$ListP.Items.Add($li) }
        $S.Plan = @{ Plan = $plan; Cut = $cut; Tot = $tot; TotB = $totB; Folders = $folders.Count }
        $TotalP.Text = ('Would move {0} items ({1}) from {2} folder(s). Nothing has moved.' -f $tot, (Format-AfMb $totB), $folders.Count); $TotalP.ForeColor = $Th.Text
        $Prog.Value = 0; Set-AfBusy $false $(if ($tot) { 'Preview ready. Step 5: click Push to Online Archive.' } else { 'Nothing older than that date in those folders.' })
        $BtnPush.Enabled = [bool]$tot })

    $BtnPush.Add_Click({
        $pushPlan = $S.Plan; if (-not $pushPlan -or -not $pushPlan.Tot) { return }
        $warn = if ($pushPlan.Cut -gt (Get-Date).AddDays(-30)) { "`n`nNote: the date is less than 30 days ago, so recent mail moves too." } else { '' }
        $msg = ("Move {0} items ({1}) received before {2} into the Online Archive?`n`nThe folder layout is kept. Nothing is deleted. You can move them back from the Undo page.{3}" -f $pushPlan.Tot, (Format-AfMb $pushPlan.TotB), $pushPlan.Cut.ToString('yyyy-MM-dd'), $warn)
        if ([Windows.Forms.MessageBox]::Show($msg, 'Confirm push', 'YesNo', 'Question') -ne 'Yes') { $Status.Text = 'Push cancelled. Nothing moved.'; return }
        Set-AfBusy $true 'Moving...'
        try { $null = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop } catch { Set-AfBusy $false ('Cannot make the log folder: ' + $_.Exception.Message); return }
        $log = Join-Path $LogDir ('push-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
        $cols = 'SourcePath', 'SourceFolderId', 'SourceStoreId', 'ArchiveFolderId', 'ArchiveStoreId', 'OldEntryId', 'NewEntryId', 'Received', 'Size', 'Status', 'Error'
        Set-Content -LiteralPath $log -Value (($cols | ForEach-Object { '"' + $_ + '"' }) -join ',') -Encoding UTF8
        $made = 0; $ok = 0; $bad = 0; $late = 0; $g = 0
        foreach ($p in $pushPlan.Plan) { if ($S.Cancel) { break }; if (-not $p.Ids.Count) { continue }
            $dest = $aroot
            try { foreach ($nm in ($p.Rel -split '\\')) { $x = Get-AfArchiveSub $dest $nm; if (-not $x) { $x = $dest.Folders.Add($nm); $made++ }; $dest = $x } }
            catch { $bad += $p.Ids.Count; continue }
            $p.Dest = $dest
            foreach ($id in $p.Ids) { if ($S.Cancel) { break }; $g++; Set-AfProgress $g $pushPlan.Tot ('Moving ' + $p.Rel)
                $row = [ordered]@{ SourcePath = $p.Rel; SourceFolderId = $p.Folder.EntryID; SourceStoreId = $main.StoreID; ArchiveFolderId = $dest.EntryID; ArchiveStoreId = $arc.StoreID; OldEntryId = $id; NewEntryId = ''; Received = ''; Size = ''; Status = ''; Error = '' }
                $it = $null; $mv = $null
                try { $it = $ns.GetItemFromID($id, $main.StoreID); $t = Get-AfArchiveReceived $it; $row.Received = $t.ToString('yyyy-MM-dd HH:mm'); $row.Size = $it.Size
                    if (-not (Test-AfItemPick $it $pushPlan.Cut)) { $row.Status = 'skipped'; $row.Error = 'changed since preview'; $late++ }
                    else { $mv = $it.Move($dest); $row.NewEntryId = $mv.EntryID; $row.Status = 'moved'; $ok++ } }
                catch { $row.Status = 'failed'; $row.Error = ($_.Exception.Message -replace '[\r\n",]', ' '); $bad++ }
                finally { Remove-AfArchiveRef $mv; Remove-AfArchiveRef $it }
                Add-Content -LiteralPath $log -Value (([pscustomobject]$row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)) -Encoding UTF8 } }
        $stopped = [bool]$S.Cancel
        $Status.Text = 'After check: finding each moved item in the archive...'; [Windows.Forms.Application]::DoEvents()
        $mvd = @(Import-Csv -LiteralPath $log | Where-Object { $_.Status -eq 'moved' }); $found = 0; $q = 0
        foreach ($r in $mvd) { $q++; Set-AfProgress $q $mvd.Count 'After check'; $x = $null; try { $x = $ns.GetItemFromID($r.NewEntryId, $r.ArchiveStoreId); $found++ } catch { $null = $_ } finally { Remove-AfArchiveRef $x } }
        $after = @(); $okAll = $true
        foreach ($p in $pushPlan.Plan) { if (-not $p.Ids.Count -or -not $p.Dest) { continue }
            $m = @($mvd | Where-Object { $_.SourcePath -eq $p.Rel }).Count; $srcNow = $p.Folder.Items.Count; $arcNow = $p.Dest.Items.Count
            $fine = ($p.SrcBefore - $srcNow -eq $m) -and ($arcNow - $p.ArcBefore -eq $m); if (-not $fine) { $okAll = $false }
            $after += ('   {0}  moved {1}  source {2}->{3}  archive {4}->{5}  {6}' -f (Get-AfArchiveFolderLabel $p.Idx $p.Rel), $m, $p.SrcBefore, $srcNow, $p.ArcBefore, $arcNow, $(if ($fine) { 'OK' } else { 'CHECK' })) }
        $good = ($ok -gt 0) -and ($found -eq $ok) -and -not $bad -and $okAll -and -not $stopped
        $lines = @('Online Archive push', ('Cut-off: before {0}   Subfolders: {1}   Skip unread: {2}   Skip flagged: {3}   Folders: {4}' -f $pushPlan.Cut.ToString('yyyy-MM-dd'), $(if ($ChkSub.Checked) { 'Y' } else { 'N' }), $(if ($ChkUnread.Checked) { 'Y' } else { 'N' }), $(if ($ChkFlag.Checked) { 'Y' } else { 'N' }), $pushPlan.Folders),
            ('Move: moved {0}  failed {1}  skipped {2}  new archive folders {3}' -f $ok, $bad, $late, $made), 'After check (CHECK = mail arrived or left during the run, or a failure):') + $after + ('   found in archive by new id: {0} of {1}' -f $found, $ok) + ('Log: ' + (Split-Path $log -Leaf))
        if ($stopped) { $lines += 'STOPPED by the user: items not reached stay where they were. Undo still works for the ones that moved.' }
        Show-AfResult $lines $good $stopped
        $S.Plan = $null; $BtnPush.Enabled = $false; $ListP.Items.Clear()
        $TotalP.Text = $(if ($good) { "Done: all $ok items moved and found in the Online Archive." } else { 'Done with warnings: see the result box. Nothing was deleted.' }); $TotalP.ForeColor = $(if ($good) { $Th.Ok } else { $Th.Warn })
        $Status.Text = 'Refreshing counts...'; Update-AfTree
        Update-AfLogList; Set-AfBusy $false 'Push finished. Folder counts refreshed. Undo is on the Undo page.' })

    # ---- Undo page ----
    $U1 = New-AfStepLabel 0 0 600 '1. Pick a push or PST import to undo (newest first)'
    $ListL = New-AfList 0 26 820 150 @(@('Push or import', 250), @('When', 150), @('Items moved', 110), @('Undo status', 220)); $ListL.MultiSelect = $false; $ListL.Anchor = 'Top,Left,Right'
    $BtnUPrev = New-AfBtn 0 186 170 '2. Pre&view undo' $false
    $BtnUndo = New-AfBtn 180 186 230 '3. &Move back' $true; $BtnUndo.Enabled = $false
    $TagChgU = New-AfTag 416 194 'CHG' $Th.Chg $Th.ChgBg
    $ListU = New-AfList 0 230 820 156 @(@('Folder', 380), @('Still in archive', 150), @('Logged', 100), @('Goes back to', 230)); $ListU.Anchor = 'Top,Left,Right,Bottom'
    $TotalU = New-AfCtl 'Label' 0 392 820 24 'Nothing moves until you click Move back and then Yes. Archive folders the tool made stay (empty).'; $TotalU.ForeColor = $Th.Dim; $TotalU.Anchor = 'Left,Right,Bottom'
    $TabUndo.Controls.AddRange(@($U1, $ListL, $BtnUPrev, $BtnUndo, $TagChgU, $ListU, $TotalU))

    function Update-AfLogList {
        $ListL.Items.Clear()
        $logs = @(Get-ChildItem -LiteralPath $LogDir -Filter 'push-*.csv' -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $LogDir -Filter 'import-*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*-inventory.csv' })
        foreach ($lf in @($logs | Sort-Object LastWriteTime -Descending)) {
            $m = @(Import-Csv -LiteralPath $lf.FullName | Where-Object { $_.Status -eq 'moved' }).Count
            $ul = Join-Path $LogDir ('undo-' + $lf.Name); $back = 0; if (Test-Path -LiteralPath $ul) { $back = @(Import-Csv -LiteralPath $ul | Where-Object { $_.Status -eq 'back' }).Count }
            $li = New-Object Windows.Forms.ListViewItem($lf.Name); [void]$li.SubItems.Add($lf.LastWriteTime.ToString('yyyy-MM-dd HH:mm')); [void]$li.SubItems.Add([string]$m)
            [void]$li.SubItems.Add((Get-AfArchiveUndoState -Moved $m -Back $back)); $li.Tag = $lf.FullName
            if ($back -ge $m -and $m) { $li.ForeColor = $Th.Dim }; [void]$ListL.Items.Add($li) } }
    Update-AfLogList
    $ListL.Add_SelectedIndexChanged({ $BtnUndo.Enabled = $false; $S.UndoPlan = $null; $ListU.Items.Clear() })

    $BtnUPrev.Add_Click({
        if (-not $ListL.SelectedItems.Count) { [void][Windows.Forms.MessageBox]::Show('Click a push or import in the list first.', 'Nothing picked'); return }
        $log = [string]$ListL.SelectedItems[0].Tag; $ul = Join-Path $LogDir ('undo-' + (Split-Path $log -Leaf))
        $back = @{}; if (Test-Path -LiteralPath $ul) { foreach ($r in (Import-Csv -LiteralPath $ul)) { if ($r.Status -eq 'back') { $back[$r.ArchiveEntryId] = 1 } } }
        $todo = @(Import-Csv -LiteralPath $log | Where-Object { $_.Status -eq 'moved' -and -not $back.ContainsKey($_.NewEntryId) })
        $ListU.Items.Clear()
        if (-not $todo.Count) { $TotalU.Text = 'Nothing left to move back for this one.'; return }
        Set-AfBusy $true 'Checking the archive (nothing moves)...'
        $droot = $mroot; $dstore = $main.StoreID; $where = 'mailbox'
        $copyMode = ([string]$todo[0].Mode -eq 'copy'); $arcDel = $null
        if ($copyMode) { $where = 'archive Deleted Items'; $dstore = $arc.StoreID; try { $arcDel = $arc.GetDefaultFolder(3) } catch { $null = $_ }
            if (-not $arcDel) { Set-AfBusy $false 'Cannot find Deleted Items in the Online Archive. Nothing moved.'; return }; $droot = $arcDel }
        $plan = @(); $k = 0; $q = 0
        foreach ($gp in @($todo | Group-Object SourcePath)) { if ($S.Cancel) { break }; $k++; $r0 = $gp.Group[0]; $dest = $null; $how = 'same folder'
            if ($copyMode) { $dest = $arcDel; $how = 'the PST still has the originals' }
            else { try { $dest = $ns.GetFolderFromID($r0.SourceFolderId, $r0.SourceStoreId) } catch { $null = $_ }
                if (-not $dest) { $dest = Find-AfArchivePath $droot $gp.Name; $how = 'found by path' } }
            if (-not $dest) { $how = 'folder gone: made again' }
            $here = 0; foreach ($r in $gp.Group) { if ($S.Cancel) { break }; $q++; Set-AfProgress $q $todo.Count 'Checking'; $x = $null; try { $x = $ns.GetItemFromID($r.NewEntryId, $r.ArchiveStoreId); $here++ } catch { $null = $_ } finally { Remove-AfArchiveRef $x } }
            $plan += [pscustomobject]@{ Idx = $k; Rel = $gp.Name; Rows = $gp.Group; Dest = $dest; Root = $droot; How = $how; Here = $here; Before = $(if ($dest) { $dest.Items.Count } else { 0 }) }
            $li = New-Object Windows.Forms.ListViewItem($gp.Name); [void]$li.SubItems.Add([string]$here); [void]$li.SubItems.Add([string]$gp.Count); [void]$li.SubItems.Add($where + ': ' + $how)
            if ($here -lt $gp.Count) { $li.ForeColor = $Th.Warn }; [void]$ListU.Items.Add($li) }
        if ($S.Cancel) { $ListU.Items.Clear(); $TotalU.Text = 'Undo preview stopped. Nothing moved.'; $Prog.Value = 0; Set-AfBusy $false 'Stopped. Nothing moved.'; return }
        $tot = 0; foreach ($p in $plan) { $tot += $p.Here }
        $S.UndoPlan = $plan; $S.UndoLog = $log; $S.UndoTot = $tot; $S.UndoStoreId = $dstore; $S.UndoWhere = $where
        $note = if ($copyMode) { ' The archive''s retention policy may empty Deleted Items later; the PST and its backup keep the originals.' } else { '' }
        $TotalU.Text = ('Would move {0} items back. {1}{2}' -f $tot, $(if ($tot -lt $todo.Count) { ($todo.Count - $tot).ToString() + ' logged items are no longer in the archive and are skipped.' } else { 'Nothing has moved.' }), $note); $TotalU.ForeColor = $Th.Text
        $Prog.Value = 0; Set-AfBusy $false $(if ($tot) { 'Undo preview ready. Step 3: click Move back.' } else { 'None of those items are in the archive any more.' }); $BtnUndo.Enabled = [bool]$tot })

    $BtnUndo.Add_Click({
        $plan = $S.UndoPlan; if (-not $plan) { return }
        $extra = if ($S.UndoWhere -eq 'archive Deleted Items') { "`n`nThe archive's retention policy may empty Deleted Items later. The PST and its backup still have every email." } else { '' }
        if ([Windows.Forms.MessageBox]::Show(("Move {0} items back from the Online Archive to the {1}?{2}" -f $S.UndoTot, $S.UndoWhere, $extra), 'Confirm undo', 'YesNo', 'Question') -ne 'Yes') { $Status.Text = 'Undo cancelled. Nothing moved.'; return }
        Set-AfBusy $true 'Moving back...'
        $log = $S.UndoLog; $ul = Join-Path $LogDir ('undo-' + (Split-Path $log -Leaf))
        if (-not (Test-Path -LiteralPath $ul)) { Set-Content -LiteralPath $ul -Value '"SourcePath","ArchiveEntryId","MailboxEntryId","Status","Error"' -Encoding UTF8 }
        $ok = 0; $bad = 0; $gone = 0; $g = 0; $all = 0; foreach ($p in $plan) { $all += $p.Rows.Count }
        foreach ($p in $plan) { if ($S.Cancel) { break }
            if (-not $p.Dest) { try { $f = $p.Root; foreach ($nm in ($p.Rel -split '\\')) { $x = Get-AfArchiveSub $f $nm; if (-not $x) { $x = $f.Folders.Add($nm) }; $f = $x }; $p.Dest = $f } catch { $bad += $p.Rows.Count; continue } }
            foreach ($r in $p.Rows) { if ($S.Cancel) { break }; $g++; Set-AfProgress $g $all ('Moving back to ' + $p.Rel)
                $row = [ordered]@{ SourcePath = $p.Rel; ArchiveEntryId = $r.NewEntryId; MailboxEntryId = ''; Status = ''; Error = '' }; $it = $null; $mv = $null
                try { $it = $ns.GetItemFromID($r.NewEntryId, $r.ArchiveStoreId) } catch { $row.Status = 'not in archive'; $gone++ }
                if ($it) { try { $mv = $it.Move($p.Dest); $row.MailboxEntryId = $mv.EntryID; $row.Status = 'back'; $ok++ } catch { $row.Status = 'failed'; $row.Error = ($_.Exception.Message -replace '[\r\n",]', ' '); $bad++ } finally { Remove-AfArchiveRef $mv; Remove-AfArchiveRef $it } }
                Add-Content -LiteralPath $ul -Value (([pscustomobject]$row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)) -Encoding UTF8 } }
        $stopped = [bool]$S.Cancel
        $rows = @(Import-Csv -LiteralPath $ul | Where-Object { $_.Status -eq 'back' }); $found = 0; $q = 0
        foreach ($r in $rows) { $q++; Set-AfProgress $q $rows.Count 'After check'; $x = $null; try { $x = $ns.GetItemFromID($r.MailboxEntryId, $S.UndoStoreId); $found++ } catch { $null = $_ } finally { Remove-AfArchiveRef $x } }
        $after = @(foreach ($p in $plan) { if ($p.Dest) { '   {0}  folder {1}->{2}' -f (Get-AfArchiveFolderLabel $p.Idx $p.Rel), $p.Before, $p.Dest.Items.Count } })
        $good = -not $bad -and ($found -eq $rows.Count) -and -not $stopped
        $lines = @(('Online Archive undo (back to the ' + $S.UndoWhere + ')'), ('Log: ' + (Split-Path $log -Leaf)), ('Undo: back {0}  failed {1}  not in archive {2}' -f $ok, $bad, $gone), 'Folder counts before -> after:') + $after + ('Found back in the {0} by new id (all runs): {1} of {2}' -f $S.UndoWhere, $found, $rows.Count)
        if ($stopped) { $lines += 'STOPPED by the user: items not reached stay where they were. Undo still works for the rest.' }
        Show-AfResult $lines $good $stopped
        $S.UndoPlan = $null; $BtnUndo.Enabled = $false; $ListU.Items.Clear()
        $TotalU.Text = $(if ($good) { "Done: all $ok items are back in the $($S.UndoWhere)." } else { 'Done with warnings: see the result box. Click Preview undo again to retry.' }); $TotalU.ForeColor = $(if ($good) { $Th.Ok } else { $Th.Warn })
        $Status.Text = 'Refreshing counts...'; Update-AfTree
        Update-AfLogList; Set-AfBusy $false 'Undo finished. Folder counts refreshed.' })

    # ---- Import a PST page ----
    function Open-AfPstStore([string] $Path) {
        # Attaches the PST in Outlook on a helper runspace, so the window keeps drawing and Stop works.
        # Outlook can attach the PST without the call ever returning, so the store list is also watched.
        $st = Find-AfArchiveStoreByFile $Path; if ($st) { return $st }
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $S.OpenWhy = 'Outlook could not open the PST.'
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open(); $job = [powershell]::Create(); $job.Runspace = $rs
        [void]$job.AddScript({ param($pf) $ol = New-Object -ComObject Outlook.Application; $ol.GetNamespace('MAPI').AddStore($pf) }).AddArgument($Path)
        $h = $job.BeginInvoke(); $t0 = Get-Date; $Prog.Style = 'Marquee'; $seen = $null; $tick = 0
        while (-not $h.IsCompleted) { $tick++
            if ($tick % 6 -eq 0) { $seen = Find-AfArchiveStoreByFile $Path; if ($seen) { break } }
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150
            $secs = [int]((Get-Date) - $t0).TotalSeconds
            $Status.Text = ('Opening the PST in Outlook... {0} s  (if Outlook shows a message, answer it there; Stop gives up)' -f $secs)
            if ($S.Cancel) { $S.OpenWhy = 'Stopped while Outlook was opening the PST. Nothing imported.'; return $null }
            if ($secs -ge 120) { $S.OpenWhy = 'Outlook did not open the PST in 2 minutes. Look for a message in Outlook, or restart Outlook, then try again. Nothing imported.'; return $null } }
        if ($seen) { [void]$S.Attached.Add($seen); return $seen }   # the helper is left to finish on its own
        $failed = $job.HadErrors; $why = ''; if ($failed) { $why = [string]($job.Streams.Error | Select-Object -First 1) }
        try { $job.Dispose(); $rs.Dispose() } catch { $null = $_ }
        if ($failed) { $S.OpenWhy = 'Outlook refused the PST: ' + (Protect-AfArchiveText (($why -split "`n")[0])); return $null }
        $st = Find-AfArchiveStoreByFile $Path; if ($st) { [void]$S.Attached.Add($st) }; $st }
    function Copy-AfPstBackup([string] $Src, [string] $Dst, [bool] $Shared) {
        # Reads the original (never writes it), writes the backup, shows progress. Returns $true when the sizes match.
        $share = if ($Shared) { [IO.FileShare]::ReadWrite } else { [IO.FileShare]::Read }
        $in = [IO.File]::Open($Src, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share); $out = $null
        try { $out = [IO.File]::Open($Dst, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $buf = New-Object byte[] (4MB); $len = [int64]$in.Length; $done = [int64]0; $k = 0; $Prog.Maximum = 1000; $Prog.Style = 'Continuous'
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { if ($S.Cancel) { break }; $out.Write($buf, 0, $n); $done += $n; $k++
                if ($k % 8 -eq 1 -or $done -eq $len) { $Prog.Value = [int](1000 * $done / [Math]::Max($len, 1)); $Status.Text = ('Backing up the PST (the original is only read)  {0} of {1}' -f (Format-AfSizeText $done), (Format-AfSizeText $len)); [Windows.Forms.Application]::DoEvents() } } }
        finally { if ($out) { $out.Dispose() }; $in.Dispose() }
        if ($S.Cancel) { return $false }
        (Get-Item -LiteralPath $Dst).Length -eq (Get-Item -LiteralPath $Src).Length }

    $I1 = New-AfStepLabel 0 0 500 '1. Choose the PST file'
    $BtnPstPick = New-AfBtn 0 26 170 'Choose &PST...' $false
    $LblPst = New-AfCtl 'Label' 180 32 640 22 'No PST chosen yet. It can stay open in Outlook.'; $LblPst.ForeColor = $Th.Dim; $LblPst.Anchor = 'Top,Left,Right'
    $I2 = New-AfStepLabel 0 66 600 '2. Backup copy (made first; the PST keeps every email)'
    $LblWork = New-AfCtl 'Label' 0 92 640 22 ''; $LblWork.ForeColor = $Th.Dim; $LblWork.AutoEllipsis = $true; $LblWork.Anchor = 'Top,Left,Right'
    $BtnWork = New-AfBtn 650 86 170 'Change &folder...' $false; $BtnWork.Anchor = 'Top,Right'
    $I3 = New-AfStepLabel 0 124 400 '3. Archive folder and options'
    $TxtTarget = New-AfCtl 'TextBox' 0 150 300 26 'PST import'
    $ChkPstDate = New-AfCtl 'CheckBox' 320 150 220 24 'Only mail received &before'
    $DatePst = New-AfCtl 'DateTimePicker' 540 148 150 28 $null; $DatePst.Format = 'Short'; $DatePst.MaxDate = (Get-Date).Date.AddDays(1); $DatePst.Value = (Get-Date).Date.AddYears(-1); $DatePst.Enabled = $false
    $BtnPstPrev = New-AfBtn 0 186 210 '4. Back up and pre&view' $false
    $BtnPstGo = New-AfBtn 220 186 250 '5. Import to Online &Archive' $true; $BtnPstGo.Enabled = $false
    $TagChgI = New-AfTag 476 194 'CHG' $Th.Chg $Th.ChgBg
    $ListI = New-AfList 0 230 820 156 @(@('PST folder (untick to leave it out)', 380), @('Items', 90), @('Size', 100), @('Note', 220)); $ListI.CheckBoxes = $true; $ListI.Anchor = 'Top,Left,Right,Bottom'
    $TotalI = New-AfCtl 'Label' 0 392 820 24 'Nothing is imported until you click Import and then Yes.'; $TotalI.ForeColor = $Th.Dim; $TotalI.Anchor = 'Left,Right,Bottom'
    $TabPst.Controls.AddRange(@($I1, $BtnPstPick, $LblPst, $I2, $LblWork, $BtnWork, $I3, $TxtTarget, $ChkPstDate, $DatePst, $BtnPstPrev, $BtnPstGo, $TagChgI, $ListI, $TotalI))

    function Show-AfWorkFolder { $free = -1; try { $free = (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($S.WorkDir))).AvailableFreeSpace } catch { $null = $_ }
        $LblWork.Text = ('Backup goes to: {0}   (free space: {1})' -f (Protect-AfArchiveText $S.WorkDir), $(if ($free -ge 0) { Format-AfGb $free } else { 'unknown' })); $free }
    [void](Show-AfWorkFolder)
    function Reset-AfPstPlan { $S.PstPlan = $null; $S.PstTot = 0; $BtnPstGo.Enabled = $false }
    $ChkPstDate.Add_CheckedChanged({ $DatePst.Enabled = $ChkPstDate.Checked; Reset-AfPstPlan })
    $DatePst.Add_ValueChanged({ Reset-AfPstPlan }); $TxtTarget.Add_TextChanged({ Reset-AfPstPlan })
    $ListI.Add_ItemChecked({ if (-not $S.Busy) { Reset-AfPstPlan; $TotalI.Text = 'Folder ticks changed: click Back up and preview again (the backup is reused).'; $TotalI.ForeColor = $Th.Dim } })

    $BtnPstPick.Add_Click({
        $dlg = New-Object Windows.Forms.OpenFileDialog; $dlg.Filter = 'Outlook data file (*.pst)|*.pst'; $dlg.Title = 'Choose the PST to import'
        if ($dlg.ShowDialog($Form) -ne 'OK') { return }
        $fi = Get-Item -LiteralPath $dlg.FileName
        Add-AfRedactionName -Redactor $red -Names @($fi.BaseName)
        $S.PstSrc = $fi.FullName; $S.PstCopy = $null; $S.PstStore = $null; Reset-AfPstPlan; $ListI.Items.Clear()
        $LblPst.Text = ('{0}   ({1})' -f (Protect-AfArchiveText $fi.Name), (Format-AfSizeText $fi.Length))
        if ($fi.FullName -match '(?i)\\OneDrive') { $LblPst.Text += '   Note: in OneDrive; best moved to a local folder first' }; $LblPst.ForeColor = $Th.Text
        $TxtTarget.Text = 'PST import ' + (Get-Date -Format 'yyyy-MM-dd')
        $Status.Text = 'Step 4: click Back up and preview. Nothing is imported yet.' })
    $BtnWork.Add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog; $dlg.Description = 'Folder for the PST backup copy (needs free space at least the size of the PST)'
        if ($dlg.ShowDialog($Form) -eq 'OK') { $S.WorkDir = $dlg.SelectedPath; $S.PstCopy = $null; $S.PstStore = $null; Reset-AfPstPlan; [void](Show-AfWorkFolder) } })

    $BtnPstPrev.Add_Click({
        if (-not $S.PstSrc) { [void][Windows.Forms.MessageBox]::Show('Choose the PST file first (step 1).', 'No PST'); return }
        $tn = $TxtTarget.Text.Trim()
        if (-not $tn -or $tn -match '[\\/]') { [void][Windows.Forms.MessageBox]::Show('Type a folder name for the archive (no \ or / in it).', 'Archive folder name'); return }
        Set-AfBusy $true 'Getting the PST ready (nothing is imported)...'; $TotalI.Text = ''
        if (-not (Test-Path -LiteralPath $S.PstSrc)) { Set-AfBusy $false 'That PST file is not there any more. Click Choose PST again.'; return }
        $fi = Get-Item -LiteralPath $S.PstSrc; $LblPst.Text = ('{0}   ({1})' -f (Protect-AfArchiveText $fi.Name), (Format-AfSizeText $fi.Length))
        if (-not $S.PstCopy -or -not (Test-Path -LiteralPath $S.PstCopy)) {
            $len = $fi.Length; $free = Show-AfWorkFolder
            if ($free -ge 0 -and $free -lt ($len + 512MB)) { Set-AfBusy $false 'Not enough free space for the backup. Click Change folder and pick a drive with more space.'; return }
            try { $null = New-Item -ItemType Directory -Path $S.WorkDir -Force -ErrorAction Stop } catch { Set-AfBusy $false ('Cannot make the backup folder: ' + $_.Exception.Message); return }
            $dst = Join-Path $S.WorkDir ('pst-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.pst')
            $same = $false; $err = $null; $shared = $false
            try { $same = Copy-AfPstBackup $S.PstSrc $dst $false } catch { $err = $_ }
            if ($err) {   # held open by another program
                $ask = "Another program has this PST open (Outlook, or OneDrive syncing it).`n`nMake the backup anyway? The PST is only read for the backup. While Outlook has it open, the backup can miss the last few seconds of changes, and the hash check is skipped.`n`nNo = stop; close the PST in Outlook or pause OneDrive, then try again."
                if ([Windows.Forms.MessageBox]::Show($ask, 'PST is in use', 'YesNo', 'Question') -ne 'Yes') { Set-AfBusy $false 'Stopped. Nothing backed up or imported.'; return }
                Remove-Item -LiteralPath $dst -ErrorAction SilentlyContinue   # only the half-made backup this run started (never the original)
                $shared = $true
                try { $same = Copy-AfPstBackup $S.PstSrc $dst $true }
                catch { Set-AfBusy $false 'Could not read the PST even in shared mode. Close Outlook fully, pause OneDrive, then try again.'; $TotalI.Text = ('Backup failed: ' + (Protect-AfArchiveText (($_.Exception.Message -split "`n")[0]))); $TotalI.ForeColor = $Th.Warn; return } }
            if ($S.Cancel) { Remove-Item -LiteralPath $dst -ErrorAction SilentlyContinue; Set-AfBusy $false 'Backup stopped. Nothing imported.'; return }
            if (-not $same) { Set-AfBusy $false 'The backup is not the same size as the original. Nothing was imported; try again.'; return }
            $S.PstHash = 'skipped (PST was open in another program)'
            if (-not $shared) {
                $Status.Text = 'Checking the backup (SHA-256)...'; [Windows.Forms.Application]::DoEvents()
                $h1 = (Get-FileHash -LiteralPath $S.PstSrc -Algorithm SHA256).Hash; $h2 = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
                if ($h1 -ne $h2) { Set-AfBusy $false 'The backup does not match the original (SHA-256). Nothing was imported; try again.'; return }
                $S.PstHash = 'matches the original (SHA-256)' }
            $S.PstCopy = $dst }
        $Status.Text = 'Opening the PST in Outlook (if Outlook shows a message, answer it there)...'; [Windows.Forms.Application]::DoEvents()
        $pst = Open-AfPstStore $S.PstSrc   # the ORIGINAL (Outlook will not open a copy of a PST it already knows)
        if (-not $pst) { Set-AfBusy $false $S.OpenWhy; $TotalI.Text = $S.OpenWhy; $TotalI.ForeColor = $Th.Warn; return }
        $S.PstStore = $pst
        $byDate = $ChkPstDate.Checked; $cut = $DatePst.Value.Date
        $folders = New-Object System.Collections.ArrayList
        function Add-AfPstFolder($Fold) { foreach ($sf in $Fold.Folders) { if (Test-AfArchiveHidden $sf) { continue }; [void]$folders.Add($sf); Add-AfPstFolder $sf } }
        Add-AfPstFolder $pst.GetRootFolder()
        $all = 0; foreach ($fo in $folders) { if ($fo.DefaultItemType -eq 0) { $all += $fo.Items.Count } }
        $keep = @{}; foreach ($li in $ListI.Items) { $keep[$li.Text] = $li.Checked }   # remember the user's ticks between previews
        $rows = @(); $k = 0; $done = 0
        foreach ($fo in $folders) { if ($S.Cancel) { break }; $k++; $rel = Get-AfArchiveRelPath ([string]$fo.FolderPath); $idl = New-Object System.Collections.ArrayList; $kl = New-Object System.Collections.ArrayList; $bytes = [int64]0; $note = ''
            if ($fo.DefaultItemType -ne 0) { $note = 'not a mail folder: left out' }
            else { $items = $fo.Items; $cnt = $items.Count
                for ($j = 1; $j -le $cnt; $j++) { if ($S.Cancel) { break }; $done++; Set-AfProgress $done $all ('Counting ' + $rel)
                    $it = $null; try { $it = $items.Item($j); $t = Get-AfArchiveReceived $it; if (-not $byDate -or ($t -and $t -lt $cut)) { [void]$idl.Add($it.EntryID); [void]$kl.Add([pscustomobject]@{ Key = (Get-AfArchiveKeyOf $it); Received = $(if ($t) { $t.ToString('yyyy-MM-dd HH:mm') } else { '' }) }); $bytes += [int64]$it.Size } } catch { $null = $_ } finally { Remove-AfArchiveRef $it } }
                if (-not $idl.Count) { $note = 'nothing to import' } }
            $rows += [pscustomobject]@{ Idx = $k; Folder = $fo; Rel = $rel; Ids = $idl; Keys = $kl; Bytes = $bytes; SrcBefore = $(if ($fo.DefaultItemType -eq 0) { $fo.Items.Count } else { 0 }); Note = $note; Dest = $null; ArcBefore = 0 } }
        if ($S.Cancel) { $ListI.Items.Clear(); $TotalI.Text = 'Preview stopped. Nothing imported.'; $Prog.Value = 0; Set-AfBusy $false 'Stopped. Nothing imported.'; return }
        $ListI.BeginUpdate(); $ListI.Items.Clear()
        foreach ($r in $rows) { $li = New-Object Windows.Forms.ListViewItem($r.Rel); [void]$li.SubItems.Add([string]$r.Ids.Count); [void]$li.SubItems.Add((Format-AfMb $r.Bytes)); [void]$li.SubItems.Add($(if ($r.Ids.Count) { 'goes to: ' + $tn + '\' + $r.Rel } else { $r.Note }))
            $li.Tag = $r.Idx; $li.Checked = [bool]$r.Ids.Count -and ($keep.Count -eq 0 -or -not $keep.ContainsKey($r.Rel) -or $keep[$r.Rel]); if (-not $r.Ids.Count) { $li.ForeColor = $Th.Dim }; [void]$ListI.Items.Add($li) }
        $ListI.EndUpdate()
        $tot = 0; $totB = [int64]0; $on = 0
        foreach ($li in $ListI.Items) { if ($li.Checked) { $r = $rows[[int]$li.Tag - 1]; $tot += $r.Ids.Count; $totB += $r.Bytes; $on++ } }
        $S.PstPlan = @{ Rows = $rows; Target = $tn; ByDate = $byDate; Cut = $cut }; $S.PstTot = $tot
        $used = Get-AfArchiveStoreSize $arc
        $TotalI.Text = ('Would import {0} items ({1}) from {2} folder(s) into Online Archive\{3}. Archive now holds: {4}. Nothing is imported yet.' -f $tot, (Format-AfMb $totB), $on, $tn, $(if ($used -ge 0) { Format-AfGb $used } else { 'size not shown' }))
        $TotalI.ForeColor = $Th.Text
        if ($used -ge 0 -and ($used + $totB) -gt 45GB) { $TotalI.Text += ' WARNING: this goes past 45 GB; a Plan 1 archive holds 50 GB.'; $TotalI.ForeColor = $Th.Warn }
        $Prog.Value = 0; Set-AfBusy $false $(if ($tot) { 'Preview ready. Untick any folder to leave it out, then click Import to Online Archive.' } else { 'Nothing to import with these settings.' }) })

    $BtnPstGo.Add_Click({
        $imp = $S.PstPlan; if (-not $imp -or -not $S.PstTot) { return }
        $chosen = @(@(foreach ($li in $ListI.Items) { if ($li.Checked) { $imp.Rows[[int]$li.Tag - 1] } }) | Where-Object { $_.Ids.Count })
        $want = 0; foreach ($r in $chosen) { $want += $r.Ids.Count }
        if (-not $want) { return }
        $msg = ("Copy {0} items from the PST into Online Archive\{1}?`n`nHow: Outlook makes a temporary copy of each email inside the PST folder and moves that copy to the archive, so the PST file is written to and its date changes. The PST keeps every email it had. If a move fails, the temporary copy is removed again.`n`nA backup of the PST was made first. Every item is logged; Undo moves the imported emails to the archive's Deleted Items." -f $want, $imp.Target)
        if ([Windows.Forms.MessageBox]::Show($msg, 'Confirm PST import', 'YesNo', 'Question') -ne 'Yes') { $Status.Text = 'Import cancelled. Nothing moved.'; return }
        Set-AfBusy $true 'Importing...'
        $pst = $S.PstStore
        try { $null = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop } catch { Set-AfBusy $false ('Cannot make the log folder: ' + $_.Exception.Message); return }
        $log = Join-Path $LogDir ('import-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
        $cols = 'SourcePath', 'SourceFolderId', 'SourceStoreId', 'ArchiveFolderId', 'ArchiveStoreId', 'OldEntryId', 'NewEntryId', 'Received', 'Size', 'Status', 'Error', 'Mode'
        Set-Content -LiteralPath $log -Value (($cols | ForEach-Object { '"' + $_ + '"' }) -join ',') -Encoding UTF8
        $inv = $log -replace '\.csv$', '-inventory.csv'   # inventory BEFORE: every planned email (hashed key, received time, folder)
        $invRows = foreach ($r in $chosen) { foreach ($kr in $r.Keys) { [pscustomobject]@{ Side = 'PST before'; Folder = $r.Rel; Key = $kr.Key; Received = $kr.Received } } }
        @($invRows) | Export-Csv -LiteralPath $inv -NoTypeInformation -Encoding UTF8
        $made = 0; $ok = 0; $bad = 0; $late = 0; $g = 0; $leftover = 0; $cleaned = 0
        $top = Get-AfArchiveSub $aroot $imp.Target; if (-not $top) { try { $top = $aroot.Folders.Add($imp.Target); $made++ } catch { Set-AfBusy $false ('Cannot make the archive folder: ' + $_.Exception.Message); return } }
        foreach ($r in $chosen) { if ($S.Cancel) { break }
            $dest = $top
            try { foreach ($nm in ($r.Rel -split '\\')) { if (-not $nm) { continue }; $x = Get-AfArchiveSub $dest $nm; if (-not $x) { $x = $dest.Folders.Add($nm); $made++ }; $dest = $x } }
            catch { $bad += $r.Ids.Count; continue }
            $r.Dest = $dest; $r.ArcBefore = $dest.Items.Count
            foreach ($id in $r.Ids) { if ($S.Cancel) { break }; $g++; Set-AfProgress $g $want ('Importing ' + $r.Rel)
                $row = [ordered]@{ SourcePath = $r.Rel; SourceFolderId = $r.Folder.EntryID; SourceStoreId = $pst.StoreID; ArchiveFolderId = $dest.EntryID; ArchiveStoreId = $arc.StoreID; OldEntryId = $id; NewEntryId = ''; Received = ''; Size = ''; Status = ''; Error = ''; Mode = 'copy' }
                $it = $null; $mv = $null
                try { $it = $ns.GetItemFromID($id, $pst.StoreID); $t = Get-AfArchiveReceived $it; if ($t) { $row.Received = $t.ToString('yyyy-MM-dd HH:mm') }; $row.Size = $it.Size
                    if ($imp.ByDate -and -not ($t -and $t -lt $imp.Cut)) { $row.Status = 'skipped'; $row.Error = 'changed since preview'; $late++ }
                    else { $cp = $it.Copy()   # a temporary copy inside the PST folder, then moved straight to the archive
                        try { $mv = $cp.Move($dest); $row.NewEntryId = $mv.EntryID; $row.Status = 'moved'; $ok++ }
                        catch { $row.Status = 'failed'; $bad++; $why = ($_.Exception.Message -replace '[\r\n",]', ' ')
                            # Only the temporary copy this run just made is removed; the original email stays.
                            try { $cp.Delete(); $cleaned++; $row.Error = 'not moved; temporary copy removed from the PST folder. ' + $why }
                            catch { $leftover++; $row.Error = 'not moved; an extra copy is left in the PST folder. ' + $why } }
                        finally { Remove-AfArchiveRef $cp } } }
                catch { $row.Status = 'failed'; $row.Error = ($_.Exception.Message -replace '[\r\n",]', ' '); $bad++ }
                finally { Remove-AfArchiveRef $mv; Remove-AfArchiveRef $it }
                Add-Content -LiteralPath $log -Value (([pscustomobject]$row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1)) -Encoding UTF8 } }
        $stopped = [bool]$S.Cancel
        $Status.Text = 'After check: finding each imported item in the archive...'; [Windows.Forms.Application]::DoEvents()
        $mvd = @(Import-Csv -LiteralPath $log | Where-Object { $_.Status -eq 'moved' }); $found = 0; $q = 0
        foreach ($rw in $mvd) { $q++; Set-AfProgress $q $mvd.Count 'After check'; $x = $null; try { $x = $ns.GetItemFromID($rw.NewEntryId, $rw.ArchiveStoreId); $found++ } catch { $null = $_ } finally { Remove-AfArchiveRef $x } }
        $after = @(); $okAll = $true
        foreach ($r in $chosen) { if (-not $r.Dest) { continue }
            $m = @($mvd | Where-Object { $_.SourcePath -eq $r.Rel }).Count; $srcNow = $r.Folder.Items.Count; $arcNow = $r.Dest.Items.Count
            $fine = ($srcNow -eq $r.SrcBefore) -and ($arcNow - $r.ArcBefore -eq $m); if (-not $fine) { $okAll = $false }
            $after += ('   {0}  copied {1}  PST {2}->{3} (should not change)  archive {4}->{5}  {6}' -f (Get-AfArchiveFolderLabel $r.Idx $r.Rel), $m, $r.SrcBefore, $srcNow, $r.ArcBefore, $arcNow, $(if ($fine) { 'OK' } else { 'CHECK' })) }
        # Inventory AFTER: read every email in each archive folder and match it to the BEFORE inventory, one by one.
        $Status.Text = 'Inventory check: reading the archive folders...'; [Windows.Forms.Application]::DoEvents()
        $cmp = @(); $miss = @(); $allMiss = 0; $allMatch = 0; $allPlan = 0; $afterRows = New-Object System.Collections.ArrayList
        $tot2 = 0; foreach ($r in $chosen) { if ($r.Dest) { $tot2 += $r.Dest.Items.Count } }; $q = 0
        foreach ($r in $chosen) { if (-not $r.Dest) { $allPlan += $r.Keys.Count; $allMiss += $r.Keys.Count; continue }
            $keys = New-Object System.Collections.ArrayList; $items = $r.Dest.Items; $cnt = $items.Count
            for ($j = 1; $j -le $cnt; $j++) { $q++; Set-AfProgress $q $tot2 'Inventory check'
                $it = $null; try { $it = $items.Item($j); $key = Get-AfArchiveKeyOf $it; [void]$keys.Add($key); [void]$afterRows.Add([pscustomobject]@{ Side = 'Archive after'; Folder = $r.Rel; Key = $key; Received = '' }) } catch { $null = $_ } finally { Remove-AfArchiveRef $it } }
            $c = Compare-AfArchiveInventory -Planned @($r.Keys) -Found @($keys)
            foreach ($mr in $c.MissingReceived) { if ($miss.Count -lt 10) { $miss += ('     missing: received {0}  {1}' -f $mr, (Get-AfArchiveFolderLabel $r.Idx $r.Rel)) } }
            $allPlan += $c.Planned; $allMatch += $c.Found; $allMiss += $c.Missing
            $cmp += ('   {0}  PST before {1}  found in archive {2}  missing {3}  {4}' -f (Get-AfArchiveFolderLabel $r.Idx $r.Rel), $c.Planned, $c.Found, $c.Missing, $(if ($c.Missing) { 'CHECK' } else { 'OK' })) }
        @($afterRows) | Export-Csv -LiteralPath $inv -NoTypeInformation -Encoding UTF8 -Append
        $invOk = ($allPlan -gt 0) -and ($allMiss -eq 0) -and -not $stopped
        $good = ($ok -gt 0) -and ($found -eq $ok) -and -not $bad -and $okAll -and $invOk -and -not $stopped
        $lines = @('PST -> Online Archive import (copy)', ('PST size: {0}   Backup: {1}   Date filter: {2}   Folders: {3}' -f (Format-AfSizeText (Get-Item -LiteralPath $S.PstSrc).Length), $S.PstHash, $(if ($imp.ByDate) { 'before ' + $imp.Cut.ToString('yyyy-MM-dd') } else { 'none (all mail)' }), $chosen.Count),
            ('Import: copied {0}  failed {1}  skipped {2}  new archive folders {3}' -f $ok, $bad, $late, $made)) +
            @(if ($bad) { ('Temporary copies: removed {0}, left in the PST folder {1}' -f $cleaned, $leftover) }) +
            @('After check (CHECK = a failure, or the count did not match):') + $after + ('   found in archive by new id: {0} of {1}' -f $found, $ok) +
            ('Inventory check (every email in the PST before vs the archive after): {0} of {1} found, {2} missing  {3}' -f $allMatch, $allPlan, $allMiss, $(if ($invOk) { 'OK' } else { 'CHECK' })) + $cmp + $miss +
            ('Log: ' + (Split-Path $log -Leaf) + '   Inventory: ' + (Split-Path $inv -Leaf)) + ('PST: every email kept (Outlook wrote and moved temporary copies). Backup kept: ' + (Split-Path $S.PstCopy -Leaf))
        if ($stopped) { $lines += 'STOPPED by the user: items not reached stay where they were. Undo still works for the ones that were imported.' }
        Show-AfResult $lines $good $stopped
        Reset-AfPstPlan; $ListI.Items.Clear()
        $TotalI.Text = $(if ($good) { "Done: all $ok items imported. Inventory check: all $allMatch of $allPlan found in the Online Archive." } else { 'Done with warnings: see the result box. Nothing was deleted from the PST.' }); $TotalI.ForeColor = $(if ($good) { $Th.Ok } else { $Th.Warn })
        Update-AfLogList; Set-AfBusy $false 'Import finished. Undo is on the Undo page.' })

    # ---- Status page (this mailbox, read from Outlook) ----
    $T1 = New-AfStepLabel 0 0 600 'This mailbox (read from Outlook; changes nothing)'
    $LblMine = New-AfCtl 'Label' 0 26 640 90 ''; $LblMine.Anchor = 'Top,Left,Right'
    $BtnMine = New-AfBtn 650 26 170 'Check a&gain' $false; $BtnMine.Anchor = 'Top,Right'
    $LblOther = New-AfCtl 'Label' 0 130 820 60 'Checking another person''s mailbox needs Exchange Online and an admin sign-in, so it is not part of this window yet.'; $LblOther.ForeColor = $Th.Dim; $LblOther.Anchor = 'Top,Left,Right'
    $TabStat.Controls.AddRange(@($T1, $LblMine, $BtnMine, $LblOther))
    function Show-AfMine {
        $ms = Get-AfArchiveStoreSize $main
        if ($arc) { $as = Get-AfArchiveStoreSize $arc
            $LblMine.Text = ("Online Archive: ON (Outlook shows it as {0})`r`nMailbox size: {1}     Archive size: {2}`r`nPlan sizes: Plan 1 / Business Basic / Standard = 50 GB;  Plan 2 / E3 / E5 = 100 GB, grows to 1.5 TB." -f (Protect-AfArchiveText ([string]$arc.DisplayName)), $(if ($ms -ge 0) { Format-AfGb $ms } else { 'not shown' }), $(if ($as -ge 0) { Format-AfGb $as } else { 'not shown' }))
            $LblMine.ForeColor = $Th.Ok }
        else { $LblMine.Text = ("Online Archive: NOT SHOWN in this Outlook.`r`nMailbox size: {0}. Ask the mail admin whether the plan includes an archive and to turn it on. Push and Import stay off until it shows." -f $(if ($ms -ge 0) { Format-AfGb $ms } else { 'not shown' })); $LblMine.ForeColor = $Th.Warn } }
    $BtnMine.Add_Click({ Show-AfMine; $Status.Text = 'This mailbox checked again.' })

    $Lock = @($Tree, $BtnRef, $ChkSub, $Date, $ChkUnread, $ChkFlag, $BtnPrev, $BtnPush, $ListL, $BtnUPrev, $BtnUndo, $RailPush, $RailUndo, $RailPst, $RailStat, $BtnCopy,
        $BtnPstPick, $BtnWork, $TxtTarget, $ChkPstDate, $DatePst, $BtnPstPrev, $BtnPstGo, $ListI, $BtnMine)
    $NeedArc = @($RailPush, $RailUndo, $RailPst, $BtnRef, $BtnPrev, $BtnPush, $BtnUPrev, $BtnUndo, $BtnPstPrev, $BtnPstGo)
    foreach ($ctl in $TabPush.Controls) { if ($ctl -is [Windows.Forms.Button] -and $null -ne $ctl.Tag) { $Lock += $ctl } }
    Set-AfBusy $false $null
    Show-AfPage $(if ($arc) { 'push' } else { 'stat' }); Show-AfMine
    try { [void]$Form.ShowDialog() }
    finally {
        $Form.Dispose()
        foreach ($st in @($S.Attached)) { try { $ns.RemoveStore($st.GetRootFolder()) } catch { $null = $_ } }   # close a PST this window opened (the file stays)
    }

    if (-not $arc) { $S.Code = 3; [void]$S.Lines.Add('This mailbox has no Online Archive in Outlook. Nothing was changed.') }
    elseif ($S.Warn) { $S.Code = 1 }
    elseif ($S.Stopped) { $S.Code = 2 }
    else { $S.Code = 0 }
    & $saveResult
    return $S.Code
}
