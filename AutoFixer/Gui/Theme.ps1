# Colours for the GUI window. Pure functions (no WPF), so Pester can test them on any
# machine: the window code in Window.ps1 turns the result into brushes.
# The window follows Windows: light/dark app mode, the accent colour and high contrast.

$script:AfGuiFolder = $PSScriptRoot
$script:AfHighContrastKeys = @{
    # High contrast uses only the colours Windows sets for it (System.Windows.SystemColors).
    Window = 'sys:Window'; Rail = 'sys:Window'; RailSelected = 'sys:Highlight'; Content = 'sys:Window'
    Card = 'sys:Window'; CardHover = 'sys:Highlight'; Line = 'sys:WindowText'; Text = 'sys:WindowText'
    Muted = 'sys:GrayText'; StatusBar = 'sys:Window'; Accent = 'sys:Highlight'; AccentText = 'sys:HighlightText'
    AccentOnSurface = 'sys:HotTrack'; Focus = 'sys:WindowText'; ProgressTrack = 'sys:Window'
}

function ConvertTo-AfRgb {
    # '#RRGGBB' -> @(r, g, b) as numbers 0-255.
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory)] [string] $Hex)

    if ($Hex -notmatch '^#?([0-9A-Fa-f]{6})$') { throw "Not a #RRGGBB colour: '$Hex'" }
    $h = $Matches[1]
    return @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function ConvertTo-AfHex {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [double[]] $Rgb)

    $parts = foreach ($c in $Rgb) { [int][math]::Max(0, [math]::Min(255, [math]::Round($c))) }
    return ('#{0:X2}{1:X2}{2:X2}' -f $parts[0], $parts[1], $parts[2])
}

function Get-AfMixedColor {
    # Moves colour A toward colour B by Amount (0 = A, 1 = B).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $From, [Parameter(Mandatory)] [string] $To, [Parameter(Mandatory)] [double] $Amount)

    $a = ConvertTo-AfRgb $From
    $b = ConvertTo-AfRgb $To
    return (ConvertTo-AfHex @(($a[0] + ($b[0] - $a[0]) * $Amount), ($a[1] + ($b[1] - $a[1]) * $Amount), ($a[2] + ($b[2] - $a[2]) * $Amount)))
}

function Get-AfContrastRatio {
    # WCAG contrast ratio between two colours: 1 (same) to 21 (black on white).
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)] [string] $Foreground, [Parameter(Mandatory)] [string] $Background)

    $lum = {
        param($hex)
        $sum = 0.0
        $weights = @(0.2126, 0.7152, 0.0722)
        $rgb = ConvertTo-AfRgb $hex
        for ($i = 0; $i -lt 3; $i++) {
            $c = $rgb[$i] / 255.0
            if ($c -le 0.03928) { $c = $c / 12.92 } else { $c = [math]::Pow(($c + 0.055) / 1.055, 2.4) }
            $sum += $weights[$i] * $c
        }
        $sum
    }
    $l1 = & $lum $Foreground
    $l2 = & $lum $Background
    return (([math]::Max($l1, $l2) + 0.05) / ([math]::Min($l1, $l2) + 0.05))
}

function Get-AfReadableColor {
    # Darkens (or lightens) Color toward Toward in small steps until it reaches MinRatio
    # against Background. Used so any Windows accent colour stays readable.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Color,
        [Parameter(Mandatory)] [string] $Background,
        [Parameter(Mandatory)] [string] $Toward,
        [double] $MinRatio = 4.5
    )

    $current = $Color
    for ($step = 1; $step -le 20 -and (Get-AfContrastRatio $current $Background) -lt $MinRatio; $step++) {
        $current = Get-AfMixedColor -From $Color -To $Toward -Amount ($step * 0.05)
    }
    return $current
}

function ConvertFrom-AfAbgr {
    # Windows stores the accent colour as a DWORD 0xAABBGGRR. Returns '#RRGGBB'.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [long] $Value)

    $v = [uint32]($Value -band 0xFFFFFFFFL)
    return ('#{0:X2}{1:X2}{2:X2}' -f ($v -band 0xFF), (($v -shr 8) -band 0xFF), (($v -shr 16) -band 0xFF))
}

function Get-AfWindowsTheme {
    <#
    .SYNOPSIS
        Reads the user's Windows colour settings: light or dark app mode, the accent colour
        and high contrast. Only reads the current user's registry; changes nothing.
    #>
    [CmdletBinding()]
    param()

    $appsLight = $true
    $accent = '#0067C0'
    $highContrast = $false
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        $appsLight = ([int]$v -ne 0)
    }
    catch { Write-Verbose 'No AppsUseLightTheme value: using light.' }
    try {
        # Windows 10 and 11 both keep the chosen accent here.
        $a = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -ErrorAction Stop
        $accent = ConvertFrom-AfAbgr -Value ([long]$a)
    }
    catch { Write-Verbose 'No AccentColor value: using the Windows default blue.' }
    try {
        $flags = Get-ItemPropertyValue -Path 'HKCU:\Control Panel\Accessibility\HighContrast' -Name 'Flags' -ErrorAction Stop
        $highContrast = (([int]$flags -band 1) -eq 1)
    }
    catch { Write-Verbose 'No HighContrast flags: high contrast off.' }
    [pscustomobject]@{ AppsLight = $appsLight; Accent = $accent; HighContrast = $highContrast }
}

function Resolve-AfThemeBase {
    # Settings Theme (System, Light or Dark) + the Windows app mode -> 'Light' or 'Dark'.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Setting = 'System', [bool] $AppsLight = $true)

    if ($Setting -eq 'Light' -or $Setting -eq 'Dark') { return $Setting }
    if ($AppsLight) { return 'Light' }
    return 'Dark'
}

function Read-AfThemeFile {
    [CmdletBinding()]
    param([string] $Path = (Join-Path $script:AfGuiFolder 'theme.json'))

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-AfTintPair {
    # A meaning colour (group or tag) as text + background for the light or dark base.
    # Light: the colours from theme.json. Dark: text lightened toward white, background
    # a dim wash of the colour over the card. Both are checked for 4.5:1.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Pair, [Parameter(Mandatory)] [string] $Base, [Parameter(Mandatory)] [string] $Card)

    if ($Base -eq 'Light') {
        $fg = Get-AfReadableColor -Color ([string]$Pair.fg) -Background ([string]$Pair.bg) -Toward '#000000'
        return [pscustomobject]@{ Fg = $fg.ToUpperInvariant(); Bg = ([string]$Pair.bg).ToUpperInvariant() }
    }
    $bg = Get-AfMixedColor -From $Card -To ([string]$Pair.fg) -Amount 0.27
    $fg = Get-AfMixedColor -From ([string]$Pair.fg) -To '#FFFFFF' -Amount 0.45
    $fg = Get-AfReadableColor -Color $fg -Background $bg -Toward '#FFFFFF'
    return [pscustomobject]@{ Fg = $fg; Bg = $bg }
}

function Get-AfThemePalette {
    <#
    .SYNOPSIS
        Builds every colour the window uses. Returns Base (Light, Dark or HighContrast),
        Colors (name -> '#RRGGBB', or 'sys:<name>' in high contrast), Groups and Tags
        (name -> Fg/Bg) and the mode badges.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Light', 'Dark')] [string] $Base = 'Light',
        [string] $Accent = '#0067C0',
        [switch] $HighContrast,
        $ThemeData = (Read-AfThemeFile)
    )

    $colors = [ordered]@{}
    $groups = [ordered]@{}
    $tags = [ordered]@{}
    $badges = [ordered]@{}
    if ($HighContrast) {
        foreach ($k in $script:AfHighContrastKeys.Keys) { $colors[$k] = $script:AfHighContrastKeys[$k] }
        foreach ($g in $ThemeData.groups.PSObject.Properties.Name) { $groups[$g] = [pscustomobject]@{ Fg = 'sys:WindowText'; Bg = 'sys:Window' } }
        foreach ($t in $ThemeData.tags.PSObject.Properties.Name) { $tags[$t] = [pscustomobject]@{ Fg = 'sys:WindowText'; Bg = 'sys:Window' } }
        foreach ($m in $ThemeData.modeBadge.PSObject.Properties.Name) { $badges[$m] = [pscustomobject]@{ Fg = 'sys:HighlightText'; Bg = 'sys:Highlight' } }
        return [pscustomobject]@{ Base = 'HighContrast'; Colors = $colors; Groups = $groups; Tags = $tags; Badges = $badges }
    }

    $baseData = $ThemeData.light
    if ($Base -eq 'Dark') { $baseData = $ThemeData.dark }
    foreach ($p in $baseData.PSObject.Properties) { $colors[$p.Name] = ([string]$p.Value).ToUpperInvariant() }

    # Accent fill (buttons, progress bar, selected marker): keep the Windows accent, but make
    # sure its text reads at 4.5:1. Text goes white on dark accents and black on light ones.
    $accent = (ConvertTo-AfHex (ConvertTo-AfRgb $Accent))
    $onWhite = Get-AfContrastRatio '#FFFFFF' $accent
    $onBlack = Get-AfContrastRatio '#000000' $accent
    if ($onWhite -ge $onBlack) {
        $colors['AccentText'] = '#FFFFFF'
        $colors['Accent'] = Get-AfReadableColor -Color $accent -Background '#FFFFFF' -Toward '#000000'
    }
    else {
        $colors['AccentText'] = '#000000'
        $colors['Accent'] = Get-AfReadableColor -Color $accent -Background '#000000' -Toward '#FFFFFF'
    }
    # Accent used as text or a thin line on the window (links, selected item, focus ring).
    $toward = '#000000'
    if ($Base -eq 'Dark') { $toward = '#FFFFFF' }
    $colors['AccentOnSurface'] = Get-AfReadableColor -Color $accent -Background $colors['Card'] -Toward $toward
    $colors['Focus'] = $colors['AccentOnSurface']
    $colors['ProgressTrack'] = $colors['Line']

    foreach ($g in $ThemeData.groups.PSObject.Properties) { $groups[$g.Name] = Get-AfTintPair -Pair $g.Value -Base $Base -Card $colors['Card'] }
    foreach ($t in $ThemeData.tags.PSObject.Properties) { $tags[$t.Name] = Get-AfTintPair -Pair $t.Value -Base $Base -Card $colors['Card'] }
    foreach ($m in $ThemeData.modeBadge.PSObject.Properties) { $badges[$m.Name] = [pscustomobject]@{ Fg = [string]$m.Value.fg; Bg = [string]$m.Value.bg } }
    return [pscustomobject]@{ Base = $Base; Colors = $colors; Groups = $groups; Tags = $tags; Badges = $badges }
}

function Get-AfGuiWordmark {
    # Which AUTO-FIXER wordmark file to show (TEAM Creative, raven575 picks 2026-11-11):
    # Herd edition = tile mosaic #10, Plain edition = business lockup #12 in black on light
    # and white on dark. High contrast gets no picture, so the plain text name shows.
    [CmdletBinding()]
    [OutputType([string])]
    param([bool] $Plain, [string] $Base = 'Light')

    if ($Base -eq 'HighContrast') { return $null }
    if (-not $Plain) { return 'wordmark-herd.png' }
    if ($Base -eq 'Dark') { return 'wordmark-plain-white.png' }
    return 'wordmark-plain-black.png'
}

function Read-AfGuiMenu {
    # Reads menu.json: Tiles (Home + left bar) and Footer (Settings, About).
    [CmdletBinding()]
    param([string] $Path = (Join-Path $script:AfGuiFolder 'menu.json'))

    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    [pscustomobject]@{ Tiles = @($data.tiles); Footer = @($data.footer) }
}

function Get-AfAccessKey {
    # 'Se&ttings' -> 'T'. Returns $null when the label has no '&'.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Label)

    $at = $Label.IndexOf('&')
    if ($at -lt 0 -or $at -ge $Label.Length - 1) { return $null }
    return $Label.Substring($at + 1, 1).ToUpperInvariant()
}

function ConvertTo-AfWpfLabel {
    # The console marks access keys with '&'; WPF uses '_'. A real '_' is doubled first.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Label)

    return $Label.Replace('_', '__').Replace('&', '_')
}

$script:AfGuiActions = @('scan', 'report', 'logs', 'settings', 'about', 'soon')

function Test-AfGuiMenu {
    # Checks menu.json against theme.json. Returns one line per problem; none = good.
    # Runs without WPF, so CI on any machine catches a bad tile before anyone sees it.
    [CmdletBinding()]
    [OutputType([string])]
    param($Menu = (Read-AfGuiMenu), $ThemeData = (Read-AfThemeFile))

    $groups = @($ThemeData.groups.PSObject.Properties.Name)
    $tags = @($ThemeData.tags.PSObject.Properties.Name)
    $seenIds = @{}
    # Home uses H; the rest must not clash with it or with each other.
    $seenKeys = @{ H = 'home' }
    foreach ($item in @($Menu.Tiles) + @($Menu.Footer)) {
        $id = [string]$item.id
        if (-not $id) { 'A tile has no id.'; continue }
        if ($seenIds.ContainsKey($id)) { "Tile id '$id' is used twice." }
        $seenIds[$id] = $true
        foreach ($field in 'label', 'icon', 'group', 'action', 'description') {
            if (-not [string]$item.$field) { "Tile '$id' has no $field." }
        }
        if ([string]$item.icon -notmatch '^[0-9A-Fa-f]{4}$') { "Tile '$id' icon '$($item.icon)' is not a 4-digit codepoint." }
        if ($groups -notcontains [string]$item.group) { "Tile '$id' group '$($item.group)' is not in theme.json." }
        foreach ($t in @($item.tags)) { if ($tags -notcontains [string]$t) { "Tile '$id' tag '$t' is not in theme.json." } }
        if ($script:AfGuiActions -notcontains [string]$item.action) { "Tile '$id' action '$($item.action)' is unknown." }
        $changes = (@($item.tags) -contains 'CHG')
        if ($changes -and [string]$item.action -ne 'soon') { "Tile '$id' changes the PC but has no confirm step in this window yet." }
        if ($item.label) {
            $key = Get-AfAccessKey -Label ([string]$item.label)
            if (-not $key) { "Tile '$id' has no access-key letter (&)." }
            elseif ($seenKeys.ContainsKey($key)) { "Tile '$id' uses access key $key, already used by '$($seenKeys[$key])'." }
            else { $seenKeys[$key] = $id }
        }
    }
}

function Get-AfGuiLogo {
    # Which logo file to show (TEAM Creative FIXW-0027 v2, raven575 picked 2026-11-11):
    # Branded = Wrench the Monkey (both eyes open), Plain = the four-bar mark, no mascot.
    # Dark themes get the for-dark versions. High contrast gets no picture.
    [CmdletBinding()]
    [OutputType([string])]
    param([bool] $Plain, [string] $Base = 'Light')

    if ($Base -eq 'HighContrast') { return $null }
    if ($Plain) {
        if ($Base -eq 'Dark') { return 'logo-plain-white.png' }
        return 'logo-plain-black.png'
    }
    if ($Base -eq 'Dark') { return 'logo-branded-dark.png' }
    return 'logo-branded.png'
}

function Get-AfGuiSplashArt {
    # Splash card art file for a base name such as 'splash-herd': '-dark' on dark themes,
    # nothing in high contrast (the card shows its text instead).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Name, [string] $Base = 'Light')

    if ($Base -eq 'HighContrast') { return $null }
    if ($Base -eq 'Dark') { return ('{0}-dark.png' -f $Name) }
    return ('{0}.png' -f $Name)
}
