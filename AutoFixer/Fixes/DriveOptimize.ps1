# Optimize drives (Clean up menu, plan 2026-10-30): TRIM for SSDs, defrag for hard drives.
#   - an SSD is never offered a defrag, in any mode
#   - a drive Windows can't identify (VMs, RAID, USB boxes) gets TRIM only
#   - both run Windows' own defrag.exe, the engine behind "Optimize Drives", which prints a %
#   - every run asks Y/N first; Windows settings change only in Technician mode, and are logged

$script:AfDefragTaskPath = '\Microsoft\Windows\Defrag\'
$script:AfDefragTaskName = 'ScheduledDefrag'

function Get-AfDriveMedia {
    # SSD, HDD or Unknown for the disk under a drive letter. Read-only.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Letter)

    try {
        $partition = Get-Partition -DriveLetter $Letter -ErrorAction Stop
        $disk = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$partition.DiskNumber })[0]
        if ($disk) {
            switch ([string]$disk.MediaType) {
                'SSD' { return 'SSD' }
                'SCM' { return 'SSD' }
                'HDD' { return 'HDD' }
            }
        }
    }
    catch { Write-Verbose ('Drive type for {0}: {1}' -f $Letter, $_.Exception.Message) }
    return 'Unknown'
}

function Get-AfDriveList {
    <#
    .SYNOPSIS
        Fixed NTFS and ReFS drives with a letter: Letter, Media (SSD, HDD, Unknown),
        Size and Free in bytes. Read-only. Volume labels are left out (they can name people).
    #>
    [CmdletBinding()]
    param(
        [scriptblock] $GetVolumes = { Get-Volume -ErrorAction Stop },
        [scriptblock] $GetMedia = { param($Letter) Get-AfDriveMedia -Letter $Letter }
    )

    $drives = foreach ($v in @(& $GetVolumes)) {
        $letter = [string]$v.DriveLetter
        if (-not $letter.Trim() -or [string]$v.DriveType -ne 'Fixed' -or [string]$v.FileSystem -notin 'NTFS', 'ReFS') { continue }
        [pscustomobject]@{ Letter = $letter.Trim().ToUpperInvariant(); Media = [string](& $GetMedia $letter); Size = [long]$v.Size; Free = [long]$v.SizeRemaining }
    }
    return @($drives | Sort-Object Letter)
}

function Format-AfDefragLine {
    # defrag.exe names the drive by its label ("Invoking retrim on <label> (G:)...").
    # Labels can name people, so the label is dropped and only the letter is kept.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text)

    return [regex]::Replace($Text, '\bon\s+[^()\r\n]*?\s*\(([A-Za-z]):\)', 'on ($1:)')
}

function Get-AfDriveAction {
    # What a drive is offered. An SSD gets TRIM, never a defrag; a hard drive gets a
    # defrag; a drive Windows can't identify gets TRIM only, which is harmless.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Media)

    if ($Media -eq 'HDD') { return 'DEFRAG' }
    return 'TRIM'
}

function Get-AfTrimEnabled {
    # $true when Windows sends TRIM to NTFS drives, $false when someone turned it off, $null if unknown.
    [CmdletBinding()]
    param([scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList })

    try {
        $r = & $RunTool -Name 'fsutil.exe' -ArgumentList @('behavior', 'query', 'DisableDeleteNotify')
        $found = [regex]::Match((@($r.Lines) -join "`n"), '(?im)^\s*NTFS\s+DisableDeleteNotify\s*=\s*(\d)')
        if (-not $found.Success) { $found = [regex]::Match((@($r.Lines) -join "`n"), '(?i)DisableDeleteNotify\s*=\s*(\d)') }
        if ($found.Success) { return ($found.Groups[1].Value -eq '0') }
    }
    catch { Write-Verbose ('fsutil: {0}' -f $_.Exception.Message) }
    return $null
}

function Get-AfDefragTaskState {
    # Ready, Disabled and so on for Windows' weekly "Optimize Drives" task; $null if not found.
    [CmdletBinding()]
    param()

    try { return [string](Get-ScheduledTask -TaskPath $script:AfDefragTaskPath -TaskName $script:AfDefragTaskName -ErrorAction Stop).State }
    catch { return $null }
}

function Test-AfOnBattery {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try { return [bool](@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Where-Object { $_.BatteryStatus -eq 1 }).Count) }
    catch { return $false }
}

function Get-AfDriveLabel {
    param([Parameter(Mandatory)] $Drive)
    $type = @{ SSD = 'SSD'; HDD = 'Hard drive'; Unknown = 'Unknown type' }[$Drive.Media]
    $action = @{ TRIM = 'TRIM now'; DEFRAG = 'Defrag' }[(Get-AfDriveAction -Media $Drive.Media)]
    return ('{0}:  {1,-12} {2}' -f $Drive.Letter, $type, $action)
}

function Invoke-AfDriveOptimize {
    <#
    .SYNOPSIS
        TRIM or defrag one drive after a Y, with the progress panel, a redacted log
        and the time history. Returns Tag (OK, FAILED, STOPPED, CANCELLED) and Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Drive,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $RunStep = { param($FilePath, $Arguments, $EstimatedSeconds, $OnProgress, $OnMessage, $OnStall) Invoke-AfRepairProcess @PSBoundParameters -ActivityProbe { 'output only' } },
        [bool] $OnBattery = (Test-AfOnBattery)
    )

    $action = Get-AfDriveAction -Media $Drive.Media
    $key = $action
    $historyPath = Get-AfHistoryPath -OutputRoot $OutputRoot -Prepare
    $default = 120.0
    if ($action -eq 'DEFRAG') { $default = 1800.0 }
    $estimate = Get-AfRepairEstimate -Key $key -HistoryPath $historyPath -DefaultSeconds $default

    Write-Host ''
    if ($action -eq 'TRIM') {
        Write-Host ('  TRIM drive {0}: tells the SSD which blocks are free, so it stays fast.' -f $Drive.Letter) -ForegroundColor White
        Write-Host '  No files are moved or deleted. Windows does this weekly; this runs it now.'
        if ($Drive.Media -eq 'Unknown') { Write-Host '  Windows cannot tell what kind of drive this is, so defrag is not offered.' -ForegroundColor Yellow }
        $arguments = '{0}: /L /U /V' -f $Drive.Letter
    }
    else {
        Write-Host ('  Defrag drive {0}: puts the pieces of each file back together.' -f $Drive.Letter) -ForegroundColor White
        Write-Host '  No files are deleted. The PC stays usable but slower while it runs.'
        if ($OnBattery) { Write-Host '  This laptop is on battery. Plug it in first: a defrag can take a long time.' -ForegroundColor Yellow }
        $arguments = '{0}: /D /U /V' -f $Drive.Letter
    }
    Write-Host ('  Runs: defrag {0}   Expected: {1}' -f $arguments, (Format-AfApprox $estimate)) -ForegroundColor DarkGray
    if ((Read-AfYesNo -Prompt 'Start now?' -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return [pscustomobject]@{ Tag = 'CANCELLED'; Detail = 'Nothing was changed.' }
    }

    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'cleanup' -Redactor $redactor -Task ('optimize drive {0}: {1}' -f $Drive.Letter, $action)
    Write-AfToolLog $toolLog ('Drive     : {0}: {1}, {2} free of {3}' -f $Drive.Letter, $Drive.Media, (Format-AfSize $Drive.Free), (Format-AfSize $Drive.Size))
    Write-AfToolLog $toolLog ('Command   : defrag.exe {0}' -f $arguments)

    $progressTitle = @{ TRIM = 'TRIM'; DEFRAG = 'Defrag' }[$action]
    $progressName = '{0} drive {1}:' -f $progressTitle, $Drive.Letter
    $progressView = Open-AfProgressView -Title 'Optimizing drives' -Mode $Settings.Mode
    $onProgress = {
        param($Percent, $Known, $Elapsed, $Left, $Quiet)
        $label = '{0:0.0}%' -f $Percent
        if (-not $Known) { $label = '~{0:0}%, estimated by time' -f $Percent }
        $lines = @(
            ('{0} ({1})' -f $progressName, $label)
            ('Elapsed {0} | about {1} left | quiet for {2}' -f (Format-AfSpan $Elapsed), (Format-AfSpan $Left), (Format-AfSpan $Quiet))
        )
        Update-AfProgressView -View $progressView -Lines $lines -Percent $Percent
    }
    $onStall = { Close-AfProgressView -View $progressView; Read-AfStallChoice -ReadKey $ReadKey }
    Set-AfStayAwake $true
    try { $r = & $RunStep -FilePath (Get-AfSystemToolPath 'defrag.exe') -Arguments $arguments -EstimatedSeconds $estimate -OnProgress $onProgress -OnMessage { } -OnStall $onStall }
    finally {
        Set-AfStayAwake $false
        Close-AfProgressView -View $progressView
    }

    if ($r.Outcome -eq 'Stopped') { $tag = 'STOPPED'; $detail = 'Stopped after you chose S. Stopping part-way is safe; nothing is lost.' }
    elseif ($r.ExitCode -eq 0) { $tag = 'OK'; $detail = 'Finished.' }
    else {
        $tag = 'FAILED'
        $detail = 'defrag exit code {0}.' -f (Get-AfExitText -Code $r.ExitCode)
        $last = @($r.Messages | Where-Object { $_ }) | Select-Object -Last 1
        if ($last) { $detail += ' ' + (Format-AfDefragLine -Text $last) }
        if ($action -eq 'TRIM' -and $Drive.Media -eq 'Unknown') { $detail += ' This drive may not support TRIM. Nothing was changed.' }
    }
    if ($null -ne $r.ExitCode) { Add-AfRepairHistory -HistoryPath $historyPath -Key $key -Seconds $r.Seconds -ExitCode $r.ExitCode }
    Write-AfToolLog $toolLog ('{0,-7}{1}  {2}  ({3})' -f $tag, $progressName, $detail, (Format-AfSpan $r.Seconds))
    foreach ($m in @($r.Messages | Select-Object -Last 15)) { Write-AfToolLog $toolLog ('  {0}' -f (Format-AfDefragLine -Text $m)) }

    $color = @{ OK = 'Green'; FAILED = 'Red'; STOPPED = 'Yellow' }[$tag]
    Write-Host ''
    Write-Host ('  {0,-8}{1}  {2}  ({3})' -f $tag, $progressName, $detail, (Format-AfSpan $r.Seconds)) -ForegroundColor $color
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return [pscustomobject]@{ Tag = $tag; Detail = $detail }
}

function Set-AfTrimEnabled {
    # Technician only: turns TRIM back on for NTFS after a Y. Logged with the old value.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList }
    )

    Write-Host ''
    Write-Host '  Windows is not sending TRIM to SSDs (DisableDeleteNotify = 1).' -ForegroundColor White
    Write-Host '  This turns it back on:' -ForegroundColor White
    Write-Host '    fsutil behavior set DisableDeleteNotify 0' -ForegroundColor DarkGray
    Write-Host '  Undo: fsutil behavior set DisableDeleteNotify 1'
    if ((Read-AfYesNo -Prompt 'Turn TRIM on?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return $false }
    $r = & $RunTool -Name 'fsutil.exe' -ArgumentList @('behavior', 'set', 'DisableDeleteNotify', '0')
    $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'cleanup' -Redactor (New-AfRedactor) -Task 'turn TRIM back on'
    Write-AfToolLog $log ('Old value : DisableDeleteNotify = 1. fsutil exit code {0}' -f $r.ExitCode)
    if ($r.ExitCode -eq 0) { Write-Host '  OK      TRIM is on again.' -ForegroundColor Green; return $true }
    Write-Host ('  FAILED  fsutil exit code {0}.' -f (Get-AfExitText -Code $r.ExitCode)) -ForegroundColor Red
    return $false
}

function Enable-AfDefragTask {
    # Technician only: turns Windows' weekly Optimize Drives task back on after a Y.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $Enable = { Enable-ScheduledTask -TaskPath $script:AfDefragTaskPath -TaskName $script:AfDefragTaskName -ErrorAction Stop | Out-Null }
    )

    Write-Host ''
    Write-Host '  Windows'' weekly "Optimize Drives" task is turned off. This turns it back on,' -ForegroundColor White
    Write-Host '  so Windows TRIMs SSDs and defrags hard drives on its own again.'
    Write-Host '  Undo: Disable the same task in Task Scheduler.'
    if ((Read-AfYesNo -Prompt 'Turn it on?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return $false }
    $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'cleanup' -Redactor (New-AfRedactor) -Task 'turn the weekly Optimize Drives task back on'
    try {
        & $Enable
        Write-AfToolLog $log 'OK     Old state: Disabled. New state: enabled.'
        Write-Host '  OK      The weekly task is on again.' -ForegroundColor Green
        return $true
    }
    catch {
        Write-AfToolLog $log ('FAILED {0}' -f $_.Exception.Message)
        Write-Host ('  FAILED  {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Invoke-AfOptimizeMenu {
    # The Optimize drives screen, opened from Clean up.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default action script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $GetDrives = { Get-AfDriveList },
        [scriptblock] $GetTrim = { Get-AfTrimEnabled },
        [scriptblock] $GetTaskState = { Get-AfDefragTaskState },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        # Called with the drive.
        [scriptblock] $Optimize = { param($Drive) $null = Invoke-AfDriveOptimize -Drive $Drive -Settings $Settings -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $EnableTrim = { $null = Set-AfTrimEnabled -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $EnableTask = { $null = Enable-AfDefragTask -OutputRoot $OutputRoot -ReadKey $ReadKey }
    )

    $notice = $null
    while ($true) {
        $drives = @(& $GetDrives)
        $trim = & $GetTrim
        $task = & $GetTaskState
        $items = New-Object System.Collections.Generic.List[object]
        $itemInfo = @{}
        for ($i = 0; $i -lt $drives.Count; $i++) {
            $d = $drives[$i]
            $key = 'D{0}' -f $i
            $items.Add(@{ Key = $key; Label = (Get-AfDriveLabel -Drive $d); Tags = '[CHG]' })
            $what = @{
                TRIM   = 'Tells the SSD which blocks are free. Moves and deletes nothing.'
                DEFRAG = 'Puts file pieces back together. Deletes nothing. Can take hours.'
            }[(Get-AfDriveAction -Media $d.Media)]
            $itemInfo[$key] = @($what, '', ('Free: {0} of {1}' -f (Format-AfSize $d.Free), (Format-AfSize $d.Size)), '', 'Asks Y/N first.')
        }
        if ($Settings.Mode -eq 'Technician' -and $trim -eq $false) {
            $items.Add(@{ Key = 'E'; Label = 'Turn TRIM back &on'; Tags = '[CHG]' })
            $itemInfo['E'] = @('Windows is not sending TRIM to SSDs. This turns it back on.', '', 'Changes system: YES', 'Asks Y/N first.')
        }
        if ($Settings.Mode -eq 'Technician' -and $task -eq 'Disabled') {
            $items.Add(@{ Key = 'W'; Label = 'Turn the &weekly task back on'; Tags = '[CHG]' })
            $itemInfo['W'] = @('Windows'' own weekly Optimize Drives task is off. This turns it back on.', '', 'Changes system: YES', 'Asks Y/N first.')
        }
        if ($items.Count) { $items[$items.Count - 1].Divider = $true }
        $items.Add(@{ Key = 'B'; Label = '&Back' })
        $items.Add(@{ Key = 'Q'; Label = '&Quit' })
        $itemInfo['B'] = @('Back to Clean up.')
        $itemInfo['Q'] = @('Closes Auto-Fixer. Asks first.')

        $info = @('SSDs get TRIM; hard drives get a defrag. An SSD is never defragged.')
        if ($trim -eq $false -and $Settings.Mode -ne 'Technician') { $info += 'Windows TRIM is turned off on this PC. Technician mode can turn it back on.' }
        if (-not $drives.Count -and -not $notice) { $notice = 'No fixed NTFS or ReFS drives with a letter were found.' }

        $choice = Select-AfMenuItem -Title 'Optimize drives' -Items $items.ToArray() -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        if (-not $IsAdmin) { $notice = 'This needs administrator rights. Start Auto-Fixer with AutoFix.bat and answer Yes.'; continue }
        try {
            if ($choice -eq 'E') { & $EnableTrim }
            elseif ($choice -eq 'W') { & $EnableTask }
            else { & $Optimize $drives[[int]$choice.Substring(1)] }
        }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        Write-Host ''
        Write-Host '  Press any key to return.' -ForegroundColor DarkGray
        $null = & $ReadKey
    }
}
