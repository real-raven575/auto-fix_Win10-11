# What the window's change tasks do (GUI part 2): Repair Windows files, Disk Cleanup and
# Optimize drives. Each task is a plan first: what it changes, whether it needs
# administrator rights, where it goes online, and the answers the user gives in the
# "Are you sure?" dialog. The window then runs the same engine function the console menu
# runs, in a background runspace, with those answers (see $script:AfGuiRun in
# Core\Redaction.ps1). Nothing here needs WPF, so the tests run on any machine.

$script:AfGuiNo = @{ $true = 'Yes'; $false = 'No' }

function New-AfGuiPlan {
    # One task plan. Task is the engine call, run with param($A) = Arguments.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $Title,
        [string[]] $What = @(),
        [bool] $Changes,
        [bool] $Admin = $true,
        [string] $Internet = 'Never',
        [double] $Seconds,
        [bool] $RestorePoint,
        [string] $Warning,
        [hashtable] $Answers = @{},
        [Parameter(Mandatory)] [string] $Task,
        [hashtable] $Arguments = @{},
        # Ask in the dialog even though nothing changes (a test page uses paper).
        [bool] $Ask,
        # One extra tick box in the dialog; its tick answers OptionPrompt.
        [string] $OptionText,
        [string] $OptionPrompt,
        [bool] $OptionChecked = $true,
        # A second "Are you sure?" after Yes, for steps that lose data.
        [string] $SecondAsk
    )

    [pscustomobject]@{
        Kind = $Kind; Title = $Title; What = @($What); Changes = $Changes; Admin = $Admin; Internet = $Internet
        Seconds = $Seconds; RestorePoint = $RestorePoint; Warning = $Warning; Answers = $Answers; Task = $Task; Arguments = $Arguments
        Ask = $Ask; OptionText = $OptionText; OptionPrompt = $OptionPrompt; OptionChecked = $OptionChecked; SecondAsk = $SecondAsk
    }
}

function Get-AfGuiConfirmLines {
    # The body of the "Are you sure?" dialog, as plain lines. The same words a screen reader gets.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Plan)

    'What it does:'
    foreach ($w in $Plan.What) { '  - ' + $w }
    ''
    'Changes this PC: {0}' -f $script:AfGuiNo[[bool]$Plan.Changes]
    'Needs administrator rights: {0}' -f $script:AfGuiNo[[bool]$Plan.Admin]
    'Internet: {0}' -f $Plan.Internet
    if ($Plan.Seconds -gt 0) { 'Time: {0}' -f (Format-AfApprox $Plan.Seconds) }
    if ($Plan.Warning) { ''; $Plan.Warning }
}

function Get-AfGuiRepairPlan {
    # SFC and DISM steps in order. Standard mode's step-by-step questions are all in this
    # one dialog; anything the dialog did not ask (such as "continue without a restore
    # point?") is answered No, so the run stops instead of guessing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Queue,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot
    )

    $historyPath = Get-AfHistoryPath -OutputRoot $OutputRoot
    $seconds = 0.0
    foreach ($key in $Queue) { $seconds += Get-AfRepairEstimate -Key $key -HistoryPath $historyPath }
    $what = New-Object System.Collections.Generic.List[string]
    $answers = @{ 'Plan' = $true; 'Continue without a restore point?' = $false; 'Run the remaining steps anyway?' = $false; 'Restart now?' = $false }
    $changes = $false
    foreach ($key in ($Queue | Select-Object -Unique)) {
        $step = $script:AfRepairSteps[$key]
        $kind = 'reads only'
        if ($step.Changes) { $kind = 'CHANGES this PC'; $changes = $true; $answers[('Start {0}?' -f $step.Name)] = $true }
        $what.Add(('{0} ({1}): {2}' -f $step.Name, $kind, $step.What))
    }
    $internet = 'Never'
    if ($Queue -contains 'RESTORE' -and $Settings.Online) {
        $internet = 'Windows Update (Microsoft), only for DISM RestoreHealth, to download clean copies of damaged system files.'
        $answers['Connect to Windows Update?'] = $true
    }
    elseif ($Queue -contains 'RESTORE') { $internet = 'Never. The Online switch in Settings is off, so RestoreHealth uses only the files already on this PC.' }
    $title = 'Repair Windows files'
    if ($Queue.Count -eq 1) { $title = $script:AfRepairSteps[$Queue[0]].Name }
    $warning = $null
    if ($changes) { $warning = 'Windows may need a restart afterwards. Auto-Fixer will tell you; it never restarts on its own from this window.' }
    New-AfGuiPlan -Kind 'repair' -Title $title -What $what.ToArray() -Changes $changes -Internet $internet -Seconds $seconds `
        -RestorePoint $changes -Warning $warning -Answers $answers -Arguments @{ Queue = @($Queue); Settings = $Settings; OutputRoot = $OutputRoot } `
        -Task 'param($A) Invoke-AfRepairBatch -Queue $A.Queue -Settings $A.Settings -OutputRoot $A.OutputRoot -ReadKey { ''N'' }'
}

function Get-AfGuiMeasurePlan {
    # Disk Cleanup, part 1: measure what each item would free. Reads only, so no dialog.
    [CmdletBinding()]
    param()

    New-AfGuiPlan -Kind 'measure' -Title 'Measuring Disk Cleanup items' -What @('Adds up what each Disk Cleanup item would free. Reads only.') `
        -Seconds 60 -Task 'param($A) @(Get-AfCleanItem -Handlers @(Get-ChildItem -LiteralPath $script:AfVolumeCachesPath -ErrorAction Stop | ForEach-Object { $_.PSChildName }))'
}

function Get-AfGuiCleanPlan {
    # Disk Cleanup, part 2: remove the ticked items. Items that lose something (Recycle Bin,
    # Downloads, going back to old Windows) are named in the dialog with their warning, so
    # the console's "Remove X anyway?" is answered by the same Yes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot
    )

    $chosen = @($Items | Where-Object { $_.Checked -and -not $_.Locked })
    $answers = @{ 'Run Disk Cleanup now?' = $true }
    $what = foreach ($item in $chosen) {
        $line = '{0}: {1}' -f $item.Label, (Format-AfSize $item.Size)
        if ($item.Warn -ge 2) { $line += '. ' + $item.Note; $answers[('Remove {0} anyway?' -f $item.Label)] = $true }
        $line
    }
    $total = Get-AfCheckListTotal -Items $chosen
    $sizes = @{}
    foreach ($item in @($Items)) { $sizes[[string]$item.Key] = $item.Size }
    New-AfGuiPlan -Kind 'clean' -Title 'Disk Cleanup' -What @($what) -Changes $true -Seconds 300 -Answers $answers `
        -Warning ('About {0} in all. Removed files cannot be put back. Windows shows its own small Disk Cleanup window while it works; leave it open.' -f (Format-AfSize $total.Bytes)) `
        -Arguments @{ Chosen = @($chosen | ForEach-Object { [string]$_.Key }); Sizes = $sizes; Settings = $Settings; OutputRoot = $OutputRoot } `
        -Task 'param($A) Invoke-AfDiskCleanup -Settings $A.Settings -OutputRoot $A.OutputRoot -ReadKey { ''N'' } -ClearScreen { } -Measure { param($Key) $A.Sizes[$Key] } -Pick { param($Items) [pscustomobject]@{ Action = ''Continue''; Items = @($Items | Where-Object { $A.Chosen -contains [string]$_.Key }) } }'
}

function Get-AfGuiOptimizePlan {
    # TRIM an SSD or defrag a hard drive; an SSD is never defragged.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Drive,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot
    )

    $action = Get-AfDriveAction -Media $Drive.Media
    $historyPath = Get-AfHistoryPath -OutputRoot $OutputRoot
    if ($action -eq 'TRIM') {
        $what = 'TRIM drive {0}: tells the SSD which blocks are free, so it stays fast. No files are moved or deleted.' -f $Drive.Letter
        $seconds = Get-AfRepairEstimate -Key 'TRIM' -HistoryPath $historyPath -DefaultSeconds 120
    }
    else {
        $what = 'Defrag drive {0}: puts the pieces of each file back together. No files are deleted; the PC is slower while it runs.' -f $Drive.Letter
        $seconds = Get-AfRepairEstimate -Key 'DEFRAG' -HistoryPath $historyPath -DefaultSeconds 1800
    }
    New-AfGuiPlan -Kind 'optimize' -Title ('Optimize drive {0}:' -f $Drive.Letter) -What @($what) -Changes $true -Seconds $seconds `
        -Answers @{ 'Start now?' = $true } -Arguments @{ Drive = $Drive; Settings = $Settings; OutputRoot = $OutputRoot } `
        -Task 'param($A) Invoke-AfDriveOptimize -Drive $A.Drive -Settings $A.Settings -OutputRoot $A.OutputRoot -ReadKey { ''N'' }'
}

function ConvertFrom-AfGuiHostLine {
    <#
    .SYNOPSIS
        Turns what the engine wrote with Write-Host into Activity rows: Text and a tag
        (OK, WARN, FAIL or INFO, from the line's colour). Pieces written with -NoNewline
        are joined first; -Pending carries an unfinished line between calls.
    #>
    [CmdletBinding()]
    param(
        # Each: Message, NoNewLine, ForegroundColor (a HostInformationMessage, or the same shape).
        [object[]] $Records = @(),
        [Parameter(Mandatory)] [hashtable] $Pending
    )

    $tags = @{ Red = 'FAIL'; DarkRed = 'FAIL'; Yellow = 'WARN'; DarkYellow = 'WARN'; Green = 'OK'; DarkGreen = 'OK' }
    foreach ($r in $Records) {
        $text = [string]$r.Message
        if (-not $Pending.Text -and $null -ne $r.ForegroundColor) { $Pending.Color = [string]$r.ForegroundColor }
        $Pending.Text += $text
        if ($r.NoNewLine) { continue }
        # Colour codes and cursor moves are for consoles only.
        $line = ($Pending.Text -replace "$([char]27)\[[0-9;?]*[A-Za-z]", '').Trim()
        $tag = $tags[[string]$Pending.Color]
        $Pending.Text = ''
        $Pending.Color = $null
        if (-not $line -or $line -match '^[-=]{3,}$') { continue }
        if (-not $tag) { $tag = 'INFO' }
        [pscustomobject]@{ Text = $line; Tag = $tag }
    }
}

# Printers (GUI part 3): the same check and fixes as the console's Printers menu. Each
# button names the printer it is for, so the console's "which printer?" list is answered
# by that click (the -Pick hook of Invoke-AfPrinterFix).
$script:AfGuiPrinterAdminKeys = @('R', 'C', 'J', 'S', 'V', 'M', 'U', 'P')
$script:AfGuiPrinterTechKeys = @('V', 'M', 'U', 'P')

function Get-AfGuiPrinterCheckPlan {
    # The read-only printer check. No dialog.
    [CmdletBinding()]
    param()

    New-AfGuiPlan -Kind 'printcheck' -Title 'Printer check (read-only)' -What @('Reads the Print Spooler, printers, waiting jobs and recent print errors.') -Admin $false -Seconds 15 `
        -Task 'param($A) Get-AfPrinterCheck -OnStep { param($Number, $Count, $Text) Write-Host (''Step {0} of {1}: {2}'' -f $Number, $Count, $Text) }'
}

function Get-AfGuiPrinterListPlan {
    # Read-only lists for Technician removal and for adding a printer: unused drivers, or
    # printers shared in the domain. No dialog.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidateSet('Drivers', 'Domain')] [string] $List, $Check)

    if ($List -eq 'Drivers') {
        return New-AfGuiPlan -Kind 'printdrivers' -Title 'Finding unused printer drivers' -What @('Asks Windows which drivers no printer uses. Reads only.') -Admin $false -Seconds 10 `
            -Arguments @{ Check = $Check } -Task 'param($A) Write-Host ''Asking Windows which printer drivers are in use''; @(Get-AfUnusedPrinterDriver -Check $A.Check)'
    }
    New-AfGuiPlan -Kind 'printdomain' -Title 'Searching the domain for shared printers' -Admin $false -Seconds 30 `
        -What @('Lists printers shared in your domain. Reads only; it asks only your domain controller.') `
        -Task 'param($A) if (-not (& (Get-AfPrinterOps).IsDomain)) { Write-Host ''This PC is not in a domain, so there is no directory to search. Use Connect by name or the Windows wizard.'' -ForegroundColor Yellow; return }; Write-Host ''Asking the domain controller (up to 30 s)''; @(Find-AfDomainPrinter)'
}

function Get-AfGuiPrinterFixPlan {
    # One printer fix. -Printer is the printer the button is for; -Keep the copy to keep
    # (P); -Driver the driver to remove (U); -Path the \\server\printer to connect (N).
    # -Show turns a name into what the screen may show (redacted unless Show sensitive).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('T', 'O', 'J', 'C', 'R', 'D', 'S', 'V', 'M', 'P', 'U', 'N', 'W')] [string] $Key,
        [Parameter(Mandatory)] $Check,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        $Printer,
        $Group,
        [string] $Keep,
        [string] $Driver,
        [string] $Path,
        [scriptblock] $Show = { param($Text) $Text }
    )

    $name = ''
    if ($Printer) { $name = & $Show $Printer.Name }
    $picks = @()
    if ($Printer) { $picks = @([string]$Printer.Name) }
    $answers = @{}
    $p = @{ Changes = $true; Admin = ($script:AfGuiPrinterAdminKeys -contains $Key); Seconds = 10 }
    switch ($Key) {
        'T' { $p.Title = 'Print a test page'; $p.What = @(('Sends Windows'' own test page to {0}. It uses one sheet of paper.' -f $name)); $p.Changes = $false; $p.Ask = $true; $answers['Print the test page?'] = $true }
        'O' { $p.Title = 'Printer online again'; $p.What = @(('Turns off Use printer offline for {0}.' -f $name)); $answers['Turn it back online?'] = $true }
        'J' { $p.Title = 'Cancel waiting jobs'; $p.What = @(('Cancels the {0} waiting job(s) on {1}. Other printers keep theirs.' -f $Printer.Jobs, $name)); $answers['Cancel these jobs?'] = $true }
        'C' {
            $p.Title = 'Clear all print jobs'; $p.Seconds = 60
            $p.What = @(('Stops the Print Spooler, deletes the waiting job files ({0} job(s), {1} file(s)) and starts it again.' -f $Check.JobCount, $Check.SpoolFileCount))
            $p.Warning = 'Every waiting job on every printer is lost. Print them again afterwards.'
            $p.SecondAsk = 'Every waiting job on every printer is deleted and cannot be brought back. Clear them anyway?'
            $answers['Clear all print jobs?'] = $true; $answers['Are you sure? Waiting jobs cannot be brought back.'] = $true
        }
        'R' { $p.Title = 'Restart the Print Spooler'; $p.Seconds = 60; $p.What = @('Stops the Print Spooler and starts it again. Waiting jobs stay in the queue.'); $answers['Restart the Print Spooler now?'] = $true }
        'D' {
            $p.Title = 'Default printer'; $p.What = @(('Makes {0} the default printer for this Windows account.' -f $name)); $answers['Set the default printer?'] = $true
            if ($Check.WindowsManagesDefault) {
                $p.OptionText = 'Also stop Windows from changing it (turns off Let Windows manage my default printer).'
                $p.OptionPrompt = 'Turn that setting off?'
            }
        }
        'S' { $p.Title = 'Spooler start type'; $p.What = @(('Sets the Print Spooler to start Automatic (now: {0}).' -f $Check.StartMode)); $answers['Change the start type?'] = $true }
        'V' { $p.Title = 'Spooler recovery'; $p.What = @('Windows restarts the Print Spooler 60 seconds after a crash (first and second time). The old and new settings go in the log.'); $answers['Set the recovery options?'] = $true }
        'M' {
            $p.Title = 'Remove a printer'
            $p.What = @(('Removes {0} from this PC. Its driver stays; add the printer again in Settings > Printers.' -f $name))
            if ($Printer.Jobs -gt 0) { $p.Warning = 'Its {0} waiting job(s) are lost.' -f $Printer.Jobs }
            $answers['Remove this printer?'] = $true
        }
        'P' {
            $p.Title = 'Remove duplicate copies'
            $others = @($Group.Names | Where-Object { $_ -ne $Keep })
            $p.What = @(('Keeps {0}.' -f (& $Show $Keep))) + @($others | ForEach-Object { 'Removes the extra copy {0}. Its driver stays.' -f (& $Show $_) })
            $lost = @($Check.Printers | Where-Object { $others -contains $_.Name -and $_.Jobs -gt 0 })
            if ($lost.Count) { $p.Warning = 'Waiting jobs on the removed copies are lost.' }
            foreach ($o in $others) { $answers[('Remove the extra copy {0}?' -f $o)] = $true }
            # The console asks which group first (when there are several), then which copy to keep.
            $picks = @(($Group.Names -join ' = '), $Keep)
        }
        'U' {
            $p.Title = 'Remove unused driver'
            $p.What = @(('Removes the printer driver {0}. Windows is asked again just before that no printer uses it.' -f $Driver))
            $p.OptionText = 'Make a restore point first (recommended).'
            $p.OptionPrompt = 'Make a restore point first?'
            $answers['Remove this driver?'] = $true
            $picks = @($Driver)
        }
        'N' {
            $p.Title = 'Connect a shared printer'; $p.Seconds = 60
            $p.What = @(('Connects {0}. Windows installs the driver from the print server if the server shares one.' -f (& $Show $Path)))
            $p.Internet = 'Never. It uses only your own network (the print server).'
            $answers['Add this printer?'] = $true
        }
        'W' { $p.Title = 'Windows Add a printer wizard'; $p.Seconds = 180; $p.What = @('Opens Windows'' own Add a printer wizard and waits for it to close.'); $answers['Open the Add a printer wizard?'] = $true }
    }
    $internet = 'Never'
    if ($p.Internet) { $internet = $p.Internet }
    New-AfGuiPlan -Kind 'printfix' -Title $p.Title -What $p.What -Changes $p.Changes -Admin $p.Admin -Internet $internet -Seconds $p.Seconds `
        -Warning $p.Warning -Answers $answers -Ask ([bool]$p.Ask) -OptionText $p.OptionText -OptionPrompt $p.OptionPrompt -SecondAsk $p.SecondAsk `
        -Arguments @{ Key = $Key; Check = $Check; Settings = $Settings; OutputRoot = $OutputRoot; Picks = @($picks); Path = $Path } `
        -Task 'param($A) Invoke-AfGuiPrinterFix -Key $A.Key -Check $A.Check -Settings $A.Settings -OutputRoot $A.OutputRoot -Picks $A.Picks -Path $A.Path'
}

function Invoke-AfGuiPrinterFix {
    # Runs in the task runspace: the console's own fix, with the clicked printer as the
    # pick, a printer log like the console's, and the outcome written to it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Picks', Justification = 'Used by the pick script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Path', Justification = 'Used by the ReadText script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] $Check,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [string[]] $Picks = @(),
        [string] $Path,
        [hashtable] $Ops = (Get-AfPrinterOps)
    )

    $redactor = New-AfRedactor
    Add-AfRedactionName -Redactor $redactor -Names @($Check.Printers | ForEach-Object { $_.Name })
    $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'printer' -Redactor $redactor -Task 'Printers (window)'
    # The row whose name was clicked; none (the list changed) means nothing is changed.
    $pick = { param($List, $Title) Write-Verbose $Title; @(@($List) | Where-Object { $Picks -contains [string]$_.Name })[0] }
    $r = Invoke-AfPrinterFix -Key $Key -Check $Check -Settings $Settings -Log $log -Ops $Ops -ReadKey { 'N' } -ReadText { $Path } -Pick $pick
    Write-AfPrinterLog $log ('{0,-7}{1}: {2}' -f $r.Tag, $Key, $r.Detail)
    Write-Host ('Log: {0}' -f $log.Path)
    return $r
}

function Get-AfGuiTimeProgress {
    # The bar for steps that print no percent: elapsed against the estimate, never 100%
    # before the step really ends.
    [CmdletBinding()]
    param([double] $Elapsed, [double] $Estimate)

    if ($Estimate -le 0) { $Estimate = 60 }
    $percent = [math]::Min(99, [math]::Floor(100 * $Elapsed / $Estimate))
    $left = $Estimate - $Elapsed
    $text = 'Elapsed {0}, about {1} left (estimated by time)' -f (Format-AfSpan $Elapsed), (Format-AfSpan $left)
    if ($left -le 0) { $text = 'Elapsed {0}. Taking longer than expected; it is still working.' -f (Format-AfSpan $Elapsed) }
    [pscustomobject]@{ Percent = [int]$percent; Text = $text }
}

function Get-AfGuiTaskOutcome {
    # The one line under the bar when a task ends: Tag (OK, WARN, FAIL) and Text.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Kind, $Result, [string] $ErrorText)

    if ($ErrorText) { return [pscustomobject]@{ Tag = 'FAIL'; Text = ('Stopped: {0}' -f $ErrorText) } }
    switch ($Kind) {
        'repair' {
            $steps = @($Result.Steps)
            $bad = @($steps | Where-Object { $_.Tag -in 'FAILED', 'ISSUES', 'STOPPED' }).Count
            $skipped = @($steps | Where-Object { $_.Tag -eq 'SKIPPED' }).Count
            $text = '{0} of {1} step(s) OK' -f @($steps | Where-Object { $_.Tag -eq 'OK' }).Count, $steps.Count
            if ($bad) { $text += ', {0} with problems' -f $bad }
            if ($skipped) { $text += ', {0} not run' -f $skipped }
            $text += '. See Activity for each step.'
            if ($Result.RestartNeeded) { $text += ' Windows needs a restart to finish these repairs. Restart when you are ready.' }
            $tag = 'OK'
            if ($skipped -or $Result.Stopped) { $tag = 'WARN' }
            if ($bad) { $tag = 'FAIL' }
            return [pscustomobject]@{ Tag = $tag; Text = $text }
        }
        'printcheck' {
            return [pscustomobject]@{ Tag = 'OK'; Text = ('Printer check done: {0} printer(s), Print Spooler {1}.' -f @($Result.Printers).Count, $Result.SpoolerState) }
        }
        'printdrivers' {
            return [pscustomobject]@{ Tag = 'OK'; Text = ('{0} unused printer driver(s) found. Built-in drivers are never listed.' -f @($Result | Where-Object { $_ }).Count) }
        }
        'printdomain' {
            return [pscustomobject]@{ Tag = 'OK'; Text = ('{0} shared printer(s) found in the domain.' -f @($Result | Where-Object { $_ }).Count) }
        }
        'measure' {
            return [pscustomobject]@{ Tag = 'OK'; Text = ('{0} Disk Cleanup item(s) measured. Tick what to remove on the Clean up page.' -f @($Result).Count) }
        }
        default {
            $tag = [string]$Result.Tag
            $map = @{ OK = 'OK'; CANCELLED = 'WARN'; STOPPED = 'WARN'; FAILED = 'FAIL' }
            $word = @{ OK = 'Finished.'; CANCELLED = 'Nothing was changed.'; STOPPED = 'Stopped part-way.'; FAILED = 'It did not finish.' }[$tag]
            if (-not $word) { $word = 'Done.' }
            if ($Kind -eq 'clean' -and $null -ne $Result.Freed) { $word += ' Freed {0}.' -f (Format-AfSize $Result.Freed) }
            if ($Result.Detail) { $word += ' ' + $Result.Detail }
            $t = $map[$tag]
            if (-not $t) { $t = 'INFO' }
            return [pscustomobject]@{ Tag = $t; Text = $word.Trim() }
        }
    }
}
