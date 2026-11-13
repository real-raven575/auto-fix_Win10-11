# The tick-box screen shared by the Clean up tools: Disk Cleanup now, the browser
# cleaner next. The user ticks items, sees the total, and nothing is removed here;
# the caller shows its own preview and asks Y/N after Enter.

function Format-AfSize {
    # 0 B, 12 KB, 3.4 MB, 1.2 GB. $null means the size is not known.
    # Rounds DOWN, the way Explorer does (464.7 GB shows as 464 GB, raven575 2026-11-13),
    # so a size never reads higher than Explorer's and free space is never overstated.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Bytes)

    if ($null -eq $Bytes) { return 'size not known' }
    $value = [double]$Bytes
    if ($value -lt 1024) { return ('{0:0} B' -f [math]::Floor($value)) }
    foreach ($unit in 'KB', 'MB', 'GB', 'TB') {
        $value = $value / 1024
        if ($value -lt 1024 -or $unit -eq 'TB') {
            # The tiny nudge keeps exact values such as 3.4 from flooring to 3.3 through binary rounding.
            if ($value -ge 100) { return ('{0:0} {1}' -f [math]::Floor($value + 1e-9), $unit) }
            return ('{0:0.0} {1}' -f ([math]::Floor($value * 10 + 1e-9) / 10), $unit).Replace(',', '.')
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

function Get-AfCheckListLine {
    <#
    .SYNOPSIS
        The rows of a tick list in order: a heading row when the group changes, then
        the item's row. Each row: Kind (Group or Item), Text, and Item (its index).
    #>
    [CmdletBinding()]
    param([object[]] $Items = @())

    $digits = ([string]$Items.Count).Length
    $group = $null
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        if ($item.Group -and $item.Group -ne $group) {
            $group = $item.Group
            [pscustomobject]@{ Kind = 'Group'; Text = [string]$group; Item = $i }
        }
        $box = '[ ]'
        if ($item.Checked) { $box = '[x]' }
        if ($item.Locked) { $box = '[-]' }
        $flag = '  '
        if ($item.Warn -ge 2) { $flag = '!!' } elseif ($item.Warn -ge 1) { $flag = '! ' }
        $label = [string]$item.Label
        if ($label.Length -gt 44) { $label = $label.Substring(0, 41) + '...' }
        $size = Format-AfSize $item.Size
        if ($null -eq $item.Size) { $size = 'size ?' }
        if ($item.Locked) { $size = 'locked' }
        [pscustomobject]@{
            Kind = 'Item'; Item = $i
            Number = ([string]($i + 1)).PadLeft($digits); Box = $box; Label = ('{0,-44}' -f $label); Flag = $flag; Size = ('{0,10}' -f $size)
        }
    }
}

function Get-AfCheckListWindow {
    # The first row to show so the marked item (and its heading, when it fits) is in view.
    [CmdletBinding()]
    [OutputType([int])]
    param([object[]] $Lines, [int] $Index, [int] $Top, [int] $Height)

    $at = 0
    for ($n = 0; $n -lt $Lines.Count; $n++) { if ($Lines[$n].Kind -eq 'Item' -and $Lines[$n].Item -eq $Index) { $at = $n; break } }
    $want = $at
    if ($at -gt 0 -and $Lines[$at - 1].Kind -eq 'Group') { $want = $at - 1 }
    if ($want -lt $Top) { $Top = $want }
    if ($at -ge $Top + $Height) { $Top = $at - $Height + 1 }
    return [math]::Max(0, [math]::Min($Top, [math]::Max(0, $Lines.Count - $Height)))
}

function New-AfCheckListScreen {
    <#
    .SYNOPSIS
        One frame of the tick list in the Branded or Plain look, built as a grid and
        written in one go (no screen clear), like every other menu: banner, the list
        box with the scrolling rows, the marked item's note, the total, and the keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Display,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        [int] $Index,
        [int] $Top,
        [string[]] $Info = @(),
        [string] $Notice,
        [string] $Mode = 'Standard',
        [int] $Height = 8
    )

    $g = $script:AfGlyph
    $theme = Get-AfTheme -Mode $Mode
    $state = Get-AfUiState
    $screen = New-AfScreen
    if ($Display.Tile) { Add-AfTile -Screen $screen }
    Add-AfBannerArea -Screen $screen -Mode $Mode -Style $Display.Style -IsAdmin $state.IsAdmin -Online $state.Online -Redacted $state.Redacted
    Add-AfBox -Screen $screen -Top 6 -Left 2 -Bottom 21 -Right 79 -Title $Title -Frame $theme.Frame -Accent $theme.Accent

    if ($Info -and $Info[0]) {
        $first = @(Split-AfText -Text $Info[0] -Width 74)
        Set-AfText -Screen $screen -Row 7 -Col 4 -Text ([string]$first[0]) -Fg 'White'
    }
    $lines = @(Get-AfCheckListLine -Items $Items)
    if ($Top -gt 0) { Set-AfText -Screen $screen -Row 8 -Col 8 -Text '... more above' -Fg 'DarkGray' }
    $row = 9
    for ($n = $Top; $n -lt [math]::Min($lines.Count, $Top + $Height); $n++) {
        $line = $lines[$n]
        if ($line.Kind -eq 'Group') {
            Set-AfText -Screen $screen -Row $row -Col 4 -Text $line.Text -Fg $theme.Accent
        }
        else {
            $item = $Items[$line.Item]
            $color = 'Gray'
            $marker = ' '
            if ($line.Item -eq $Index) { $color = 'White'; $marker = $g.Pointer }
            elseif ($item.Locked) { $color = 'DarkGray' }
            $flagColor = $color
            if ($item.Warn -ge 1 -and -not $item.Locked) { $flagColor = 'Yellow' }
            $text = '{0} {1} {2} ' -f $marker, $line.Number, $line.Box
            Set-AfText -Screen $screen -Row $row -Col 4 -Text $text -Fg $color
            if ($line.Item -eq $Index) { Set-AfText -Screen $screen -Row $row -Col 4 -Text $marker -Fg $theme.Accent }
            $col = 4 + $text.Length
            Set-AfText -Screen $screen -Row $row -Col $col -Text ($line.Label + ' ') -Fg $color
            Set-AfText -Screen $screen -Row $row -Col ($col + 45) -Text $line.Flag -Fg $flagColor
            Set-AfText -Screen $screen -Row $row -Col ($col + 47) -Text (' ' + $line.Size) -Fg $color
        }
        $row++
    }
    if ($Top + $Height -lt $lines.Count) { Set-AfText -Screen $screen -Row 17 -Col 8 -Text '... more below' -Fg 'DarkGray' }

    # Rows 18-19: a message after the last key, or else the marked item's note.
    $current = $Items[$Index]
    $text = $null
    $color = 'Yellow'
    if ($Notice) { $text = $Notice }
    elseif ($current.Locked) { $text = [string]$current.Locked; $color = 'DarkGray' }
    elseif ($current.Note) { $text = [string]$current.Note }
    if ($text) {
        $parts = @(Split-AfText -Text $text -Width 74)
        for ($p = 0; $p -lt [math]::Min(2, $parts.Count); $p++) { Set-AfText -Screen $screen -Row (18 + $p) -Col 4 -Text $parts[$p] -Fg $color }
    }
    Set-AfText -Screen $screen -Row 20 -Col 4 -Text (Get-AfCheckListSum -Items $Items) -Fg 'Green'

    Set-AfText -Screen $screen -Row 22 -Col 2 -Text ([string]$g.H * 78) -Fg $theme.Frame
    $keys = @(@(('[{0}{1}]' -f $g.Up, $g.Down), 'Move'), @('[Space]', 'Tick'), @('[A]', 'All'), @('[N]', 'None'), @('[Enter]', 'Go on'), @('[Esc]', 'Back'), @('[Q]', 'Quit'))
    $col = 3
    $first = $true
    foreach ($key in $keys) {
        if (-not $first) { Set-AfText -Screen $screen -Row 23 -Col $col -Text (' {0}' -f $g.V) -Fg 'DarkGray'; $col += 2 }
        $first = $false
        Set-AfText -Screen $screen -Row 23 -Col $col -Text $key[0] -Fg $theme.Accent
        $col += $key[0].Length
        Set-AfText -Screen $screen -Row 23 -Col $col -Text $key[1] -Fg 'Gray'
        $col += $key[1].Length
    }
    Set-AfText -Screen $screen -Row 24 -Col 3 -Text 'Number = tick that item.  A = all without !.  !! = asks again before it runs.' -Fg 'DarkGray'
    if ($Display.Style -eq 'Branded' -and $Display.Tile) { $null = Add-AfFaces -Screen $screen -Spots $script:AfFaceSpots.Menu }
    return $screen
}

function Get-AfCheckListSum {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]] $Items = @())

    $total = Get-AfCheckListTotal -Items $Items
    $sum = 'Ticked: {0}' -f (Format-AfSize $total.Bytes)
    if ($total.Unknown -gt 0) { $sum += ' + {0} item(s) of unknown size' -f $total.Unknown }
    return $sum
}

function Select-AfCheckList {
    <#
    .SYNOPSIS
        Shows a list of tick boxes and returns Action (Continue, Back or Quit) and
        the ticked Items. Space or an item's number ticks and unticks; with 10 or
        more items a first digit that could start a longer number only moves the
        marker, and a second digit finishes it (1 then 2 = item 12; 1 then Space =
        item 1). A ticks every item without a warning, N unticks all, Enter
        continues. Items with Warn are never ticked by A. Locked items show why and
        can't be ticked. Each item: @{ Key; Label; Size (bytes or $null); Checked;
        Warn (0, 1 or 2); Locked (the reason, or empty); Group (a heading, optional) }.
        Branded and Plain draw one grid per key, so moving does not blink.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        # Lines shown above the list.
        [string[]] $Info = @(),
        [string] $Mode = 'Standard',
        # How many list rows (items and headings) show at once; the list scrolls past this.
        [int] $PageRows = 8,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $index = 0
    $top = 0
    $notice = $null
    $pending = ''
    while ($true) {
        $lines = @(Get-AfCheckListLine -Items $Items)
        $top = Get-AfCheckListWindow -Lines $lines -Index $index -Top $top -Height $PageRows
        $display = Get-AfDisplay
        if ($display.Style -ne 'Ascii') {
            $screen = New-AfCheckListScreen -Display $display -Title $Title -Items $Items -Index $index -Top $top -Info $Info `
                -Notice $notice -Mode $Mode -Height $PageRows
            Write-AfScreen -Screen $screen -Display $display
        }
        else {
            Clear-AfScreen
            Show-AfBanner -Mode $Mode
            Write-Host ('  {0}' -f $Title) -ForegroundColor White
            foreach ($line in $Info) { Write-Host ('  {0}' -f $line) -ForegroundColor Gray }
            if ($top -gt 0) { Write-Host '      ... more above' -ForegroundColor DarkGray }
            for ($n = $top; $n -lt [math]::Min($lines.Count, $top + $PageRows); $n++) {
                $line = $lines[$n]
                if ($line.Kind -eq 'Group') { Write-Host ('  {0}' -f $line.Text) -ForegroundColor Cyan; continue }
                $item = $Items[$line.Item]
                $marker = ' '
                $color = 'Gray'
                if ($line.Item -eq $index) { $marker = '>'; $color = 'White' }
                elseif ($item.Locked) { $color = 'DarkGray' }
                $flagColor = $color
                if ($item.Warn -ge 1 -and -not $item.Locked) { $flagColor = 'Yellow' }
                Write-Host ('  {0} {1} {2} ' -f $marker, $line.Number, $line.Box) -ForegroundColor $color -NoNewline
                Write-Host ($line.Label + ' ') -ForegroundColor $color -NoNewline
                Write-Host $line.Flag -ForegroundColor $flagColor -NoNewline
                Write-Host (' ' + $line.Size) -ForegroundColor $color
            }
            if ($top + $PageRows -lt $lines.Count) { Write-Host '      ... more below' -ForegroundColor DarkGray }

            $current = $Items[$index]
            if ($current.Locked) { Write-Host ('  {0}' -f $current.Locked) -ForegroundColor DarkGray }
            elseif ($current.Note) { Write-Host ('  {0}' -f $current.Note) -ForegroundColor Yellow }
            else { Write-Host '' }
            Write-Host ('  {0}' -f (Get-AfCheckListSum -Items $Items)) -ForegroundColor Green
            Write-Host '  Space/number = tick  A = all without !  N = none  Enter = go on  Esc = back' -ForegroundColor DarkGray
            Write-Host '  ! = read the note first, !! = asks again before it runs.' -ForegroundColor DarkGray
            if ($notice) { Write-Host ('  {0}' -f $notice) -ForegroundColor Yellow }
        }
        $notice = $null

        $key = [string](& $ReadKey)
        $typed = ''
        if ($key -match '^[0-9]$') { $typed = $pending + $key }
        $pending = ''
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
        elseif ($typed) {
            $number = [int]$typed
            if ($number -lt 1 -or $number -gt $Items.Count) { $notice = 'There is no item {0}.' -f $typed; continue }
            $index = $number - 1
            if ($number * 10 -le $Items.Count) {
                # Could still become a longer number: wait for the next key.
                $pending = $typed
                $last = [math]::Min($Items.Count, $number * 10 + 9)
                $notice = 'Item {0} marked. Space ticks it; a second digit picks {1} to {2}.' -f $number, ($number * 10), $last
                continue
            }
            $item = $Items[$index]
            if ($item.Locked) { $notice = $item.Locked }
            else { $item.Checked = -not $item.Checked }
        }
        elseif ($key -eq ' ') {
            $item = $Items[$index]
            if ($item.Locked) { $notice = $item.Locked }
            else { $item.Checked = -not $item.Checked }
        }
        else { $notice = 'Command unknown. Use the arrow keys and Space, or press the number.' }
    }
}
