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
        [hashtable] $Arguments = @{}
    )

    [pscustomobject]@{
        Kind = $Kind; Title = $Title; What = @($What); Changes = $Changes; Admin = $Admin; Internet = $Internet
        Seconds = $Seconds; RestorePoint = $RestorePoint; Warning = $Warning; Answers = $Answers; Task = $Task; Arguments = $Arguments
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
