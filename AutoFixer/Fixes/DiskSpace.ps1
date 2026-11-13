# Disk space (Clean up menu, plan 2026-11-11): how much of each fixed drive is used and free.
#   - read-only: nothing is changed, and volume labels are left out (they can name people)
#   - exact byte counts are shown too, to compare with a drive's Properties in Explorer
#   - a drive is low on space under 10% free, or the Windows drive under 15 GB free
# Reading drive sizes takes about a second, so there is no progress bar (the progress rule is for steps over 5 s).

$script:AfLowSpacePercent = 10
$script:AfLowSpaceSystemBytes = 15GB

function Test-AfLowSpace {
    # True when a drive is low on space: under 10% free, or the Windows drive under 15 GB free.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [long] $Size, [Parameter(Mandatory)] [long] $Free, [switch] $IsSystem)

    if ($Size -le 0) { return $false }
    if (($Free / [double]$Size) * 100 -lt $script:AfLowSpacePercent) { return $true }
    return ($IsSystem.IsPresent -and $Free -lt $script:AfLowSpaceSystemBytes)
}

function Get-AfDiskSpace {
    <#
    .SYNOPSIS
        Every fixed drive with a letter: Letter, Media (SSD, HDD, Unknown), FileSystem,
        Size, Used and Free in bytes, UsedPercent, IsSystem and Low. Read-only.
        Uses Get-Volume, and Windows' own drive list when Get-Volume is not available.
    #>
    [CmdletBinding()]
    param(
        [scriptblock] $GetVolumes = { Get-Volume -ErrorAction Stop },
        [scriptblock] $GetDrives = { [IO.DriveInfo]::GetDrives() },
        [scriptblock] $GetMedia = { param($Letter) Get-AfDriveMedia -Letter $Letter },
        [AllowEmptyString()] [string] $SystemDrive = $env:SystemDrive,
        # Leaves out the SSD or HDD check, which is the slow part (the Clean up menu line needs only sizes).
        [switch] $SkipMedia
    )

    $system = ([string]$SystemDrive).Trim().TrimEnd('\', ':').ToUpperInvariant()
    if (-not $system) { $system = 'C' }
    $found = [System.Collections.ArrayList]::new()
    try {
        foreach ($v in @(& $GetVolumes)) {
            $letter = ([string]$v.DriveLetter).Trim()
            if (-not $letter -or [string]$v.DriveType -ne 'Fixed') { continue }
            $null = $found.Add([pscustomobject]@{ Letter = $letter; FileSystem = [string]$v.FileSystem; Size = [long]$v.Size; Free = [long]$v.SizeRemaining })
        }
    }
    catch {
        Write-Verbose ('Get-Volume: {0}. Using the drive list instead.' -f $_.Exception.Message)
        $found.Clear()
        foreach ($d in @(& $GetDrives)) {
            if ([string]$d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
            $null = $found.Add([pscustomobject]@{ Letter = ([string]$d.Name).Substring(0, 1); FileSystem = [string]$d.DriveFormat; Size = [long]$d.TotalSize; Free = [long]$d.TotalFreeSpace })
        }
    }

    $drives = foreach ($f in $found) {
        # A drive with no size (not formatted, or not ready) has nothing to show.
        if ($f.Size -le 0) { continue }
        $letter = $f.Letter.ToUpperInvariant()
        $free = [math]::Min([math]::Max([long]0, $f.Free), $f.Size)
        $used = $f.Size - $free
        $isSystem = ($letter -eq $system)
        $media = ''
        if (-not $SkipMedia) { $media = [string](& $GetMedia $letter) }
        [pscustomobject]@{
            Letter = $letter; Media = $media; FileSystem = $f.FileSystem
            Size = $f.Size; Used = $used; Free = $free
            UsedPercent = [math]::Round(($used / [double]$f.Size) * 100, 1)
            IsSystem = $isSystem
            Low = (Test-AfLowSpace -Size $f.Size -Free $free -IsSystem:$isSystem)
        }
    }
    return @($drives | Sort-Object Letter)
}

function Format-AfExactBytes {
    # 381012345600 -> '381,012,345,600'. The same on every PC, whatever its number format.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Bytes)

    if ($null -eq $Bytes) { return 'not known' }
    return ([long]$Bytes).ToString('N0', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-AfUsageBar {
    # [########--] for 80% used.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [double] $Percent, [int] $Width = 10)

    $filled = [int][math]::Round([math]::Min(100, [math]::Max(0, $Percent)) / 100 * $Width)
    return ('[{0}{1}]' -f ('#' * $filled), ('-' * ($Width - $filled)))
}

function Format-AfPercent {
    # 80.04 -> '80%', 0.4 -> '0.4%': small values keep one decimal so a nearly full drive never reads 100%.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [double] $Percent)

    if ($Percent -gt 0 -and $Percent -lt 1) { return ('{0}%' -f $Percent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)) }
    if ($Percent -gt 99 -and $Percent -lt 100) { return ('{0}%' -f $Percent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)) }
    return ('{0}%' -f [math]::Round($Percent).ToString([Globalization.CultureInfo]::InvariantCulture))
}

function Format-AfDiskSpaceLine {
    # One line for the Clean up menu: 'Windows drive C: 95.3 GB free of 476 GB (80% used).'
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]] $Drives)

    $sys = @($Drives | Where-Object { $_.IsSystem })[0]
    if (-not $sys) { return 'Windows drive: size not known.' }
    $line = 'Windows drive {0}: {1} free of {2} ({3} used).' -f $sys.Letter, (Format-AfSize $sys.Free), (Format-AfSize $sys.Size), (Format-AfPercent $sys.UsedPercent)
    if ($sys.Low) { $line += ' Low on space.' }
    return $line
}

function Get-AfDiskSpaceText {
    <#
    .SYNOPSIS
        The Disk space screen as lines: Text and Color. The same lines go to the log.
    #>
    [CmdletBinding()]
    param([object[]] $Drives)

    $out = [System.Collections.ArrayList]::new()
    $add = { param($Text, $Color = 'Gray') $null = $out.Add([pscustomobject]@{ Text = $Text; Color = $Color }) }
    $Drives = @($Drives | Where-Object { $_ })
    if ($Drives.Count -eq 0) {
        & $add 'No fixed drives with a letter were found.' 'Yellow'
        return $out.ToArray()
    }
    $row = '{0,-6}{1,-8}{2,10}  {3,-17}{4,-17}{5}'
    & $add ($row -f 'Drive', 'Type', 'Size', 'Used', 'Free', '') 'DarkCyan'
    foreach ($d in $Drives) {
        $name = '{0}:' -f $d.Letter
        if ($d.IsSystem) { $name += '*' }
        $media = $d.Media
        if (-not $media) { $media = '-' }
        $used = '{0} ({1})' -f (Format-AfSize $d.Used), (Format-AfPercent $d.UsedPercent)
        $free = '{0} ({1})' -f (Format-AfSize $d.Free), (Format-AfPercent (100 - $d.UsedPercent))
        $color = 'Gray'
        if ($d.Low) { $color = 'Yellow' }
        & $add ($row -f $name, $media, (Format-AfSize $d.Size), $used, $free, (Format-AfUsageBar $d.UsedPercent)) $color
    }
    if ($Drives.Count -gt 1) {
        $size = [long]0; $usedSum = [long]0; $freeSum = [long]0
        foreach ($d in $Drives) { $size += $d.Size; $usedSum += $d.Used; $freeSum += $d.Free }
        $pct = ($usedSum / [double]$size) * 100
        & $add ($row -f 'Total', '', (Format-AfSize $size), ('{0} ({1})' -f (Format-AfSize $usedSum), (Format-AfPercent $pct)), ('{0} ({1})' -f (Format-AfSize $freeSum), (Format-AfPercent (100 - $pct))), '') 'White'
    }
    & $add '* = the Windows drive.' 'DarkGray'
    & $add ''
    & $add 'Exact numbers, in bytes:' 'DarkCyan'
    $exact = '{0,-6}{1,22}{2,22}{3,22}'
    & $add ($exact -f 'Drive', 'Used', 'Free', 'Size') 'DarkCyan'
    foreach ($d in $Drives) { & $add ($exact -f ('{0}:' -f $d.Letter), (Format-AfExactBytes $d.Used), (Format-AfExactBytes $d.Free), (Format-AfExactBytes $d.Size)) }
    $low = @($Drives | Where-Object { $_.Low })
    if ($low.Count -gt 0) { & $add '' }
    foreach ($d in $low) {
        $why = 'under {0}% free' -f $script:AfLowSpacePercent
        if ($d.IsSystem -and $d.Free -lt $script:AfLowSpaceSystemBytes) { $why = 'Windows updates need about {0:0} GB free' -f ($script:AfLowSpaceSystemBytes / 1GB) }
        & $add ('WARNING  {0}: is low on space: {1} free ({2}).' -f $d.Letter, (Format-AfSize $d.Free), $why) 'Warning'
    }
    if (@($low | Where-Object { $_.IsSystem }).Count -gt 0) { & $add 'Disk Cleanup (D in this menu) can free space on the Windows drive.' 'Yellow' }
    return $out.ToArray()
}

function Show-AfDiskSpace {
    <#
    .SYNOPSIS
        The Disk space screen: used and free on every fixed drive, with exact bytes.
        Read-only. Writes the same lines to a log in this PC's folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $GetSpace = { Get-AfDiskSpace }
    )

    Write-Host ''
    Write-Host '  Disk space on this PC (fixed drives). Read-only: nothing is changed.' -ForegroundColor Cyan
    Write-Host ''
    $drives = @()
    try { $drives = @(& $GetSpace) }
    catch {
        Write-Host ('  Could not read the drives: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return @()
    }
    $lines = @(Get-AfDiskSpaceText -Drives $drives)
    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'diskspace' -Redactor $redactor -Task 'Disk space'
    foreach ($l in $lines) {
        if ($l.Color -eq 'Warning') { Write-Host ('  {0}' -f $l.Text) -ForegroundColor Black -BackgroundColor Yellow }
        else { Write-Host ('  {0}' -f $l.Text) -ForegroundColor $l.Color }
        Write-AfToolLog $toolLog $l.Text
    }
    Write-Host ''
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return $drives
}
