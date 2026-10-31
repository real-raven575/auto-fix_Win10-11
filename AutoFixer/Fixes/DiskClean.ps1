# Disk Cleanup from the menu (Clean up, plan 2026-10-30): your files and system files,
# run by Windows' own cleanmgr.exe.
#   - sizes and tick boxes first; nothing is removed until the user answers Y
#   - only items with no warning are ticked by default; items that lose something
#     (Recycle Bin, Downloads, going back to the old Windows) ask again by name
#   - error reports, crash dumps and setup logs are locked: the scan reads them
#     (source-log rule, 2026-10-24), so only a future Advanced technician area may clear them
#   - the choices go into our own StateFlags slot, so the user's own saved Disk
#     Cleanup choices stay untouched, and the slot is always emptied afterwards

$script:AfVolumeCachesPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
$script:AfCleanFirstSlot = 42
$script:AfCleanMarkerPath = $(if ($env:ProgramData) { Join-Path $env:ProgramData 'AutoFixer\cleanmgr-slot.txt' } else { $null })
$script:AfCleanLocked = 'Locked: Auto-Fixer reads these to find problems, so it never removes them.'
$script:AfCleanSystem = 'System files (administrator)'

# Disk Cleanup's own items, by registry key name. Name is what the screen shows.
# Default = ticked at the start. Warn 1 = a note to read; Warn 2 = asks again by name.
$script:AfCleanRules = @{
    'Active Setup Temp Folders'                    = @{ Name = 'Active Setup temporary folders'; Default = $true }
    'BranchCache'                                  = @{ Name = 'BranchCache'; Group = $script:AfCleanSystem }
    'Content Indexer Cleaner'                      = @{ Name = 'Search catalog leftovers' }
    'D3D Shader Cache'                             = @{ Name = 'DirectX Shader Cache'; Default = $true; Note = 'Games and apps rebuild it; the first start may be slower.' }
    'Delivery Optimization Files'                  = @{ Name = 'Delivery Optimization Files'; Default = $true; Group = $script:AfCleanSystem }
    'Device Driver Packages'                       = @{ Name = 'Device driver packages'; Group = $script:AfCleanSystem; Locked = 'Locked: Disk Cleanup keeps no copy of old drivers. A later Auto-Fixer step backs them up first.' }
    'Diagnostic Data Viewer database files'        = @{ Name = 'Diagnostic Data Viewer files' }
    'Downloaded Program Files'                     = @{ Name = 'Downloaded Program Files'; Default = $true }
    'DownloadsFolder'                              = @{ Name = 'Downloads folder'; Warn = 2; Note = 'Deletes EVERYTHING in your Downloads folder, for good.' }
    'Feedback Hub Archive log files'               = @{ Name = 'Feedback Hub archive logs' }
    'Internet Cache Files'                         = @{ Name = 'Temporary Internet Files'; Default = $true }
    'Language Pack'                                = @{ Name = 'Unused language files'; Group = $script:AfCleanSystem; Warn = 1; Note = 'Removes languages and keyboards not in use; add them back in Settings.' }
    'Offline Pages Files'                          = @{ Name = 'Offline webpages' }
    'Old ChkDsk Files'                             = @{ Name = 'Old Chkdsk files'; Group = $script:AfCleanSystem }
    'Previous Installations'                       = @{ Name = 'Previous Windows installation(s)'; Group = $script:AfCleanSystem; Warn = 2; Note = 'You can no longer go back to the earlier version of Windows.' }
    'Recycle Bin'                                  = @{ Name = 'Recycle Bin'; Warn = 2; Note = 'Files in the Recycle Bin are deleted for good.' }
    'RetailDemo Offline Content'                   = @{ Name = 'Store demo content'; Group = $script:AfCleanSystem }
    'Service Pack Cleanup'                         = @{ Name = 'Service Pack backup files'; Group = $script:AfCleanSystem; Warn = 1; Note = 'Installed service packs can no longer be removed.' }
    'Setup Log Files'                              = @{ Name = 'Windows setup log files'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'System error memory dump files'               = @{ Name = 'System error memory dump files'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'System error minidump files'                  = @{ Name = 'System error minidump files'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Temporary Files'                              = @{ Name = 'Temporary files'; Default = $true; Note = 'Windows removes only temporary files not used for 7 days.' }
    'Temporary Setup Files'                        = @{ Name = 'Temporary Setup Files'; Default = $true; Group = $script:AfCleanSystem }
    'Temporary Sync Files'                         = @{ Name = 'Temporary sync files' }
    'Thumbnail Cache'                              = @{ Name = 'Thumbnails'; Default = $true; Note = 'Windows rebuilds them when folders are opened.' }
    'Update Cleanup'                               = @{ Name = 'Windows Update Cleanup'; Group = $script:AfCleanSystem; Warn = 1; Note = 'Installed updates can no longer be uninstalled. Can take a long time.' }
    'Upgrade Discarded Files'                      = @{ Name = 'Windows upgrade leftover files'; Group = $script:AfCleanSystem }
    'User file versions'                           = @{ Name = 'File History versions'; Warn = 2; Note = 'Deletes older backup copies made by File History.' }
    'Windows Defender'                             = @{ Name = 'Microsoft Defender (non-critical files)'; Group = $script:AfCleanSystem }
    'Windows Error Reporting Files'                = @{ Name = 'Windows error reports'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows Error Reporting Archive Files'        = @{ Name = 'Windows error reports (archived)'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows Error Reporting Queue Files'          = @{ Name = 'Windows error reports (queued)'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows Error Reporting System Archive Files' = @{ Name = 'System error reports (archived)'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows Error Reporting System Queue Files'   = @{ Name = 'System error reports (queued)'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows Error Reporting Temp Files'           = @{ Name = 'Error reporting temporary files'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows ESD installation files'               = @{ Name = 'Windows ESD installation files'; Group = $script:AfCleanSystem; Warn = 2; Note = '"Reset this PC" may then need to download Windows.' }
    'Windows Reset Log Files'                      = @{ Name = 'Windows reset log files'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
    'Windows Upgrade Log Files'                    = @{ Name = 'Windows upgrade log files'; Group = $script:AfCleanSystem; Locked = $script:AfCleanLocked }
}

function Get-AfCleanMeasureSpec {
    # Folders the tool can measure for an item; empty when the size is not known.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)

    $windows = $env:windir
    if (-not $windows) { $windows = 'C:\Windows' }
    $system = $env:SystemDrive
    if (-not $system) { $system = 'C:' }
    # Text joins: a missing variable gives a path that does not exist, measured as 0.
    $local = [string]$env:LOCALAPPDATA
    $userProfile = [string]$env:USERPROFILE
    switch ($Key) {
        'Temporary Files' { return @(@{ Path = $env:TEMP; OlderThanDays = 7 }, @{ Path = ('{0}\Temp' -f $windows); OlderThanDays = 7 }) }
        'Thumbnail Cache' { return @(@{ Path = ('{0}\Microsoft\Windows\Explorer' -f $local); Filter = 'thumbcache_*.db'; NoRecurse = $true }) }
        'Internet Cache Files' { return @(@{ Path = ('{0}\Microsoft\Windows\INetCache' -f $local) }) }
        'D3D Shader Cache' { return @(@{ Path = ('{0}\D3DSCache' -f $local) }) }
        'Delivery Optimization Files' { return @(@{ Path = ('{0}\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache' -f $windows) }) }
        'Downloaded Program Files' { return @(@{ Path = ('{0}\Downloaded Program Files' -f $windows) }) }
        'Previous Installations' { return @(@{ Path = ('{0}\Windows.old' -f $system) }) }
        'Recycle Bin' { return @(@{ Path = ('{0}\$Recycle.Bin' -f $system) }) }
        'DownloadsFolder' { return @(@{ Path = ('{0}\Downloads' -f $userProfile) }) }
    }
    return @()
}

function Measure-AfFolder {
    <#
    .SYNOPSIS
        Total bytes of the files in a folder. Skips junctions and links so nothing is
        counted twice, and folders it can't read. 0 when the folder is missing.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [AllowEmptyString()] [string] $Path,
        [string] $Filter = '*',
        [int] $OlderThanDays = 0,
        [switch] $NoRecurse
    )

    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return [long]0 }
    $cutoff = [datetime]::MaxValue
    if ($OlderThanDays -gt 0) { $cutoff = (Get-Date).AddDays(-$OlderThanDays) }
    $total = [long]0
    $folders = New-Object System.Collections.Generic.Stack[string]
    $folders.Push($Path)
    while ($folders.Count) {
        $folder = $folders.Pop()
        try {
            $dir = New-Object IO.DirectoryInfo $folder
            foreach ($file in $dir.GetFiles($Filter)) {
                if ($file.LastWriteTime -lt $cutoff) { $total += $file.Length }
            }
            if ($NoRecurse) { continue }
            foreach ($sub in $dir.GetDirectories()) {
                if (-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $folders.Push($sub.FullName) }
            }
        }
        catch { Write-Verbose ('Not readable: {0}' -f $_.Exception.Message) }
    }
    return $total
}

function Measure-AfCleanItem {
    # Bytes for one Disk Cleanup item, or $null when the tool can't measure it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key)

    $specs = @(Get-AfCleanMeasureSpec -Key $Key)
    if (-not $specs.Count) { return $null }
    $total = [long]0
    foreach ($s in $specs) {
        $filter = '*'
        if ($s.Filter) { $filter = $s.Filter }
        $total += Measure-AfFolder -Path $s.Path -Filter $filter -OlderThanDays ([int]$s.OlderThanDays) -NoRecurse:([bool]$s.NoRecurse)
    }
    return $total
}

function Get-AfCleanItem {
    <#
    .SYNOPSIS
        One tick-box item per Disk Cleanup handler on this PC, grouped Your files,
        System files, then Other. Unknown handlers are listed, never ticked, with a note.
    #>
    [CmdletBinding()]
    param(
        # Registry key names under VolumeCaches.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Handlers,
        [scriptblock] $Measure = { param($Key) Measure-AfCleanItem -Key $Key },
        # Called before each item is measured, with its number, the count and its name,
        # so the screen can show progress while large folders are added up.
        [scriptblock] $OnItem = { }
    )

    $order = @{ 'Your files' = 0; $script:AfCleanSystem = 1; 'Other Windows items' = 2 }
    $number = 0
    $items = foreach ($key in $Handlers) {
        $number++
        $rule = $script:AfCleanRules[$key]
        if (-not $rule) { $rule = @{ Name = $key; Group = 'Other Windows items'; Warn = 1; Note = 'Not on Auto-Fixer''s list of known items. Windows decides what it removes.' } }
        $group = 'Your files'
        if ($rule.Group) { $group = $rule.Group }
        $warn = 0
        if ($rule.Warn) { $warn = [int]$rule.Warn }
        & $OnItem $number $Handlers.Count ([string]$rule.Name)
        $size = $null
        if (-not $rule.Locked) { $size = & $Measure $key }
        @{
            Key = $key; Label = $rule.Name; Group = $group; Size = $size; Warn = $warn; Note = $rule.Note; Locked = $rule.Locked
            Checked = ([bool]$rule.Default -and -not $rule.Locked -and $warn -eq 0)
        }
    }
    return @($items | Sort-Object { $order[$_.Group] }, { $_.Label })
}

function Get-AfCleanRegistry {
    # The three registry steps Disk Cleanup needs. Tests pass their own.
    return @{
        Get    = { param($Path, $Name) (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name }
        Set    = { param($Path, $Name, $Value) $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop }
        Remove = { param($Path, $Name) Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
    }
}

function Get-AfCleanSlotName {
    param([Parameter(Mandatory)] [int] $Slot)
    return ('StateFlags{0:0000}' -f $Slot)
}

function Find-AfCleanSlot {
    # The first slot from 42 that no handler uses, so the user's own saved choices
    # (written by cleanmgr /sageset) are never changed. $null if none is free.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Handlers,
        [Parameter(Mandatory)] [hashtable] $Registry
    )

    for ($slot = $script:AfCleanFirstSlot; $slot -le 9999; $slot++) {
        $name = Get-AfCleanSlotName $slot
        $used = $false
        foreach ($h in $Handlers) {
            if ($null -ne (& $Registry.Get ('{0}\{1}' -f $script:AfVolumeCachesPath, $h) $name)) { $used = $true; break }
        }
        if (-not $used) { return $slot }
    }
    return $null
}

function Clear-AfCleanSlot {
    # Removes our StateFlags value from every handler.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Slot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Handlers,
        [Parameter(Mandatory)] [hashtable] $Registry
    )

    $name = Get-AfCleanSlotName $Slot
    foreach ($h in $Handlers) { & $Registry.Remove ('{0}\{1}' -f $script:AfVolumeCachesPath, $h) $name }
}

function Get-AfFreeBytes {
    # Free space on the Windows drive.
    [CmdletBinding()]
    param()

    $system = $env:SystemDrive
    if (-not $system) { $system = 'C:' }
    try { return [long](New-Object IO.DriveInfo $system).AvailableFreeSpace } catch { return $null }
}

function Get-AfCleanActivity {
    # cleanmgr prints nothing; its CPU time and the free space show it is working.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $cpu = 0
    foreach ($p in @(Get-Process -Name 'cleanmgr', 'dismhost', 'TiWorker' -ErrorAction SilentlyContinue)) {
        try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { Write-Verbose 'No CPU time for this process.' }
    }
    return ('{0}|{1}' -f [math]::Floor($cpu), [math]::Floor([double](Get-AfFreeBytes) / 1MB))
}

function Invoke-AfDiskCleanup {
    <#
    .SYNOPSIS
        The Disk Cleanup screen: sizes, tick boxes, a preview and Y/N, then
        cleanmgr /sagerun with our own slot, emptied again afterwards whatever happens.
        Returns Tag (OK, FAILED, STOPPED, CANCELLED, QUIT) and the bytes freed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $GetHandlers = { @(Get-ChildItem -LiteralPath $script:AfVolumeCachesPath -ErrorAction Stop | ForEach-Object { $_.PSChildName }) },
        [scriptblock] $Measure = { param($Key) Measure-AfCleanItem -Key $Key },
        [hashtable] $Registry = (Get-AfCleanRegistry),
        [scriptblock] $RunStep = { param($FilePath, $Arguments, $EstimatedSeconds, $OnProgress, $OnMessage, $OnStall) Invoke-AfRepairProcess @PSBoundParameters -ActivityProbe { Get-AfCleanActivity } },
        [scriptblock] $GetFree = { Get-AfFreeBytes },
        [AllowNull()] [string] $MarkerPath = $script:AfCleanMarkerPath,
        [bool] $IsAdmin = (Test-AfIsAdmin),
        # Called between screens; tests pass { }.
        [scriptblock] $ClearScreen = { Clear-AfScreen; Show-AfBanner -Mode $Settings.Mode }
    )

    $none = [pscustomobject]@{ Tag = 'CANCELLED'; Freed = $null }
    if (-not $IsAdmin) {
        Write-Host ''
        Write-Host '  Disk Cleanup needs administrator rights.' -ForegroundColor Yellow
        Write-Host '  Start Auto-Fixer with AutoFix.bat and answer Yes to the Windows prompt.' -ForegroundColor Yellow
        return $none
    }
    $handlers = @(& $GetHandlers)

    # A run that was closed part-way can leave its slot behind; empty it first.
    if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) {
        $old = 0
        if ([int]::TryParse(([string](Get-Content -LiteralPath $MarkerPath -TotalCount 1)).Trim(), [ref]$old) -and $old -ge $script:AfCleanFirstSlot) {
            Clear-AfCleanSlot -Slot $old -Handlers $handlers -Registry $Registry
            Write-Host ('  Cleared the Disk Cleanup choices left by an earlier run that did not finish (slot {0}).' -f $old) -ForegroundColor DarkGray
        }
        Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host '  Measuring what each item would free. Large folders can take a minute...' -ForegroundColor DarkGray
    $measureView = Open-AfProgressView -Title 'Measuring Disk Cleanup items' -Mode $Settings.Mode
    $measureStart = Get-Date
    $onItem = {
        param($Number, $Count, $Name)
        $lines = @(
            ('Item {0} of {1}: {2}' -f $Number, $Count, $Name)
            ('Elapsed {0}' -f (Format-AfSpan ((Get-Date) - $measureStart).TotalSeconds))
        )
        Update-AfProgressView -View $measureView -Lines $lines -Percent (100.0 * ($Number - 1) / [math]::Max(1, $Count))
    }
    try { $items = @(Get-AfCleanItem -Handlers $handlers -Measure $Measure -OnItem $onItem) }
    finally { Close-AfProgressView -View $measureView }
    if (-not $items.Count) {
        Write-Host '  Disk Cleanup has no items on this PC.' -ForegroundColor Yellow
        return $none
    }
    $picked = Select-AfCheckList -Title 'Disk Cleanup' -Items $items -Mode $Settings.Mode -ReadKey $ReadKey `
        -Info @('Tick what to remove. Sizes are for the Windows drive.')
    if ($picked.Action -eq 'Quit') { $script:AfQuitRequested = $true; return [pscustomobject]@{ Tag = 'QUIT'; Freed = $null } }
    if ($picked.Action -ne 'Continue') { return $none }
    & $ClearScreen

    # Each item that loses something asks again by name; No leaves just that item out.
    $chosen = New-Object System.Collections.Generic.List[object]
    foreach ($item in $picked.Items) {
        if ($item.Warn -ge 2) {
            Write-Host ''
            Write-Host ('  {0}: {1}' -f $item.Label, $item.Note) -ForegroundColor Yellow
            if ((Read-AfYesNo -Prompt ('Remove {0} anyway?' -f $item.Label) -ReadKey $ReadKey) -ne $true) {
                Write-Host ('  {0} is left out.' -f $item.Label) -ForegroundColor DarkGray
                continue
            }
        }
        $chosen.Add($item)
    }
    if (-not $chosen.Count) { Write-Host '  Nothing is left to remove. Nothing was changed.' -ForegroundColor Yellow; return $none }

    $total = Get-AfCheckListTotal -Items $chosen.ToArray()
    Write-Host ''
    Write-Host '  Disk Cleanup will remove:' -ForegroundColor White
    foreach ($item in $chosen) { Write-Host ('    {0,-44} {1,10}' -f $item.Label, (Format-AfSize $item.Size)) }
    $sum = 'About {0}' -f (Format-AfSize $total.Bytes)
    if ($total.Unknown) { $sum += ', plus {0} item(s) Windows measures as it goes' -f $total.Unknown }
    Write-Host ('  {0}.' -f $sum) -ForegroundColor Green
    Write-Host '  Removed files cannot be put back.' -ForegroundColor Yellow
    Write-Host '  Windows shows its own small Disk Cleanup window while it works; leave it open.'
    if ((Read-AfYesNo -Prompt 'Run Disk Cleanup now?' -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return $none
    }

    $slot = Find-AfCleanSlot -Handlers $handlers -Registry $Registry
    if ($null -eq $slot) { Write-Host '  No free Disk Cleanup slot. Nothing was changed.' -ForegroundColor Red; return [pscustomobject]@{ Tag = 'FAILED'; Freed = $null } }
    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'cleanup' -Redactor $redactor -Task 'Disk Cleanup'
    foreach ($item in $chosen) { Write-AfToolLog $toolLog ('Ticked    : {0} ({1})' -f $item.Label, (Format-AfSize $item.Size)) }
    Write-AfToolLog $toolLog ('Command   : cleanmgr.exe /sagerun:{0}' -f $slot)
    $historyPath = Get-AfHistoryPath -OutputRoot $OutputRoot -Prepare
    $estimate = Get-AfRepairEstimate -Key 'DISKCLEAN' -HistoryPath $historyPath -DefaultSeconds 300
    $freeBefore = & $GetFree

    $progressView = $null
    $r = $null
    $name = Get-AfCleanSlotName $slot
    try {
        if ($MarkerPath) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $MarkerPath) -Force
            Set-Content -LiteralPath $MarkerPath -Value $slot -Encoding ASCII
        }
        foreach ($item in $chosen) { & $Registry.Set ('{0}\{1}' -f $script:AfVolumeCachesPath, $item.Key) $name 2 }
        $progressView = Open-AfProgressView -Title 'Disk Cleanup' -Mode $Settings.Mode
        $onProgress = {
            param($Percent, $Known, $Elapsed, $Left, $Quiet)
            # cleanmgr never prints a %, so Known is always false here.
            $null = $Known
            $lines = @(
                ('Disk Cleanup ({0} items, ~{1:0}%, time-based: Disk Cleanup shows no %)' -f $chosen.Count, $Percent)
                ('Elapsed {0} | about {1} left | no activity for {2}' -f (Format-AfSpan $Elapsed), (Format-AfSpan $Left), (Format-AfSpan $Quiet))
            )
            Update-AfProgressView -View $progressView -Lines $lines -Percent $Percent
        }
        $onStall = { Close-AfProgressView -View $progressView; Read-AfStallChoice -ReadKey $ReadKey }
        Set-AfStayAwake $true
        $r = & $RunStep -FilePath (Get-AfSystemToolPath 'cleanmgr.exe') -Arguments ('/sagerun:{0}' -f $slot) -EstimatedSeconds $estimate -OnProgress $onProgress -OnMessage { } -OnStall $onStall
    }
    finally {
        Set-AfStayAwake $false
        Close-AfProgressView -View $progressView
        Clear-AfCleanSlot -Slot $slot -Handlers $handlers -Registry $Registry
        if ($MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue }
    }

    $freeAfter = & $GetFree
    $freed = $null
    if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freed = [math]::Max([long]0, [long]$freeAfter - [long]$freeBefore) }
    if ($r.Outcome -eq 'Stopped') { $tag = 'STOPPED'; $detail = 'Stopped after you chose S. What was already removed stays removed.' }
    elseif ($r.ExitCode -eq 0) { $tag = 'OK'; $detail = 'Finished.' }
    else { $tag = 'FAILED'; $detail = 'cleanmgr exit code {0}.' -f (Get-AfExitText -Code $r.ExitCode) }
    if ($null -ne $r.ExitCode) { Add-AfRepairHistory -HistoryPath $historyPath -Key 'DISKCLEAN' -Seconds $r.Seconds -ExitCode $r.ExitCode }
    $freedText = 'not known'
    if ($null -ne $freed) { $freedText = Format-AfSize $freed }

    Write-AfToolLog $toolLog ('{0,-7}Disk Cleanup  {1}  ({2})' -f $tag, $detail, (Format-AfSpan $r.Seconds))
    Write-AfToolLog $toolLog ('Free space: before {0}, after {1}, freed {2}' -f (Format-AfSize $freeBefore), (Format-AfSize $freeAfter), $freedText)
    Write-AfToolLog $toolLog ('Slot      : {0} emptied again' -f $name)
    $color = @{ OK = 'Green'; FAILED = 'Red'; STOPPED = 'Yellow' }[$tag]
    Write-Host ''
    Write-Host ('  {0,-8}Disk Cleanup  {1}  ({2})' -f $tag, $detail, (Format-AfSpan $r.Seconds)) -ForegroundColor $color
    Write-Host ('  Free space on the Windows drive: before {0}, after {1}. Freed: {2}.' -f (Format-AfSize $freeBefore), (Format-AfSize $freeAfter), $freedText)
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return [pscustomobject]@{ Tag = $tag; Freed = $freed }
}
