# The progress panel that replaces the stock Write-Progress block, from Creative's
# CRTV-0010 build guide: ONE bar row with the words on top; done cells Black on
# Green, the rest White on DarkGray; the frame in the mode colour (Standard cyan,
# Technician orange). The panel sits under the normal output and is redrawn in
# place, so activity lines scroll above it and it never covers the banner.
#   Live   A console: the panel is drawn and redrawn. Colour comes from the display
#          (VT, 16 colours, or none); the Ascii style draws it with + - | # only.
#   Lines  Redirected output or TERM=dumb: no panel, activity lines only, so logs
#          and pipes stay clean.
# A panel is built as rows of coloured runs first, so tests can read it without a console.

function Get-AfBarFill {
    # How many of -Width cells are done. Rounds down, so a full bar means 100%.
    [CmdletBinding()]
    [OutputType([int])]
    param([double] $Percent, [int] $Width)

    if ($Width -le 0) { return 0 }
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    return [int][math]::Floor($Width * $p / 100)
}

function Get-AfProgressKind {
    # Live or Lines. Pure: the caller passes the facts.
    [CmdletBinding()]
    [OutputType([string])]
    param([bool] $OutputRedirected, [AllowEmptyString()] [string] $Term, [int] $Width)

    if ($OutputRedirected -or $Term -eq 'dumb' -or $Width -lt 42) { return 'Lines' }
    return 'Live'
}

function New-AfProgressPanel {
    <#
    .SYNOPSIS
        The panel as rows of runs (@{ Text; Fg; Bg }). Every row is exactly -Width
        cells, so it never wraps. -Ascii draws it with + - | # and no colour.
    #>
    [CmdletBinding()]
    param(
        [string] $Title,
        [AllowEmptyCollection()] [string[]] $Lines = @(),
        [double] $Percent,
        [int] $Width = 78,
        [string] $Mode = 'Standard',
        [switch] $Ascii
    )

    $theme = Get-AfTheme -Mode $Mode
    $g = $script:AfGlyph
    $inner = $Width - 4
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $label = '{0}%' -f [int][math]::Floor($p)
    $run = { param($Text, $Fg = 'Gray', $Bg = 'Black') @{ Text = [string]$Text; Fg = $Fg; Bg = $Bg } }
    $fit = { param([string] $Text) if ($Text.Length -gt $inner) { $Text.Substring(0, $inner) } else { $Text.PadRight($inner) } }

    if ($Ascii) { $h = '-'; $v = '|'; $tl = '+'; $tr = '+'; $bl = '+'; $br = '+' }
    else { $h = [string]$g.H; $v = [string]$g.V; $tl = [string]$g.TopLeft; $tr = [string]$g.TopRight; $bl = [string]$g.BottomLeft; $br = [string]$g.BottomRight }

    $rows = New-Object System.Collections.Generic.List[object]
    $name = ' {0} ' -f $Title.ToUpperInvariant()
    if ($name.Length -gt $Width - 4) { $name = $name.Substring(0, $Width - 4) }
    $rows.Add(@((& $run ($tl + $h) $theme.Frame), (& $run $name $theme.Accent), (& $run (($h * ($Width - 3 - $name.Length)) + $tr) $theme.Frame)))
    foreach ($line in $Lines) {
        $rows.Add(@((& $run ($v + ' ') $theme.Frame), (& $run (& $fit $line) 'White'), (& $run (' ' + $v) $theme.Frame)))
    }

    if ($Ascii) {
        # The percent goes after the bar: there is no colour to read it on.
        $cells = $inner - 5
        $done = Get-AfBarFill -Percent $p -Width $cells
        $bar = @(& $run (('#' * $done) + ('-' * ($cells - $done)) + $label.PadLeft(5)))
    }
    else {
        # The percent sits in the middle of the bar, in the colour of the cell under it.
        $done = Get-AfBarFill -Percent $p -Width $inner
        $text = (' ' * $inner).ToCharArray()
        $start = [int][math]::Floor(($inner - $label.Length) / 2)
        for ($i = 0; $i -lt $label.Length; $i++) { $text[$start + $i] = $label[$i] }
        $bar = @()
        if ($done -gt 0) { $bar += & $run (-join $text[0..($done - 1)]) 'Black' 'Green' }
        if ($done -lt $inner) { $bar += & $run (-join $text[$done..($inner - 1)]) 'White' 'DarkGray' }
    }
    $rows.Add(@((& $run ($v + ' ') $theme.Frame)) + $bar + @((& $run (' ' + $v) $theme.Frame)))
    $rows.Add(@((& $run ($bl + ($h * ($Width - 2)) + $br) $theme.Frame)))
    return , $rows.ToArray()
}

function ConvertTo-AfPanelText {
    # One panel row as text, from column 2: VT colour codes, or the bare characters.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object[]] $Row, [switch] $Vt)

    # The leading space keeps column 1 empty, as on every other screen.
    if (-not $Vt) { return ' ' + (-join @($Row | ForEach-Object { $_.Text })) }
    $e = [char]27
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$e[0m ")
    foreach ($r in $Row) {
        [void]$sb.Append("$e[0;").Append($script:AfSgrFg[$r.Fg]).Append(';').Append($script:AfSgrBg[$r.Bg]).Append('m').Append($r.Text)
    }
    [void]$sb.Append("$e[0m$e[K")
    return $sb.ToString()
}

function Open-AfProgressView {
    <#
    .SYNOPSIS
        Starts a progress panel for one task. Nothing is drawn until the first update.
        Outside a menu session (-NoMenu, scripts) a console still gets the panel, in
        Ascii; redirected output gets activity lines only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Title, [string] $Mode)

    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    $width = 0
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch { Write-Verbose 'No console window size.' }
    $display = Get-AfDisplay
    if (-not $Mode) {
        $Mode = 'Standard'
        if ($script:AfUi -and $script:AfUi.Settings -and $script:AfUi.Settings.Mode) { $Mode = [string]$script:AfUi.Settings.Mode }
    }
    return @{
        Title = $Title; Mode = $Mode
        Kind = Get-AfProgressKind -OutputRedirected $redirected -Term ([string]$env:TERM) -Width $width
        Ascii = $display.Style -eq 'Ascii'; Color = $display.Color
        Width = [math]::Min(78, $width - 2)
        Shown = 0; Last = $null
    }
}

function Clear-AfProgressRows {
    # Moves the cursor back to the panel's first row and blanks the panel.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $View, [bool] $Vt)

    if ($View.Shown -le 0) { return }
    if ($Vt) {
        $e = [char]27
        Write-Host ("$e[0m$e[{0}F$e[J" -f $View.Shown) -NoNewline
    }
    else {
        $top = [math]::Max(0, [Console]::CursorTop - $View.Shown)
        [Console]::SetCursorPosition(0, $top)
        for ($i = 0; $i -lt $View.Shown; $i++) { Write-Host (' ' * ($View.Width + 1)) }
        [Console]::SetCursorPosition(0, $top)
    }
    $View.Shown = 0
}

function Write-AfProgressRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $View, [bool] $Vt)

    $panel = New-AfProgressPanel -Title $View.Title -Lines $View.Last.Lines -Percent $View.Last.Percent -Width $View.Width -Mode $View.Mode -Ascii:$View.Ascii
    foreach ($row in $panel) {
        if ($View.Ascii -or $View.Color -eq 'None') { Write-Host (ConvertTo-AfPanelText -Row $row) }
        elseif ($Vt -and $View.Color -eq 'Vt') { Write-Host (ConvertTo-AfPanelText -Row $row -Vt) }
        else {
            Write-Host ' ' -NoNewline
            foreach ($r in $row) {
                $fg = $r.Fg; $bg = $r.Bg
                if ($fg -eq 'Orange') { $fg = 'DarkYellow' }
                if ($bg -eq 'Orange') { $bg = 'DarkYellow' }
                Write-Host $r.Text -ForegroundColor $fg -BackgroundColor $bg -NoNewline
            }
            Write-Host ''
        }
    }
    $View.Shown = $panel.Count
}

function Test-AfProgressVt {
    # VT for this draw, used to move the cursor even when the panel has no colour.
    # SFC and DISM can turn VT off, so it is switched on again each time.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return (Enable-AfVirtualTerminal)
}

function Update-AfProgressView {
    # Redraws the panel in place with new words and percent.
    [CmdletBinding()]
    param([AllowNull()] [hashtable] $View, [AllowEmptyCollection()] [string[]] $Lines = @(), [double] $Percent)

    if (-not $View) { return }
    $View.Last = @{ Lines = $Lines; Percent = $Percent }
    if ($View.Kind -ne 'Live') { return }
    $vt = Test-AfProgressVt
    Clear-AfProgressRows -View $View -Vt $vt
    Write-AfProgressRows -View $View -Vt $vt
}

function Write-AfProgressText {
    # An activity line above the panel: the panel moves down under it.
    [CmdletBinding()]
    param([AllowNull()] [hashtable] $View, [AllowEmptyString()] [string] $Text, [string] $Color = 'Gray')

    if (-not $View -or $View.Kind -ne 'Live' -or $View.Shown -le 0) {
        Write-Host $Text -ForegroundColor $Color
        return
    }
    $vt = Test-AfProgressVt
    Clear-AfProgressRows -View $View -Vt $vt
    Write-Host $Text -ForegroundColor $Color
    Write-AfProgressRows -View $View -Vt $vt
}

function Close-AfProgressView {
    # Takes the panel off the screen, like Write-Progress -Completed. Safe to call twice.
    [CmdletBinding()]
    param([AllowNull()] [hashtable] $View)

    if (-not $View -or $View.Kind -ne 'Live') { return }
    Clear-AfProgressRows -View $View -Vt (Test-AfProgressVt)
}
