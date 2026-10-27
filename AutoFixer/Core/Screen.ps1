# The Branded and Plain screens, from Creative's CRTV-0010 build guide (picked by
# raven575 2026-10-25). A screen is built as an 80x25 grid of cells first, then
# written in one go, so tests can check every cell without a console.
#   Branded  Wrench art, the background tile and its hidden faces. The default.
#   Plain    The same frames without any art. Settings, settings.json or -Plain.
#   Ascii    The original line-by-line screens, for small, redirected or TERM=dumb
#            consoles. NO_COLOR and consoles without VT support get Plain, tile off.
# Rows and columns count from 1, like the guide. Nothing is ever written in column
# 1 or 80 or on row 25. Every glyph is built from its code point, so the .ps1 files
# stay pure ASCII and Windows PowerShell 5.1 reads them the same way as PowerShell 7.

$script:AfGlyph = @{
    H = [char]0x2500; V = [char]0x2502; TopLeft = [char]0x250C; TopRight = [char]0x2510
    BottomLeft = [char]0x2514; BottomRight = [char]0x2518; TeeLeft = [char]0x251C; TeeRight = [char]0x2524
    Light = [char]0x2591; Medium = [char]0x2592; Dark = [char]0x2593; Full = [char]0x2588
    Upper = [char]0x2580; Lower = [char]0x2584; LeftHalf = [char]0x258C; RightHalf = [char]0x2590
    Square = [char]0x25A0; Pointer = [char]0x25BA; Up = [char]0x2191; Down = [char]0x2193
}

# Background tile, 8 wide x 4 tall, rows 5-21 and columns 2-79.
$script:AfTile = @('_|_     ', ' |      ', '    _|_ ', '     |  ')
$script:AfFace = '@(''_'')@'
# Cross centres (row, column) that get a face on each kind of screen. A spot is
# skipped when something covers it, so a face never sits on half a cross.
$script:AfFaceSpots = @{
    Main       = @(@(5, 27), @(19, 15), @(19, 55), @(21, 35))
    Technician = @(@(5, 27), @(19, 15), @(21, 35))
    Menu       = @(@(5, 51), @(19, 23), @(19, 63), @(21, 11))
    About      = @(@(5, 67), @(21, 27))
}

# Splash wordmark: figlet font 'Modular' (patorjk.com TAAG), exactly 78 columns.
$script:AfWordmark = @(
    ' _______ __   __ _______ _______       _______ ___   __   __ _______ ______   '
    '|   _   |  | |  |       |       |     |       |   | |  |_|  |       |    _ |  '
    '|  |_|  |  | |  |_     _|   _   | __  |    ___|   | |       |    ___|   | ||  '
    '|       |  |_|  | |   | |  | |  ||__| |   |___|   | |       |   |___|   |_||_ '
    '|       |       | |   | |  |_|  |     |    ___|   |  |     ||    ___|    __  |'
    '|   _   |       | |   | |       |     |   |   |   | |   _   |   |___|   |  | |'
    '|__| |__|_______| |___| |_______|     |___|   |___| |__| |__|_______|___|  |_|'
)
# '#' = inside a letter: the cell gets the fill colour as its background.
$script:AfWordmarkFill = @(
    '..............................................................................'
    '.#######.##...##.#######.#######.......#######.###...##...##.#######.######...'
    '.##...##.##...##.#######.#######.......#######.###...#######.#######.###......'
    '.#######.##...##...###...##...##..##...###.....###...#######.###.....###......'
    '.#######.#######...###...##...##.......#######.###....#####..#######.########.'
    '.#######.#######...###...#######.......###.....###...#######.###.....###....#.'
    '.##...##.#######...###...#######.......###.....###...##...##.#######.###....#.'
)

# Pixel art, two pixel rows per text row. '.' is see-through.
$script:AfPixelColors = @{ C = 'DarkCyan'; B = 'Cyan'; F = 'DarkYellow'; S = 'Yellow'; K = 'Black'; W = 'White' }
$script:AfIconArt = @('..CCCC..', '.CCCCCC.', '.CCBBBBB', 'SFKSSKFS', '.FSSSSF.', '..FFFF..')
$script:AfWrenchArt = @(
    '......CCCCCC......'
    '....CCCCCCCCCC....'
    '...CCCCCWWCCCCC...'
    '...CCCCCCCCCCCCBBB'
    '...BBBBBBBBBBBBBBB'
    '...FFFFFFFFFFFF...'
    '.FFFFSSSFFSSSFFFF.'
    'FSSFSSSSSSSSSSFSSF'
    'FSSFSKKSSSSKKSFSSF'
    'FSSFSKWSSSSKWSFSSF'
    '.FFFSSSSSSSSSSFFF.'
    '...FSSSKSSKSSSF...'
    '...FSFSSSSSSFSF...'
    '....FSSFFFFSSF....'
    '.....FFSSSSFF.....'
    '..FFFFCCCCCCFFFF..'
    '.FFFFFCCWWCCFFFFF.'
    'FFFFFFCCCCCCFFFFFF'
)

$script:AfSgr = @{
    Black = 30; DarkRed = 31; DarkGreen = 32; DarkYellow = 33; DarkBlue = 34; DarkMagenta = 35; DarkCyan = 36; Gray = 37
    DarkGray = 90; Red = 91; Green = 92; Yellow = 93; Blue = 94; Magenta = 95; Cyan = 96; White = 97
}
# Foreground and background codes by colour name, looked up once per cell.
$script:AfSgrFg = @{ Orange = '38;2;240;136;42' }
$script:AfSgrBg = @{ Orange = '48;2;240;136;42' }
foreach ($name in $script:AfSgr.Keys) {
    $script:AfSgrFg[$name] = [string]$script:AfSgr[$name]
    $script:AfSgrBg[$name] = [string]($script:AfSgr[$name] + 10)
}

function Get-AfDisplayStyle {
    <#
    .SYNOPSIS
        Picks how screens are drawn from what the console can do. Pure: the caller
        passes the facts, so every fallback can be tested.
    #>
    [CmdletBinding()]
    param(
        # The saved choice: Branded or Plain.
        [string] $Preferred = 'Branded',
        # -Plain on the command line, for this run only.
        [switch] $ForcePlain,
        [AllowEmptyString()] [string] $NoColor,
        [AllowEmptyString()] [string] $Term,
        [bool] $SupportsVt,
        [bool] $OutputRedirected,
        [int] $Width,
        [int] $Height
    )

    $result = { param($Style, $Color, $Tile, $Reason) [pscustomobject]@{ Style = $Style; Color = $Color; Tile = $Tile; Reason = $Reason } }
    if ($OutputRedirected) { return & $result 'Ascii' 'None' $false 'output is redirected' }
    if ($Term -eq 'dumb') { return & $result 'Ascii' 'None' $false 'TERM=dumb' }
    if ($Width -lt 80 -or $Height -lt 25) { return & $result 'Ascii' 'None' $false ('the window is {0}x{1}, smaller than 80x25' -f $Width, $Height) }
    # no-color.org: any value that is not empty turns colour off.
    if ($NoColor) { return & $result 'Plain' 'None' $false 'NO_COLOR is set' }
    if (-not $SupportsVt) { return & $result 'Plain' 'Console' $false 'the console has no VT support' }
    if ($ForcePlain) { return & $result 'Plain' 'Vt' $true '-Plain' }
    if ($Preferred -eq 'Plain') { return & $result 'Plain' 'Vt' $true 'Settings: Plain' }
    return & $result 'Branded' 'Vt' $true 'Settings: Branded'
}

function Enable-AfVirtualTerminal {
    # Turns on VT processing for this console window and says whether it is on.
    # A program such as SFC can turn it off again, so this runs before every draw.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $type = 'AutoFixer.ConsoleMode' -as [type]
    if (-not $type -and -not $script:AfVtCompileFailed) {
        try {
            $type = Add-Type -Namespace AutoFixer -Name ConsoleMode -PassThru -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        catch { $script:AfVtCompileFailed = $true }
    }
    if (-not $type) { return $false }
    try {
        # -11 is the standard output handle; 4 is ENABLE_VIRTUAL_TERMINAL_PROCESSING.
        $handle = $type::GetStdHandle(-11)
        $mode = [uint32]0
        if (-not $type::GetConsoleMode($handle, [ref]$mode)) { return $false }
        if ($mode -band 4) { return $true }
        return [bool]$type::SetConsoleMode($handle, ($mode -bor 4))
    }
    catch { return $false }
}

function Get-AfConsoleFacts {
    # What the console in front of the user can do right now.
    [CmdletBinding()]
    param()

    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    $width = 0
    $height = 0
    try {
        $size = $Host.UI.RawUI.WindowSize
        $width = $size.Width
        $height = $size.Height
    }
    catch { Write-Verbose 'No console window size.' }
    $vt = $false
    if (-not $redirected) { $vt = Enable-AfVirtualTerminal }
    return @{ NoColor = [string]$env:NO_COLOR; Term = [string]$env:TERM; SupportsVt = $vt; OutputRedirected = $redirected; Width = $width; Height = $height }
}

function Get-AfDisplay {
    # The style for the next draw. Outside a menu session (scripts, tests) it is Ascii.
    [CmdletBinding()]
    param()

    $ui = $script:AfUi
    if (-not $ui) { return [pscustomobject]@{ Style = 'Ascii'; Color = 'None'; Tile = $false; Reason = 'no menu session' } }
    $facts = $ui.Facts
    if (-not $facts) { $facts = Get-AfConsoleFacts }
    $preferred = 'Branded'
    if ($ui.Settings -and $ui.Settings.Style) { $preferred = [string]$ui.Settings.Style }
    return Get-AfDisplayStyle -Preferred $preferred -ForcePlain:([bool]$ui.ForcePlain) -NoColor $facts.NoColor -Term $facts.Term `
        -SupportsVt ([bool]$facts.SupportsVt) -OutputRedirected ([bool]$facts.OutputRedirected) -Width $facts.Width -Height $facts.Height
}

function Get-AfTheme {
    # Standard is cyan; Technician is orange (DarkYellow where 24-bit colour is not available).
    [CmdletBinding()]
    param([string] $Mode = 'Standard')

    if ($Mode -eq 'Technician') { return @{ Frame = 'DarkYellow'; Accent = 'Orange'; Fill = 'DarkRed' } }
    return @{ Frame = 'DarkCyan'; Accent = 'Cyan'; Fill = 'DarkBlue' }
}

function New-AfScreen {
    # An empty 80x25 grid. Index 0 is unused so rows and columns match the guide.
    [CmdletBinding()]
    param()

    $screen = @{ Ch = New-Object 'object[]' 26; Fg = New-Object 'object[]' 26; Bg = New-Object 'object[]' 26; Tile = New-Object 'object[]' 26 }
    for ($r = 0; $r -le 25; $r++) {
        $screen.Ch[$r] = (' ' * 81).ToCharArray()
        $screen.Fg[$r] = @('Gray') * 81
        $screen.Bg[$r] = @('Black') * 81
        $screen.Tile[$r] = New-Object 'bool[]' 81
    }
    return $screen
}

function Set-AfText {
    # Writes text from (Row, Col). Cells outside rows 1-24 and columns 2-79 are dropped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Screen,
        [int] $Row,
        [int] $Col,
        [AllowEmptyString()] [string] $Text,
        [string] $Fg = 'Gray',
        [string] $Bg = 'Black'
    )

    if ($Row -lt 1 -or $Row -gt 24) { return }
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Col + $i
        if ($c -lt 2 -or $c -gt 79) { continue }
        $Screen.Ch[$Row][$c] = $Text[$i]
        $Screen.Fg[$Row][$c] = $Fg
        $Screen.Bg[$Row][$c] = $Bg
        $Screen.Tile[$Row][$c] = $false
    }
}

function Clear-AfArea {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Screen, [int] $Top, [int] $Left, [int] $Bottom, [int] $Right)

    for ($r = $Top; $r -le $Bottom; $r++) { Set-AfText -Screen $Screen -Row $r -Col $Left -Text (' ' * ($Right - $Left + 1)) }
}

function Add-AfTile {
    # The pattern is drawn first; anything drawn later covers it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Screen)

    for ($r = 5; $r -le 21; $r++) {
        $pattern = $script:AfTile[($r - 5) % 4]
        for ($c = 2; $c -le 79; $c++) {
            $Screen.Ch[$r][$c] = $pattern[($c - 2) % 8]
            $Screen.Fg[$r][$c] = 'DarkGray'
            $Screen.Bg[$r][$c] = 'Black'
            $Screen.Tile[$r][$c] = $true
        }
    }
}

function Add-AfFaces {
    <#
    .SYNOPSIS
        Branded only, drawn last: puts @('_')@ on each listed cross that is still fully
        showing ('_|_' and the two tile cells on each side), and blanks the '|' under
        it. Returns how many faces were drawn.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [hashtable] $Screen, [Parameter(Mandatory)] [object[]] $Spots)

    $drawn = 0
    foreach ($spot in $Spots) {
        $r = $spot[0]
        $c = $spot[1]
        if ($r -lt 5 -or $r -gt 21 -or ($c - 3) -lt 2 -or ($c + 3) -gt 79) { continue }
        $visible = $true
        for ($x = $c - 3; $x -le $c + 3; $x++) { if (-not $Screen.Tile[$r][$x]) { $visible = $false } }
        if (-not $visible -or (-join $Screen.Ch[$r][($c - 1)..($c + 1)]) -ne '_|_') { continue }
        Set-AfText -Screen $Screen -Row $r -Col ($c - 3) -Text $script:AfFace -Fg 'DarkGray'
        if ($r -lt 21 -and $Screen.Tile[$r + 1][$c] -and $Screen.Ch[$r + 1][$c] -eq '|') { $Screen.Ch[$r + 1][$c] = ' ' }
        $drawn++
    }
    return $drawn
}

function Add-AfPixelArt {
    # Two pixel rows become one text row of half blocks. See-through pixels leave the cell alone.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Screen, [Parameter(Mandatory)] [string[]] $Pixels, [int] $Row, [int] $Col)

    $g = $script:AfGlyph
    for ($p = 0; $p -lt $Pixels.Count; $p += 2) {
        $top = $Pixels[$p]
        $bottom = '.' * $top.Length
        if ($p + 1 -lt $Pixels.Count) { $bottom = $Pixels[$p + 1] }
        for ($i = 0; $i -lt $top.Length; $i++) {
            $t = [string]$top[$i]
            $b = [string]$bottom[$i]
            if ($t -eq '.' -and $b -eq '.') { continue }
            $r = $Row + ($p / 2)
            $c = $Col + $i
            if ($t -eq $b) { Set-AfText -Screen $Screen -Row $r -Col $c -Text $g.Full -Fg $script:AfPixelColors[$t] }
            elseif ($t -eq '.') { Set-AfText -Screen $Screen -Row $r -Col $c -Text $g.Lower -Fg $script:AfPixelColors[$b] }
            elseif ($b -eq '.') { Set-AfText -Screen $Screen -Row $r -Col $c -Text $g.Upper -Fg $script:AfPixelColors[$t] }
            else { Set-AfText -Screen $Screen -Row $r -Col $c -Text $g.Upper -Fg $script:AfPixelColors[$t] -Bg $script:AfPixelColors[$b] }
        }
    }
}

function Add-AfBox {
    # A single-line frame that clears its own inside, so it covers the tile.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Screen,
        [int] $Top, [int] $Left, [int] $Bottom, [int] $Right,
        [string] $Title,
        [string] $Frame = 'DarkCyan',
        [string] $Accent = 'Cyan'
    )

    $g = $script:AfGlyph
    $inner = $Right - $Left - 1
    Clear-AfArea -Screen $Screen -Top $Top -Left $Left -Bottom $Bottom -Right $Right
    Set-AfText -Screen $Screen -Row $Top -Col $Left -Text ([string]$g.TopLeft + ([string]$g.H * $inner) + $g.TopRight) -Fg $Frame
    Set-AfText -Screen $Screen -Row $Bottom -Col $Left -Text ([string]$g.BottomLeft + ([string]$g.H * $inner) + $g.BottomRight) -Fg $Frame
    for ($r = $Top + 1; $r -lt $Bottom; $r++) {
        Set-AfText -Screen $Screen -Row $r -Col $Left -Text $g.V -Fg $Frame
        Set-AfText -Screen $Screen -Row $r -Col $Right -Text $g.V -Fg $Frame
    }
    if ($Title) { Set-AfText -Screen $Screen -Row $Top -Col ($Left + 2) -Text (' {0} ' -f $Title.ToUpperInvariant()) -Fg $Accent }
}

function Add-AfDivider {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Screen, [int] $Row, [int] $Left, [int] $Right, [string] $Frame = 'DarkCyan')

    $g = $script:AfGlyph
    Set-AfText -Screen $Screen -Row $Row -Col $Left -Text ([string]$g.TeeLeft + ([string]$g.H * ($Right - $Left - 1)) + $g.TeeRight) -Fg $Frame
}

function Add-AfBannerArea {
    <#
    .SYNOPSIS
        Rows 1-4: the banner with the mode badge, then the strip with administrator
        rights, the Online switch and redaction. Branded adds the icon on the left.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Screen,
        [string] $Mode = 'Standard',
        [string] $Style = 'Branded',
        [bool] $IsAdmin,
        [bool] $Online,
        [bool] $Redacted = $true
    )

    $g = $script:AfGlyph
    $theme = Get-AfTheme -Mode $Mode
    $left = 2
    if ($Style -eq 'Branded') {
        Add-AfPixelArt -Screen $Screen -Pixels $script:AfIconArt -Row 1 -Col 3
        $left = 12
    }
    $inner = 79 - $left - 1
    Set-AfText -Screen $Screen -Row 1 -Col $left -Text ([string]$g.TopLeft + ([string]$g.H * $inner) + $g.TopRight) -Fg $theme.Frame
    Set-AfText -Screen $Screen -Row 2 -Col $left -Text $g.V -Fg $theme.Frame
    Set-AfText -Screen $Screen -Row 2 -Col ($left + 2) -Text ('Auto-Fixer {0}' -f $script:AfVersion) -Fg $theme.Accent
    Set-AfText -Screen $Screen -Row 2 -Col ($left + 2 + 'Auto-Fixer '.Length + ([string]$script:AfVersion).Length + 2) -Text 'Windows 10 / 11 repair tool' -Fg 'White'
    $badge = switch ($Mode) { 'Standard' { ' STANDARD ' } 'Technician' { 'TECHNICIAN' } default { ' FIRST RUN' } }
    Set-AfText -Screen $Screen -Row 2 -Col 66 -Text $g.RightHalf -Fg $theme.Accent
    Set-AfText -Screen $Screen -Row 2 -Col 67 -Text $badge -Fg 'Black' -Bg $theme.Accent
    Set-AfText -Screen $Screen -Row 2 -Col 77 -Text $g.LeftHalf -Fg $theme.Accent
    Set-AfText -Screen $Screen -Row 2 -Col 79 -Text $g.V -Fg $theme.Frame
    Set-AfText -Screen $Screen -Row 3 -Col $left -Text ([string]$g.BottomLeft + ([string]$g.H * $inner) + $g.BottomRight) -Fg $theme.Frame

    $rights = 'NOT ADMIN'
    $rightsColor = 'Yellow'
    if ($IsAdmin) { $rights = 'ADMINISTRATOR'; $rightsColor = 'Green' }
    $col = 2
    Set-AfText -Screen $Screen -Row 4 -Col $col -Text $g.LeftHalf -Fg $rightsColor
    Set-AfText -Screen $Screen -Row 4 -Col ($col + 1) -Text ('{0} {1}' -f $g.Square, $rights) -Fg 'Black' -Bg $rightsColor
    $col += 3 + $rights.Length
    Set-AfText -Screen $Screen -Row 4 -Col $col -Text $g.RightHalf -Fg $rightsColor
    $col += 1
    $parts = @(
        @{ Name = 'Online: '; Value = @('OFF', 'ON')[[int]$Online]; Warn = $Online }
        @{ Name = 'Redaction: '; Value = @('OFF', 'ON')[[int]$Redacted]; Warn = -not $Redacted }
    )
    foreach ($part in $parts) {
        Set-AfText -Screen $Screen -Row 4 -Col $col -Text (' {0} ' -f $g.V) -Fg 'DarkGray'
        $col += 3
        Set-AfText -Screen $Screen -Row 4 -Col $col -Text $part.Name -Fg 'Gray'
        $col += $part.Name.Length
        $color = 'White'
        if ($part.Warn) { $color = 'Yellow' }
        Set-AfText -Screen $Screen -Row 4 -Col $col -Text $part.Value -Fg $color
        $col += $part.Value.Length
    }
}

function Add-AfFooter {
    # Row 22 is a line; row 23 lists the keys. -EscapeLabel is what Esc does here.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Screen, [string] $EscapeLabel, [string] $Frame = 'DarkCyan', [string] $Accent = 'Cyan')

    $g = $script:AfGlyph
    Set-AfText -Screen $Screen -Row 22 -Col 2 -Text ([string]$g.H * 78) -Fg $Frame
    $keys = @(@(('[{0}{1}]' -f $g.Up, $g.Down), 'Move'), @('[Enter]', 'Select'), @('[1-9]', 'Pick'))
    # On the main menu Esc quits, which [Q] already says.
    if ($EscapeLabel -and $EscapeLabel -ne 'Quit') { $keys += , @('[Esc]', $EscapeLabel) }
    $keys += , @('[Q]', 'Quit')
    $col = 3
    $first = $true
    foreach ($key in $keys) {
        if (-not $first) {
            Set-AfText -Screen $Screen -Row 23 -Col $col -Text (' {0}' -f $g.V) -Fg 'DarkGray'
            $col += 2
        }
        $first = $false
        Set-AfText -Screen $Screen -Row 23 -Col $col -Text $key[0] -Fg $Accent
        $col += $key[0].Length
        Set-AfText -Screen $Screen -Row 23 -Col $col -Text $key[1] -Fg 'Gray'
        $col += $key[1].Length
    }
}

function ConvertTo-AfVtText {
    <#
    .SYNOPSIS
        The whole screen as one string of VT escape codes: rows 1 to -LastRow, with
        colour codes only where the colour changes, then the rest of the window is
        erased. Every row is rewritten in place instead of clearing first, so moving
        the marker does not flicker or fill the scroll-back. -WorkTop leaves the
        cursor on row 6 so normal output can follow under the banner.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [hashtable] $Screen, [int] $LastRow = 24, [switch] $WorkTop)

    $e = [char]27
    $fgCodes = $script:AfSgrFg
    $bgCodes = $script:AfSgrBg
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$e[?25l")
    for ($r = 1; $r -le $LastRow; $r++) {
        [void]$sb.Append("$e[$r;1H")
        $fgRow = $Screen.Fg[$r]
        $bgRow = $Screen.Bg[$r]
        $chRow = $Screen.Ch[$r]
        $fg = $null
        $bg = $null
        for ($c = 1; $c -le 79; $c++) {
            if ($fgRow[$c] -ne $fg -or $bgRow[$c] -ne $bg) {
                $fg = $fgRow[$c]
                $bg = $bgRow[$c]
                [void]$sb.Append("$e[0;").Append($fgCodes[$fg]).Append(';').Append($bgCodes[$bg]).Append('m')
            }
            [void]$sb.Append($chRow[$c])
        }
        # Column 80 and anything wider stay empty, on black.
        [void]$sb.Append("$e[0;37;40m$e[K")
    }
    # Erase everything below, on black: an old menu, or rows past 25 in a tall window.
    [void]$sb.Append("$e[$($LastRow + 1);1H$e[0;37;40m$e[J$e[0m")
    if ($WorkTop) { [void]$sb.Append("$e[6;1H$e[?25h") }
    else { [void]$sb.Append("$e[25;1H") }
    return $sb.ToString()
}

function Write-AfScreen {
    # Writes the grid with the display's colour method. -WorkTop writes rows 1-5 only.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Screen, [Parameter(Mandatory)] [pscustomobject] $Display, [switch] $WorkTop)

    $lastRow = 24
    if ($WorkTop) { $lastRow = 5 }
    if ($Display.Color -eq 'Vt') {
        Write-Host (ConvertTo-AfVtText -Screen $Screen -LastRow $lastRow -WorkTop:$WorkTop) -NoNewline
        if ($script:AfUi) { $script:AfUi.UsedVt = $true }
        return
    }
    # No VT: one Write-Host per colour run (16 colours), or plain lines for NO_COLOR.
    Clear-AfScreen
    for ($r = 1; $r -le $lastRow; $r++) {
        if ($Display.Color -eq 'None') {
            Write-Host (-join $Screen.Ch[$r][1..79]).TrimEnd()
            continue
        }
        $c = 1
        while ($c -le 79) {
            $fg = $Screen.Fg[$r][$c]
            $bg = $Screen.Bg[$r][$c]
            $start = $c
            while ($c -le 79 -and $Screen.Fg[$r][$c] -eq $fg -and $Screen.Bg[$r][$c] -eq $bg) { $c++ }
            if ($fg -eq 'Orange') { $fg = 'DarkYellow' }
            if ($bg -eq 'Orange') { $bg = 'DarkYellow' }
            Write-Host (-join $Screen.Ch[$r][$start..($c - 1)]) -ForegroundColor $fg -BackgroundColor $bg -NoNewline
        }
        Write-Host ''
    }
}

function Get-AfUiState {
    # Banner facts for the current menu session, with safe values outside one.
    [CmdletBinding()]
    param()

    $state = @{ IsAdmin = $false; Online = $false; Redacted = $true }
    $ui = $script:AfUi
    if ($ui) {
        $state.IsAdmin = [bool]$ui.IsAdmin
        if ($ui.Settings) {
            $state.Online = [bool]$ui.Settings.Online
            $state.Redacted = -not [bool]$ui.Settings.ShowSensitive
        }
    }
    return $state
}

function Show-AfWorkTop {
    # Clears the screen and draws only the banner and strip, so the next lines of
    # normal output (questions, scan and repair progress) appear under it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Display, [string] $Mode = 'Standard')

    $state = Get-AfUiState
    $screen = New-AfScreen
    Add-AfBannerArea -Screen $screen -Mode $Mode -Style $Display.Style -IsAdmin $state.IsAdmin -Online $state.Online -Redacted $state.Redacted
    Write-AfScreen -Screen $screen -Display $Display -WorkTop
}

function New-AfSplashScreen {
    # The start screen: wordmark, shading bar, then Wrench (Branded) or the tagline (Plain).
    [CmdletBinding()]
    param([string] $Mode = 'Standard', [string] $Style = 'Branded', [bool] $Fill = $true)

    $g = $script:AfGlyph
    $theme = Get-AfTheme -Mode $Mode
    $screen = New-AfScreen
    for ($i = 0; $i -lt $script:AfWordmark.Count; $i++) {
        $line = $script:AfWordmark[$i]
        $mask = $script:AfWordmarkFill[$i]
        for ($x = 0; $x -lt $line.Length; $x++) {
            $inside = $Fill -and $mask[$x] -eq '#'
            if ($inside) { Set-AfText -Screen $screen -Row (3 + $i) -Col (2 + $x) -Text $line[$x] -Fg $theme.Accent -Bg $theme.Fill }
            elseif ($line[$x] -ne ' ') { Set-AfText -Screen $screen -Row (3 + $i) -Col (2 + $x) -Text $line[$x] -Fg $theme.Accent }
        }
    }
    $bar = ([string]$g.Light * 8) + ([string]$g.Medium * 8) + ([string]$g.Dark * 8) + ([string]$g.Full * 12) + ([string]$g.Dark * 8) + ([string]$g.Medium * 8) + ([string]$g.Light * 8)
    Set-AfText -Screen $screen -Row 11 -Col (1 + [int]((80 - $bar.Length) / 2)) -Text $bar -Fg $theme.Accent
    $tagline = 'Operation: Back on Its Feet'
    $byline = 'by raven575'
    if ($Style -eq 'Branded') {
        Add-AfPixelArt -Screen $screen -Pixels $script:AfWrenchArt -Row 13 -Col 18
        Set-AfText -Screen $screen -Row 16 -Col 42 -Text $tagline -Fg 'White'
        Set-AfText -Screen $screen -Row 17 -Col 42 -Text $byline -Fg 'Gray'
        Set-AfText -Screen $screen -Row 19 -Col 42 -Text ('Auto-Fixer {0}' -f $script:AfVersion) -Fg 'DarkGray'
    }
    else {
        Set-AfText -Screen $screen -Row 14 -Col (1 + [int]((80 - $tagline.Length) / 2)) -Text $tagline -Fg 'White'
        Set-AfText -Screen $screen -Row 15 -Col (1 + [int]((80 - $byline.Length) / 2)) -Text $byline -Fg 'Gray'
    }
    return $screen
}

function Show-AfSplash {
    # Shows the start screen until a key is pressed or 3.5 seconds pass.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Display, [string] $Mode = 'Standard', [int] $Milliseconds = 3500)

    Write-AfScreen -Screen (New-AfSplashScreen -Mode $Mode -Style $Display.Style -Fill ($Display.Color -ne 'None')) -Display $Display
    try {
        $deadline = (Get-Date).AddMilliseconds($Milliseconds)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true); break }
            Start-Sleep -Milliseconds 50
        }
    }
    catch { Write-Verbose 'No keyboard to wait for.' }
}

function New-AfMenuScreen {
    <#
    .SYNOPSIS
        One frame of a menu in the Branded or Plain look: banner, strip, tile, the
        menu box (with -Info text above the items), the WHAT THIS DOES panel when
        items have -ItemInfo, optional art, the footer and, last, the faces.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Display,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        [int] $Index,
        [string[]] $Info = @(),
        [hashtable] $ItemInfo,
        [string] $Message,
        [string] $EscapeLabel,
        # Main, Menu or About: picks the face spots.
        [string] $Kind = 'Menu',
        [string] $Mode = 'Standard',
        # About: the box stops here and Wrench stands to its right.
        [int] $BoxRight = 79
    )

    $g = $script:AfGlyph
    $theme = Get-AfTheme -Mode $Mode
    $state = Get-AfUiState
    $screen = New-AfScreen
    if ($Display.Tile) { Add-AfTile -Screen $screen }
    Add-AfBannerArea -Screen $screen -Mode $Mode -Style $Display.Style -IsAdmin $state.IsAdmin -Online $state.Online -Redacted $state.Redacted

    $right = $BoxRight
    if ($ItemInfo) { $right = 51 }
    $width = $right - 2 - 3
    # Lines that already fit keep their own spacing; longer ones are wrapped.
    $infoLines = @(foreach ($line in $Info) { if ($line.Length -gt $width) { Split-AfText -Text $line -Width $width } else { $line } })
    $dividers = @($Items | Where-Object { $_.Divider }).Count
    $rows = $infoLines.Count + $Items.Count + $dividers
    if ($infoLines.Count) { $rows++ }
    $bottom = [math]::Min(21, [math]::Max(17, 6 + $rows + 1))
    Add-AfBox -Screen $screen -Top 6 -Left 2 -Bottom $bottom -Right $right -Title $Title -Frame $theme.Frame -Accent $theme.Accent

    $row = 7
    foreach ($line in $infoLines) { Set-AfText -Screen $screen -Row $row -Col 4 -Text $line -Fg 'White'; $row++ }
    if ($infoLines.Count) { $row++ }
    for ($i = 0; $i -lt $Items.Count -and $row -lt $bottom; $i++) {
        $selected = $i -eq $Index
        $color = 'Gray'
        $marker = ' '
        if ($selected) { $color = $theme.Accent; $marker = $g.Pointer }
        $number = ' '
        if ($i -lt 9) { $number = [string]($i + 1) }
        Set-AfText -Screen $screen -Row $row -Col 4 -Text ('{0}  {1}  ' -f $marker, $number) -Fg $color
        $col = 10
        $label = [string]$Items[$i].Label
        $at = $label.IndexOf('&')
        if ($at -ge 0 -and $at -lt $label.Length - 1) {
            $before = $label.Substring(0, $at)
            Set-AfText -Screen $screen -Row $row -Col $col -Text $before -Fg $color
            Set-AfText -Screen $screen -Row $row -Col ($col + $before.Length) -Text ('({0})' -f $label[$at + 1]) -Fg 'Yellow'
            $rest = $label.Substring($at + 2)
            Set-AfText -Screen $screen -Row $row -Col ($col + $before.Length + 3) -Text $rest -Fg $color
            $length = $before.Length + 3 + $rest.Length
        }
        else {
            Set-AfText -Screen $screen -Row $row -Col $col -Text $label -Fg $color
            $length = $label.Length
        }
        if ($Items[$i].Tags) { Set-AfText -Screen $screen -Row $row -Col ($col + $length + 3) -Text $Items[$i].Tags -Fg 'DarkGray' }
        $row++
        if ($Items[$i].Divider -and $row -lt $bottom) { Add-AfDivider -Screen $screen -Row $row -Left 2 -Right $right -Frame $theme.Frame; $row++ }
    }

    if ($ItemInfo) {
        Add-AfBox -Screen $screen -Top 6 -Left 52 -Bottom $bottom -Right 79 -Title 'What this does' -Frame $theme.Frame -Accent $theme.Accent
        $lines = @($ItemInfo[[string]$Items[$Index].Key])
        $infoRow = 7
        foreach ($text in $lines) {
            $parts = @('')
            if ($text) { $parts = @(Split-AfText -Text $text -Width 24) }
            foreach ($part in $parts) {
                if ($infoRow -ge $bottom) { break }
                Set-AfText -Screen $screen -Row $infoRow -Col 54 -Text $part -Fg 'Gray'
                $infoRow++
            }
        }
    }

    if ($Message -and $bottom -lt 21) {
        Clear-AfArea -Screen $screen -Top ($bottom + 1) -Left 2 -Bottom ($bottom + 1) -Right 79
        Set-AfText -Screen $screen -Row ($bottom + 1) -Col 3 -Text $Message -Fg 'Yellow'
    }
    if ($Display.Style -eq 'Branded' -and $Kind -eq 'About') {
        # Wrench stands on a clear patch, so no tile marks show between the pixels.
        Clear-AfArea -Screen $screen -Top 8 -Left 59 -Bottom 16 -Right 76
        Add-AfPixelArt -Screen $screen -Pixels $script:AfWrenchArt -Row 8 -Col 59
    }
    Add-AfFooter -Screen $screen -EscapeLabel $EscapeLabel -Frame $theme.Frame -Accent $theme.Accent
    if ($Display.Style -eq 'Branded' -and $Display.Tile) {
        $spots = $script:AfFaceSpots[$Kind]
        if ($Kind -eq 'Main' -and $Mode -eq 'Technician') { $spots = $script:AfFaceSpots.Technician }
        if ($spots) { $null = Add-AfFaces -Screen $screen -Spots $spots }
    }
    return $screen
}

function Exit-AfScreen {
    # Leaves the console as it was found: default colours and a visible cursor.
    [CmdletBinding()]
    param()

    if ($script:AfUi -and $script:AfUi.UsedVt) {
        $e = [char]27
        Write-Host "$e[0m$e[?25h$e[2J$e[H" -NoNewline
    }
    $script:AfUi = $null
}
