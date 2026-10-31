# The tick-box screen shared by the Clean up tools: Disk Cleanup now, the browser
# cleaner next. The user ticks items, sees the total, and nothing is removed here;
# the caller shows its own preview and asks Y/N after Enter.

function Format-AfSize {
    # 0 B, 12 KB, 3.4 MB, 1.2 GB. $null means the size is not known.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Bytes)

    if ($null -eq $Bytes) { return 'size not known' }
    $value = [double]$Bytes
    if ($value -lt 1024) { return ('{0:0} B' -f $value) }
    foreach ($unit in 'KB', 'MB', 'GB', 'TB') {
        $value = $value / 1024
        if ($value -lt 1024 -or $unit -eq 'TB') {
            if ($value -ge 100) { return ('{0:0} {1}' -f $value, $unit) }
            return ('{0:0.0} {1}' -f $value, $unit).Replace(',', '.')
        }
    }
}

function Get-AfCheckListTotal {
    # The ticked items' known bytes, and how many ticked items have no known size.
    [CmdletBinding()]
    param([object[]] $Items = @())

    $bytes = [long]0
    $unknown = 0
    foreach ($item in @($Items | Where-Object { $_.Checked })) {
        if ($null -eq $item.Size) { $unknown++ } else { $bytes += [long]$item.Size }
    }
    return [pscustomobject]@{ Bytes = $bytes; Unknown = $unknown }
}

function Select-AfCheckList {
    <#
    .SYNOPSIS
        Shows a list of tick boxes and returns Action (Continue, Back or Quit) and
        the ticked Items. Space or an item's number (1 to 9) ticks and unticks;
        A ticks every item without a warning, N unticks all, Enter continues.
        Items with Warn are never ticked by A. Locked items show why and can't be
        ticked. Each item: @{ Key; Label; Size (bytes or $null); Checked; Warn
        (0, 1 or 2); Locked (the reason, or empty); Group (a heading, optional) }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        # Lines shown above the list.
        [string[]] $Info = @(),
        [string] $Mode = 'Standard',
        # How many item rows fit under the banner in 25 rows; the list scrolls past this.
        [int] $PageRows = 8,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $index = 0
    $top = 0
    $notice = $null
    while ($true) {
        Clear-AfScreen
        Show-AfBanner -Mode $Mode
        Write-Host ('  {0}' -f $Title) -ForegroundColor White
        foreach ($line in $Info) { Write-Host ('  {0}' -f $line) -ForegroundColor Gray }
        if ($index -lt $top) { $top = $index }
        if ($index -ge $top + $PageRows) { $top = $index - $PageRows + 1 }
        if ($top -gt 0) { Write-Host '      ... more above' -ForegroundColor DarkGray }
        $group = $null
        for ($i = $top; $i -lt [math]::Min($Items.Count, $top + $PageRows); $i++) {
            $item = $Items[$i]
            if ($item.Group -and $item.Group -ne $group) {
                $group = $item.Group
                Write-Host ('  {0}' -f $group) -ForegroundColor Cyan
            }
            $marker = ' '
            $color = 'Gray'
            if ($i -eq $index) { $marker = '>'; $color = 'White' }
            $box = '[ ]'
            if ($item.Checked) { $box = '[x]' }
            if ($item.Locked) { $box = '[-]'; if ($i -ne $index) { $color = 'DarkGray' } }
            $number = '  '
            if ($i -lt 9) { $number = '{0} ' -f ($i + 1) }
            $flag = '  '
            if ($item.Warn -ge 2) { $flag = '!!' } elseif ($item.Warn -ge 1) { $flag = '! ' }
            $label = [string]$item.Label
            if ($label.Length -gt 44) { $label = $label.Substring(0, 41) + '...' }
            $size = Format-AfSize $item.Size
            if ($null -eq $item.Size) { $size = 'size ?' }
            if ($item.Locked) { $size = 'locked' }
            $flagColor = $color
            if ($item.Warn -ge 1 -and -not $item.Locked) { $flagColor = 'Yellow' }
            Write-Host ('  {0} {1}{2} ' -f $marker, $number, $box) -ForegroundColor $color -NoNewline
            Write-Host ('{0,-44} ' -f $label) -ForegroundColor $color -NoNewline
            Write-Host $flag -ForegroundColor $flagColor -NoNewline
            Write-Host (' {0,10}' -f $size) -ForegroundColor $color
        }
        if ($top + $PageRows -lt $Items.Count) { Write-Host '      ... more below' -ForegroundColor DarkGray }

        $current = $Items[$index]
        if ($current.Locked) { Write-Host ('  {0}' -f $current.Locked) -ForegroundColor DarkGray }
        elseif ($current.Note) { Write-Host ('  {0}' -f $current.Note) -ForegroundColor Yellow }
        else { Write-Host '' }
        $total = Get-AfCheckListTotal -Items $Items
        $sum = 'Ticked: {0}' -f (Format-AfSize $total.Bytes)
        if ($total.Unknown -gt 0) { $sum += ' + {0} item(s) of unknown size' -f $total.Unknown }
        Write-Host ('  {0}' -f $sum) -ForegroundColor Green
        Write-Host '  Space/number = tick  A = all without !  N = none  Enter = go on  Esc = back' -ForegroundColor DarkGray
        Write-Host '  ! = read the note first, !! = asks again before it runs.' -ForegroundColor DarkGray
        if ($notice) { Write-Host ('  {0}' -f $notice) -ForegroundColor Yellow }
        $notice = $null

        $key = [string](& $ReadKey)
        $number = 0
        if ($key -eq 'Up') { $index = ($index - 1 + $Items.Count) % $Items.Count }
        elseif ($key -eq 'Down') { $index = ($index + 1) % $Items.Count }
        elseif ($key -eq 'Enter') {
            $ticked = @($Items | Where-Object { $_.Checked -and -not $_.Locked })
            if ($ticked.Count -eq 0) { $notice = 'Nothing is ticked. Tick at least one item, or press Esc to go back.'; continue }
            return [pscustomobject]@{ Action = 'Continue'; Items = $ticked }
        }
        elseif ($key -eq 'Escape' -or $key -eq 'B') { return [pscustomobject]@{ Action = 'Back'; Items = @() } }
        elseif ($key -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { return [pscustomobject]@{ Action = 'Quit'; Items = @() } }
        }
        elseif ($key -eq 'A') { foreach ($item in $Items) { if (-not $item.Locked -and -not $item.Warn) { $item.Checked = $true } } }
        elseif ($key -eq 'N') { foreach ($item in $Items) { $item.Checked = $false } }
        elseif ($key -eq ' ' -or ([int]::TryParse($key, [ref]$number) -and $number -ge 1 -and $number -le [math]::Min(9, $Items.Count))) {
            if ($key -ne ' ') { $index = $number - 1 }
            $item = $Items[$index]
            if ($item.Locked) { $notice = $item.Locked }
            else { $item.Checked = -not $item.Checked }
        }
        else { $notice = 'Command unknown. Use the arrow keys and Space, or press the number.' }
    }
}
