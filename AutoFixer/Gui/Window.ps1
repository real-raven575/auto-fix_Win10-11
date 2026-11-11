# The Auto-Fixer window (WPF, layout B "Fluent Panel"). Start it with Start-AfGui, or
# Start-AutoFixer.ps1 -Gui, or AutoFix-GUI.bat. Needs Windows and a single-threaded (STA)
# PowerShell; Windows PowerShell 5.1 is STA by default. Nothing here loads WPF until
# Start-AfGui runs, so the module still imports on any machine.
#
# Layout lives in MainWindow.xaml, tiles in menu.json, colours in theme.json + Theme.ps1.
# This PR runs the read-only scan only; tiles that change the PC point to AutoFix.bat.

$script:AfGuiPages = @('PageFirstRun', 'PageHome', 'PageScan', 'PageSoon', 'PageSettings', 'PageAbout')
$script:AfGuiNames = @(
    'RailColumn', 'LogoImage', 'AppNamePanel', 'WordmarkImage', 'AppNameText', 'HerdLine', 'Rail', 'RailFooter', 'ModeBadge', 'ModeBadgeText', 'HeaderText',
    'PageScroll', 'FirstRunHerd', 'FirstRunPlain', 'FirstRunHerdArt', 'FirstRunPlainArt', 'FirstRunStandard', 'FirstRunTechnician', 'HomeIntro', 'TileHost', 'HomeLegend', 'ScanIntro', 'ScanPercent',
    'ScanStep', 'ScanBar', 'ScanTime', 'ScanStart', 'ScanOpenReport', 'ScanActivity', 'FindingsTitle', 'FindingsHost', 'SoonText',
    'ModeStandard', 'ModeTechnician', 'ShowSensitiveBox', 'SaveSensitiveBox', 'OnlineBox', 'StyleBranded', 'StylePlain',
    'ThemeSystem', 'ThemeLight', 'ThemeDark', 'AboutHost', 'StatusHost'
) + $script:AfGuiPages

# Severity word -> the tag colours that show it. The word itself is always on screen.
$script:AfGuiSeverityTag = @{ Critical = 'FAIL'; High = 'FAIL'; Medium = 'WARN'; Low = 'INFO'; Info = 'INFO' }
$script:AfGuiStatusTag = @{ Done = 'OK'; Skipped = 'WARN'; Failed = 'FAIL'; Running = 'INFO' }

$script:AfGuiScanScript = {
    # Runs in its own runspace so the window never freezes. Sends redacted events back.
    param($ModulePath, $Days, $OutputRoot, $ShowOnScreen, $SaveUnredacted, $Sync)
    try {
        Import-Module $ModulePath -Force
        $redactor = New-AfRedactor -Disabled:$ShowOnScreen
        $onEvent = {
            param($e)
            $summary = $null
            if ($e.Summary) { $summary = Protect-AfText -Redactor $redactor -Text ([string]$e.Summary) }
            $Sync.Events.Enqueue([pscustomobject]@{
                    Type = $e.Type; Step = $e.Step; Index = $e.Index; Total = $e.Total; Status = $e.Status
                    Percent = $e.Percent; SecondsLeft = $e.SecondsLeft; Elapsed = $e.Elapsed; Summary = $summary
                })
        }
        $result = Invoke-AutoFixerScan -Days $Days -Redactor $redactor -OnEvent $onEvent
        $Sync.Saving = $true
        $fileRedactor = $redactor
        if (-not $redactor.Enabled) { $fileRedactor = $null }
        $saved = Export-AutoFixerReport -Result $result -OutputRoot $OutputRoot -Redactor $fileRedactor -IncludeSensitive:$SaveUnredacted
        $Sync.Html = $saved.Html
        $Sync.Failed = @($result.Steps | Where-Object { $_.Status -eq 'Failed' }).Count
        $Sync.Findings = @(foreach ($f in $result.Findings) {
                [pscustomobject]@{
                    Severity    = [string]$f.Severity
                    Title       = Protect-AfText -Redactor $redactor -Text ([string]$f.Title)
                    Explanation = Protect-AfText -Redactor $redactor -Text ([string]$f.Explanation)
                    Count       = $f.Count
                }
            })
    }
    catch { $Sync.Error = $_.Exception.Message }
    finally { $Sync.Done = $true }
}

function Test-AfGuiSupported {
    # Returns $null when the window can open here, or one line saying why not.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return 'The Auto-Fixer window needs Windows 10 or 11.' }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        return 'The Auto-Fixer window needs a single-threaded PowerShell. Use AutoFix-GUI.bat, or start PowerShell with -STA.'
    }
    return $null
}

function ConvertTo-AfBrush {
    # '#RRGGBB' -> a frozen brush; 'sys:Window' -> the Windows high contrast brush.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Value)

    if ($Value.StartsWith('sys:')) {
        $name = '{0}Brush' -f $Value.Substring(4)
        return [System.Windows.Media.Brush]([System.Windows.SystemColors]::$name)
    }
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Value))
    $brush.Freeze()
    # New-Object wraps the brush in a PSObject. Stored as-is in Window.Resources, WPF
    # rejects it ("not a valid value for property 'Background'"), so hand back the brush.
    return $brush.psobject.BaseObject
}

function Set-AfGuiTitleBar {
    # Dark title bar in dark mode (Windows 10 2004+ and 11). Skipped quietly elsewhere.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Window, [bool] $Dark)

    try {
        if (-not ('AutoFixerGui.Dwm' -as [type])) {
            Add-Type -Namespace AutoFixerGui -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);'
        }
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $value = [int]$Dark
        # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE; 19 on Windows 10 builds before 20H1.
        if ([AutoFixerGui.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$value, 4) -ne 0) {
            [void][AutoFixerGui.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$value, 4)
        }
    }
    catch { Write-Verbose ('Title bar colour not set: {0}' -f $_.Exception.Message) }
}

function Update-AfGuiTheme {
    # Reads the Windows colours and refills every brush key. DynamicResource does the rest,
    # so the open window changes on the spot. Returns $true when something changed.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Window, [Parameter(Mandatory)] [hashtable] $State, [switch] $Force)

    $win = Get-AfWindowsTheme
    $highContrast = $win.HighContrast -or [System.Windows.SystemParameters]::HighContrast
    $setting = 'System'
    if ($State.Settings) { $setting = [string]$State.Settings.Theme }
    $signature = '{0}|{1}|{2}|{3}' -f $win.AppsLight, $win.Accent, $highContrast, $setting
    if (-not $Force -and $signature -eq $State.ThemeSignature) { return $false }
    $State.ThemeSignature = $signature

    $base = Resolve-AfThemeBase -Setting $setting -AppsLight $win.AppsLight
    $palette = Get-AfThemePalette -Base $base -Accent $win.Accent -HighContrast:$highContrast -ThemeData $State.ThemeData
    $res = $Window.Resources
    foreach ($k in $palette.Colors.Keys) { $res[('{0}Brush' -f $k)] = ConvertTo-AfBrush $palette.Colors[$k] }
    foreach ($k in $palette.Groups.Keys) {
        $res[('Group_{0}_Fg' -f $k)] = ConvertTo-AfBrush $palette.Groups[$k].Fg
        $res[('Group_{0}_Bg' -f $k)] = ConvertTo-AfBrush $palette.Groups[$k].Bg
    }
    foreach ($k in $palette.Tags.Keys) {
        $res[('Tag_{0}_Fg' -f $k)] = ConvertTo-AfBrush $palette.Tags[$k].Fg
        $res[('Tag_{0}_Bg' -f $k)] = ConvertTo-AfBrush $palette.Tags[$k].Bg
    }
    foreach ($k in $palette.Badges.Keys) {
        $res[('Badge_{0}_Fg' -f $k)] = ConvertTo-AfBrush $palette.Badges[$k].Fg
        $res[('Badge_{0}_Bg' -f $k)] = ConvertTo-AfBrush $palette.Badges[$k].Bg
    }
    $State.Base = $palette.Base
    Set-AfGuiTitleBar -Window $Window -Dark ($palette.Base -eq 'Dark')
    return $true
}

function New-AfGuiText {
    [CmdletBinding()]
    param([string] $Text, [string] $Brush, [double] $Size = 0, [switch] $SemiBold, [switch] $Wrap, [switch] $Icon)

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    if ($Brush) { $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Brush) }
    if ($Size -gt 0) { $t.FontSize = $Size }
    if ($SemiBold) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    if ($Icon) {
        $t.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'
        $t.VerticalAlignment = 'Center'
    }
    return $t
}

function New-AfGuiChip {
    # A small tag such as ADMIN or HIGH: the word stays, colour only repeats it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Word, [Parameter(Mandatory)] [string] $TagKey, [string] $Glyph)

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = 4
    $border.Padding = '6,1'
    $border.Margin = '0,0,6,0'
    $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, ('Tag_{0}_Bg' -f $TagKey))
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    if ($Glyph) {
        $g = New-AfGuiText -Text ([string][char][Convert]::ToInt32($Glyph, 16)) -Brush ('Tag_{0}_Fg' -f $TagKey) -Size 11 -Icon
        $g.Margin = '0,0,4,0'
        [void]$panel.Children.Add($g)
    }
    [void]$panel.Children.Add((New-AfGuiText -Text $Word -Brush ('Tag_{0}_Fg' -f $TagKey) -Size 11 -SemiBold))
    $border.Child = $panel
    return $border
}

function Get-AfGuiTagGlyph {
    # Segoe icon codepoint shown next to a tag word. The word is always shown too.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Tag)
    $glyphs = @{ ADMIN = 'EA18'; CHG = 'E70F'; OK = 'E930'; WARN = 'E7BA'; FAIL = 'EA39'; INFO = 'E946'; SOON = 'E823'; TECHNICIAN = 'E90F' }
    return $glyphs[$Tag]
}

function New-AfGuiTile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item, [Parameter(Mandatory)] $Window)

    $button = New-Object System.Windows.Controls.Button
    $button.Style = $Window.FindResource('Tile')
    $button.Tag = $Item
    $plain = ([string]$Item.label).Replace('&', '')
    $words = @($Item.tags) -join ', '
    [System.Windows.Automation.AutomationProperties]::SetName($button, (($plain, $words) -join ' ').Trim())
    [System.Windows.Automation.AutomationProperties]::SetHelpText($button, [string]$Item.description)
    $button.ToolTip = [string]$Item.description

    $grid = New-Object System.Windows.Controls.DockPanel
    $iconBox = New-Object System.Windows.Controls.Border
    $iconBox.Width = 40; $iconBox.Height = 40; $iconBox.CornerRadius = 8
    $iconBox.HorizontalAlignment = 'Left'
    $iconBox.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, ('Group_{0}_Bg' -f $Item.group))
    $glyph = New-AfGuiText -Text ([string][char][Convert]::ToInt32([string]$Item.icon, 16)) -Brush ('Group_{0}_Fg' -f $Item.group) -Size 20 -Icon
    $glyph.HorizontalAlignment = 'Center'
    $iconBox.Child = $glyph
    [System.Windows.Controls.DockPanel]::SetDock($iconBox, 'Top')
    [void]$grid.Children.Add($iconBox)

    $label = New-Object System.Windows.Controls.AccessText
    $label.Text = ConvertTo-AfWpfLabel ([string]$Item.label)
    $label.FontSize = 15
    $label.FontWeight = [System.Windows.FontWeights]::SemiBold
    $label.Margin = '0,10,0,6'
    $label.TextWrapping = 'Wrap'
    [System.Windows.Controls.DockPanel]::SetDock($label, 'Top')
    [void]$grid.Children.Add($label)

    $chips = New-Object System.Windows.Controls.WrapPanel
    foreach ($tag in @($Item.tags)) { [void]$chips.Children.Add((New-AfGuiChip -Word $tag -TagKey $tag -Glyph (Get-AfGuiTagGlyph $tag))) }
    if (@($Item.tags).Count -eq 0 -and $Item.id -eq 'scan') { [void]$chips.Children.Add((New-AfGuiChip -Word 'READ-ONLY' -TagKey 'OK' -Glyph 'E930')) }
    [System.Windows.Controls.DockPanel]::SetDock($chips, 'Bottom')
    $chips.VerticalAlignment = 'Bottom'
    [void]$grid.Children.Add($chips)
    $button.Content = $grid
    return $button
}

function New-AfGuiRailItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item, [Parameter(Mandatory)] [hashtable] $State)

    $li = New-Object System.Windows.Controls.ListBoxItem
    $li.Tag = $Item
    $plain = ([string]$Item.label).Replace('&', '')
    $li.ToolTip = $plain
    [System.Windows.Automation.AutomationProperties]::SetName($li, $plain)
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $glyph = New-AfGuiText -Text ([string][char][Convert]::ToInt32([string]$Item.icon, 16)) -Brush ('Group_{0}_Fg' -f $Item.group) -Size 16 -Icon
    $glyph.Width = 20
    [void]$panel.Children.Add($glyph)
    $label = New-AfGuiText -Text $plain
    $label.Margin = '12,0,0,0'
    $label.VerticalAlignment = 'Center'
    [void]$panel.Children.Add($label)
    $State.RailLabels.Add($label)
    $li.Content = $panel
    return $li
}

function Set-AfGuiArt {
    # Shows Art\<File> in an Image, or hides the Image when there is no file. Returns $true when shown.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Image, [string] $File)

    if ($File) {
        $path = Join-Path (Join-Path $script:AfGuiFolder 'Art') $File
        if (Test-Path -LiteralPath $path) {
            $Image.Source = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri]$path)
            $Image.Visibility = 'Visible'
            return $true
        }
    }
    $Image.Visibility = 'Collapsed'
    return $false
}

function Set-AfGuiWindowIcon {
    # Title-bar and taskbar icon from Art\<File>; leaves the default icon when there is none.
    [CmdletBinding()]
    param($Window, [string] $File)

    if (-not $Window -or -not $File) { return }
    $path = Join-Path (Join-Path $script:AfGuiFolder 'Art') $File
    if (Test-Path -LiteralPath $path) { $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$path) }
}

function Update-AfGuiChrome {
    # Mode badge, Branded/Plain bits, status bar. Call after any settings change.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State)

    $s = $State.Settings
    $mode = 'Standard'
    if ($s) { $mode = [string]$s.Mode }
    $Ui.ModeBadgeText.Text = ('{0} MODE' -f $mode.ToUpperInvariant())
    $Ui.ModeBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, ('Badge_{0}_Bg' -f $mode))
    $Ui.ModeBadgeText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, ('Badge_{0}_Fg' -f $mode))
    [System.Windows.Automation.AutomationProperties]::SetName($Ui.ModeBadge, ('{0} mode' -f $mode))

    $plain = $State.ForcePlain -or ($s -and $s.Style -eq 'Plain') -or (-not $s -and $State.FirstRunStyle -eq 'Plain')
    # AUTO-FIXER wordmark in place of the plain text name; the text stays for high contrast.
    $shown = Set-AfGuiArt -Image $Ui.WordmarkImage -File (Get-AfGuiWordmark -Plain $plain -Base $State.Base)
    if ($shown) { $Ui.AppNameText.Visibility = 'Collapsed' } else { $Ui.AppNameText.Visibility = 'Visible' }
    [void](Set-AfGuiArt -Image $Ui.FirstRunHerdArt -File (Get-AfGuiWordmark -Plain $false -Base $State.Base))
    [void](Set-AfGuiArt -Image $Ui.FirstRunPlainArt -File (Get-AfGuiWordmark -Plain $true -Base $State.Base))
    if ($plain) { $Ui.HerdLine.Visibility = 'Collapsed' } else { $Ui.HerdLine.Visibility = 'Visible' }
    # Left-bar logo: Wrench in Branded. The Plain lockup already starts with the four-bar
    # mark, so Plain shows the mark here only when the lockup can't show.
    $logo = Get-AfGuiLogo -Plain $plain -Base $State.Base
    if ($plain -and $shown) { $logo = $null }
    [void](Set-AfGuiArt -Image $Ui.LogoImage -File $logo)
    Set-AfGuiWindowIcon -Window $Ui.Window -File (Get-AfGuiLogo -Plain $plain -Base $State.Base)

    $Ui.StatusHost.Children.Clear()
    $add = {
        param($glyph, $text)
        $p = New-Object System.Windows.Controls.StackPanel
        $p.Orientation = 'Horizontal'
        $p.Margin = '0,0,24,0'
        $g = New-AfGuiText -Text ([string][char][Convert]::ToInt32($glyph, 16)) -Brush 'MutedBrush' -Size 12 -Icon
        $g.Margin = '0,0,6,0'
        [void]$p.Children.Add($g)
        [void]$p.Children.Add((New-AfGuiText -Text $text -Brush 'MutedBrush' -Size 12))
        [System.Windows.Automation.AutomationProperties]::SetName($p, $text)
        [void]$Ui.StatusHost.Children.Add($p)
    }
    $show = $s -and $s.ShowSensitive
    $pc = [Environment]::MachineName
    if (-not $show) { $pc = Protect-AfText -Redactor $State.Redactor -Text $pc }
    & $add 'E7F4' ('PC: {0}' -f $pc)
    $admin = 'No (some logs are skipped)'
    if ($State.IsAdmin) { $admin = 'Yes' }
    & $add 'EA18' ('Administrator: {0}' -f $admin)
    $net = 'Off'
    if ($s -and $s.Online) { $net = 'On only when a step needs it (asks first)' }
    & $add 'E774' ('Internet: {0}' -f $net)
    $red = 'redacted'
    if ($show) { $red = 'shown on screen' }
    & $add 'E72E' ('Sensitive data: {0}' -f $red)
    & $add 'E823' 'Background run: none'
    if ($State.Note) { & $add 'E946' $State.Note }
}

function Show-AfGuiPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State, [Parameter(Mandatory)] [string] $Page, [string] $Title)

    foreach ($p in $script:AfGuiPages) { $Ui[$p].Visibility = 'Collapsed' }
    $Ui[$Page].Visibility = 'Visible'
    if ($Title) { $Ui.HeaderText.Text = $Title }
    $Ui.PageScroll.ScrollToTop()
    $State.Page = $Page
    # A note such as "Opened the logs folder" belongs to the click that made it; clear it on the next page.
    if ($State.Note) {
        $State.Note = $null
        Update-AfGuiChrome -Ui $Ui -State $State
    }
}

function Test-AfGuiPassScroll {
    <#
    .SYNOPSIS
        True when an inner scroll box can't move any further in the wheel's direction,
        so the wheel should scroll the page instead. Delta > 0 is wheel up.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([double] $Offset, [double] $Scrollable, [int] $Delta)

    if ($Scrollable -le 0) { return $true }
    if ($Delta -gt 0) { return ($Offset -le 0.5) }
    return ($Offset -ge ($Scrollable - 0.5))
}

function Get-AfGuiChildScrollViewer {
    # The ScrollViewer inside a control's template (a ListBox has one).
    param($Element)
    if ($Element -is [System.Windows.Controls.ScrollViewer]) { return $Element }
    if ($Element -isnot [System.Windows.Media.Visual]) { return $null }
    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
    for ($i = 0; $i -lt $count; $i++) {
        $found = Get-AfGuiChildScrollViewer -Element ([System.Windows.Media.VisualTreeHelper]::GetChild($Element, $i))
        if ($found) { return $found }
    }
    return $null
}

function Step-AfGuiScrollChain {
    # PreviewMouseWheel handler body: let the inner box scroll while it can; at its top or
    # bottom (or when it has nothing to scroll) hand the wheel to the page.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inner, [Parameter(Mandatory)] $Outer, [Parameter(Mandatory)] $WheelArgs)

    $viewer = Get-AfGuiChildScrollViewer -Element $Inner
    if ($viewer -and -not (Test-AfGuiPassScroll -Offset $viewer.VerticalOffset -Scrollable $viewer.ScrollableHeight -Delta $WheelArgs.Delta)) { return }
    $WheelArgs.Handled = $true
    $Outer.ScrollToVerticalOffset($Outer.VerticalOffset - $WheelArgs.Delta)
}

function Set-AfGuiRailLock {
    # Locks the left bar on the first-run page. Not IsEnabled: a disabled ListBox paints a
    # bright white system background, even in dark mode.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [bool] $Locked)

    foreach ($list in $Ui.Rail, $Ui.RailFooter) {
        $list.IsHitTestVisible = -not $Locked
        $list.Opacity = 1
        $nav = [System.Windows.Input.KeyboardNavigationMode]::Once
        if ($Locked) { $list.Opacity = 0.45; $nav = [System.Windows.Input.KeyboardNavigationMode]::None }
        [System.Windows.Input.KeyboardNavigation]::SetTabNavigation($list, $nav)
        [System.Windows.Input.KeyboardNavigation]::SetDirectionalNavigation($list, $nav)
    }
}

function Complete-AfGuiFirstRun {
    # Saves the chosen mode, unlocks the left bar and shows Home. Shows the page directly:
    # Invoke-AfGuiItem ignores clicks while the first-run page is open.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [ValidateSet('Standard', 'Technician')] [string] $Mode,
        [ValidateSet('Branded', 'Plain')] [string] $Style = 'Branded'
    )

    $s = Get-AfDefaultSettings
    $s.Mode = $Mode
    $s.Style = $Style
    $State.Settings = $s
    Save-AfSettings -Settings $s -Path $State.SettingsPath
    Set-AfGuiRailLock -Ui $Ui -Locked $false
    Update-AfGuiChrome -Ui $Ui -State $State
    Select-AfGuiRail -Ui $Ui -State $State -Id 'home'
    Show-AfGuiPage -Ui $Ui -State $State -Page 'PageHome' -Title 'Home'
}

function New-AfGuiWindow {
    # Parses MainWindow.xaml and returns the window plus a name -> element table.
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $window = [System.Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath (Join-Path $script:AfGuiFolder 'MainWindow.xaml') -Raw))
    $ui = @{}
    foreach ($n in $script:AfGuiNames) { $ui[$n] = $window.FindName($n) }
    # Kept in the table so Update-AfGuiChrome can set the title-bar and taskbar icon.
    $ui.Window = $window
    return @{ Window = $window; Ui = $ui }
}

function Select-AfGuiRail {
    # Marks the rail item for an id without running it again.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State, [string] $Id)

    $State.Syncing = $true
    try {
        foreach ($list in $Ui.Rail, $Ui.RailFooter) {
            $match = $null
            foreach ($li in $list.Items) { if ($li.Tag.id -eq $Id) { $match = $li } }
            $list.SelectedItem = $match
        }
    }
    finally { $State.Syncing = $false }
}

function Invoke-AfGuiItem {
    # What a tile or rail item does.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State, [Parameter(Mandatory)] $Item)

    if ($State.Page -eq 'PageFirstRun') { return }
    $title = ([string]$Item.label).Replace('&', '')
    Select-AfGuiRail -Ui $Ui -State $State -Id $Item.id
    switch ([string]$Item.action) {
        'home' { Show-AfGuiPage -Ui $Ui -State $State -Page 'PageHome' -Title 'Home' }
        'scan' { Show-AfGuiPage -Ui $Ui -State $State -Page 'PageScan' -Title $title; $Ui.ScanStart.Focus() | Out-Null }
        'settings' { Sync-AfGuiSettingsPage -Ui $Ui -State $State; Show-AfGuiPage -Ui $Ui -State $State -Page 'PageSettings' -Title 'Settings' }
        'about' { Show-AfGuiPage -Ui $Ui -State $State -Page 'PageAbout' -Title 'About and credits' }
        'report' {
            $run = @(Get-AfReportRun -OutputRoot $State.OutputRoot -Count 1)
            if ($run.Count -gt 0 -and (Test-Path -LiteralPath $run[0].Html)) { Invoke-Item -LiteralPath $run[0].Html; $State.Note = 'Opened the last report in your browser.' }
            else { $State.Note = 'No saved scan yet. Run a scan first.' }
            Update-AfGuiChrome -Ui $Ui -State $State
        }
        'logs' {
            $State.Note = Protect-AfText -Redactor $State.Redactor -Text (Open-AfLogFolder -OutputRoot $State.OutputRoot)
            Update-AfGuiChrome -Ui $Ui -State $State
        }
        default {
            $Ui.SoonText.Text = [string]$Item.description
            Show-AfGuiPage -Ui $Ui -State $State -Page 'PageSoon' -Title $title
        }
    }
}

function Sync-AfGuiSettingsPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State)

    $s = $State.Settings
    $State.Loading = $true
    try {
        $Ui.ModeStandard.IsChecked = ($s.Mode -eq 'Standard')
        $Ui.ModeTechnician.IsChecked = ($s.Mode -eq 'Technician')
        $Ui.ShowSensitiveBox.IsChecked = [bool]$s.ShowSensitive
        $Ui.SaveSensitiveBox.IsChecked = [bool]$s.SaveSensitive
        $Ui.OnlineBox.IsChecked = [bool]$s.Online
        $Ui.StyleBranded.IsChecked = ($s.Style -ne 'Plain')
        $Ui.StylePlain.IsChecked = ($s.Style -eq 'Plain')
        $Ui.ThemeSystem.IsChecked = ($s.Theme -eq 'System')
        $Ui.ThemeLight.IsChecked = ($s.Theme -eq 'Light')
        $Ui.ThemeDark.IsChecked = ($s.Theme -eq 'Dark')
    }
    finally { $State.Loading = $false }
}

function Show-AfGuiQuestion {
    # Yes/No box; No is the default. Y and N work as keys, like the console.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Window, [Parameter(Mandatory)] [string] $Text, [string] $Icon = 'Warning')

    $answer = [System.Windows.MessageBox]::Show($Window, $Text, 'Auto-Fixer: Are you sure?', 'YesNo', $Icon, 'No')
    return ($answer -eq 'Yes')
}

function Get-AfGuiText {
    # The warning texts, word for word the same as the console's.
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateSet('Technician', 'Online', 'SaveSensitive')] [string] $Name)

    switch ($Name) {
        'Technician' { 'WARNING: Technician mode runs repairs such as SFC and DISM with one key, without the extra step-by-step questions Standard mode asks. Steps that delete data, are permanent or go online still warn first. Choose it only if you know these tools and accept responsibility for the changes.' + [Environment]::NewLine + [Environment]::NewLine + 'Are you sure?' }
        'Online' { 'With this on, a step may connect to the internet when it needs to. Each connection is announced first, and only these places are ever contacted:' + [Environment]::NewLine + '    Windows Update (Microsoft): DISM RestoreHealth downloads clean system files.' + [Environment]::NewLine + 'Auto-Fixer never sends your data anywhere.' + [Environment]::NewLine + [Environment]::NewLine + 'Turn it on?' }
        'SaveSensitive' { 'Saved reports will contain real names, serial numbers, addresses and other personal data. Anyone who opens the files can read them.' + [Environment]::NewLine + [Environment]::NewLine + 'Are you sure?' }
    }
}

function Save-AfGuiSettings {
    # Saves settings.json at once, then refreshes the status bar and colours.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State, [Parameter(Mandatory)] $Window)
    Save-AfSettings -Settings $State.Settings -Path $State.SettingsPath
    Update-AfGuiChrome -Ui $Ui -State $State
    [void](Update-AfGuiTheme -Window $Window -State $State)
}

function Add-AfGuiActivity {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [string] $Word, [Parameter(Mandatory)] [string] $TagKey, [Parameter(Mandatory)] [string] $Text)

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = '0,2'
    [void]$row.Children.Add((New-AfGuiChip -Word $Word -TagKey $TagKey -Glyph (Get-AfGuiTagGlyph $TagKey)))
    [void]$row.Children.Add((New-AfGuiText -Text $Text -Brush 'TextBrush'))
    [System.Windows.Automation.AutomationProperties]::SetName($row, ('{0}: {1}' -f $Word, $Text))
    [void]$Ui.ScanActivity.Items.Add($row)
    $Ui.ScanActivity.ScrollIntoView($row)
}

function Show-AfGuiFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] $Window, [object[]] $Findings)

    $Ui.FindingsHost.Children.Clear()
    $Ui.FindingsTitle.Visibility = 'Visible'
    if (@($Findings).Count -eq 0) {
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $Window.FindResource('Card')
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        [void]$row.Children.Add((New-AfGuiChip -Word 'OK' -TagKey 'OK' -Glyph 'E930'))
        [void]$row.Children.Add((New-AfGuiText -Text 'No known problems found.' -Brush 'TextBrush'))
        $card.Child = $row
        [void]$Ui.FindingsHost.Children.Add($card)
        return
    }
    foreach ($f in $Findings) {
        $tag = $script:AfGuiSeverityTag[$f.Severity]
        if (-not $tag) { $tag = 'INFO' }
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $Window.FindResource('Card')
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        [void]$head.Children.Add((New-AfGuiChip -Word $f.Severity.ToUpperInvariant() -TagKey $tag -Glyph (Get-AfGuiTagGlyph $tag)))
        [void]$head.Children.Add((New-AfGuiText -Text $f.Title -Brush 'TextBrush' -SemiBold -Wrap))
        [void]$stack.Children.Add($head)
        $body = New-AfGuiText -Text $f.Explanation -Brush 'MutedBrush' -Wrap
        $body.Margin = '0,6,0,0'
        [void]$stack.Children.Add($body)
        $card.Child = $stack
        [System.Windows.Automation.AutomationProperties]::SetName($card, ('{0}: {1}' -f $f.Severity, $f.Title))
        [void]$Ui.FindingsHost.Children.Add($card)
    }
}

function Start-AfGuiScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State, [Parameter(Mandatory)] $Window)

    if ($State.Scan) { return }
    $s = $State.Settings
    $saveUnredacted = $false
    if ($s.SaveSensitive) {
        $saveUnredacted = Show-AfGuiQuestion -Window $Window -Text (Get-AfGuiText 'SaveSensitive')
        if (-not $saveUnredacted) { Add-AfGuiActivity -Ui $Ui -Word 'INFO' -TagKey 'INFO' -Text 'Keeping redaction on for saved reports.' }
    }

    $sync = [hashtable]::Synchronized(@{ Events = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'; Done = $false; Saving = $false; Error = $null; Html = $null; Findings = $null; Failed = 0 })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:AfGuiScanScript.ToString())
    [void]$ps.AddArgument((Join-Path $script:AfModuleRoot 'AutoFixer.psd1'))
    [void]$ps.AddArgument($State.Days)
    [void]$ps.AddArgument($State.OutputRoot)
    [void]$ps.AddArgument([bool]$s.ShowSensitive)
    [void]$ps.AddArgument($saveUnredacted)
    [void]$ps.AddArgument($sync)
    $State.Scan = @{ PowerShell = $ps; Sync = $sync; Handle = $ps.BeginInvoke() }
    $State.SavingShown = $false

    $Ui.ScanActivity.Items.Clear()
    $Ui.FindingsHost.Children.Clear()
    $Ui.FindingsTitle.Visibility = 'Collapsed'
    $Ui.ScanOpenReport.Visibility = 'Collapsed'
    $Ui.ScanStart.IsEnabled = $false
    $Ui.ScanBar.Value = 0
    $Ui.ScanPercent.Text = '0%'
    $Ui.ScanStep.Text = 'Starting the scan...'
    $Ui.ScanTime.Text = ''
    $Window.TaskbarItemInfo.ProgressState = 'Normal'
    $Window.TaskbarItemInfo.ProgressValue = 0
    $State.ScanTimer.Start()
}

function Update-AfGuiScan {
    # Runs on the window's timer: shows queued progress, then the result.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ui, [Parameter(Mandatory)] [hashtable] $State, [Parameter(Mandatory)] $Window)

    $scan = $State.Scan
    if (-not $scan) { $State.ScanTimer.Stop(); return }
    $e = $null
    while ($scan.Sync.Events.TryDequeue([ref]$e)) {
        $Ui.ScanBar.Value = [double]$e.Percent
        $Ui.ScanPercent.Text = ('{0}%' -f $e.Percent)
        $Window.TaskbarItemInfo.ProgressValue = [double]$e.Percent / 100
        if ($e.Type -eq 'StepStarted') {
            $Ui.ScanStep.Text = ('Step {0} of {1}: {2}' -f ($e.Index + 1), $e.Total, $e.Step)
            if ($null -ne $e.SecondsLeft) { $Ui.ScanTime.Text = ('About {0} s left' -f [int]$e.SecondsLeft) }
        }
        else {
            $tag = $script:AfGuiStatusTag[[string]$e.Status]
            if (-not $tag) { $tag = 'INFO' }
            $line = '{0} - {1} ({2} s)' -f $e.Step, $e.Summary, $e.Elapsed
            Add-AfGuiActivity -Ui $Ui -Word ([string]$e.Status).ToUpperInvariant() -TagKey $tag -Text $line
        }
    }
    if (-not $scan.Sync.Done) {
        if (($scan.Sync.Saving -or $Ui.ScanBar.Value -ge 100) -and -not $State.SavingShown) {
            # The last check is done; the findings analysis and the report still take a while.
            $State.SavingShown = $true
            $Ui.ScanStep.Text = 'All checks done. Working out the findings and saving the report. This can take up to a minute.'
            $Ui.ScanTime.Text = ''
        }
        return
    }

    $State.ScanTimer.Stop()
    try { [void]$scan.PowerShell.EndInvoke($scan.Handle) } catch { Write-Verbose $_.Exception.Message }
    $scan.PowerShell.Dispose()
    $State.Scan = $null
    $Ui.ScanStart.IsEnabled = $true
    $Ui.ScanStart.Content = '_Scan again'
    $Window.TaskbarItemInfo.ProgressState = 'None'
    if ($scan.Sync.Error) {
        $Ui.ScanStep.Text = 'The scan stopped.'
        Add-AfGuiActivity -Ui $Ui -Word 'FAILED' -TagKey 'FAIL' -Text (Protect-AfText -Redactor $State.Redactor -Text $scan.Sync.Error)
        return
    }
    $Ui.ScanBar.Value = 100
    $Ui.ScanPercent.Text = '100%'
    $Ui.ScanTime.Text = ''
    $Ui.ScanStep.Text = 'Scan finished. Nothing on this PC was changed.'
    if ($scan.Sync.Failed -gt 0) { $Ui.ScanStep.Text = ('Scan finished, but {0} step(s) failed (see Activity). Nothing on this PC was changed.' -f $scan.Sync.Failed) }
    $State.LastHtml = $scan.Sync.Html
    if ($State.LastHtml) { $Ui.ScanOpenReport.Visibility = 'Visible' }
    Show-AfGuiFindings -Ui $Ui -Window $Window -Findings $scan.Sync.Findings
}

function Get-AfGuiSplashPlan {
    # Which splash cards to show and for how long (ms). Branded: Herd of Helpers, then
    # Auto-Fixer. Plain: Auto-Fixer only. 3.5 s in all, like the console splash.
    [CmdletBinding()]
    param([bool] $Plain)

    # The Auto-Fixer card shows the AUTO-FIXER wordmark for the look (see Get-AfGuiWordmark).
    $autoFixer = [pscustomobject]@{ Art = $null; Wordmark = $true; Title = 'Auto-Fixer'; Line = 'PC check and repair for Windows 10 and 11'; Ms = 2000 }
    if ($Plain) { $autoFixer.Ms = 3500; return @($autoFixer) }
    $herd = [pscustomobject]@{ Art = 'splash-herd'; Wordmark = $false; Title = 'Herd of Helpers'; Line = 'presents'; Ms = 1500 }
    return @($herd, $autoFixer)
}

function Show-AfGuiSplash {
    # Borderless start card. Any key or click skips it. Art\splash-*.png shows when TEAM
    # Creative's art is added; until then the card is text only.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Resources, [bool] $Plain, [string] $Version, [string] $Base = 'Light')

    $cards = @(Get-AfGuiSplashPlan -Plain $Plain)
    $wordmark = Get-AfGuiWordmark -Plain $Plain -Base $Base
    $splash = New-Object System.Windows.Window
    $splash.Resources = $Resources
    $splash.WindowStyle = 'None'
    $splash.ResizeMode = 'NoResize'
    $splash.ShowInTaskbar = $false
    $splash.Topmost = $true
    $splash.Width = 560; $splash.Height = 320
    $splash.WindowStartupLocation = 'CenterScreen'
    $splash.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Variable Text, Segoe UI'
    $splash.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'CardBrush')
    $splash.SetResourceReference([System.Windows.Window]::BorderBrushProperty, 'AccentOnSurfaceBrush')
    $splash.BorderThickness = 1
    [System.Windows.Automation.AutomationProperties]::SetName($splash, 'Auto-Fixer is starting')

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'
    $stack.HorizontalAlignment = 'Center'
    $art = New-Object System.Windows.Controls.Image
    $art.MaxWidth = 480; $art.MaxHeight = 180; $art.Margin = '0,0,0,12'
    $title = New-AfGuiText -Text '' -Brush 'TextBrush' -Size 40 -SemiBold
    $title.HorizontalAlignment = 'Center'
    $line = New-AfGuiText -Text '' -Brush 'MutedBrush' -Size 16
    $line.HorizontalAlignment = 'Center'
    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.IsIndeterminate = $true; $bar.Height = 4; $bar.Width = 220; $bar.Margin = '0,24,0,8'; $bar.BorderThickness = 0
    $bar.SetResourceReference([System.Windows.Controls.ProgressBar]::ForegroundProperty, 'AccentBrush')
    $bar.SetResourceReference([System.Windows.Controls.ProgressBar]::BackgroundProperty, 'ProgressTrackBrush')
    $foot = New-AfGuiText -Text ('Version {0}   -   press any key to skip' -f $Version) -Brush 'MutedBrush' -Size 12
    $foot.HorizontalAlignment = 'Center'
    foreach ($c in $art, $title, $line, $bar, $foot) { [void]$stack.Children.Add($c) }
    $splash.Content = $stack

    $index = @{ Value = -1 }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $next = {
        $index.Value = $index.Value + 1
        if ($index.Value -ge $cards.Count) { $timer.Stop(); $splash.Close(); return }
        $card = $cards[$index.Value]
        $title.Text = $card.Title
        $line.Text = $card.Line
        $file = $null
        if ($card.Art) { $file = Get-AfGuiSplashArt -Name $card.Art -Base $Base }
        if ($card.Wordmark) { $file = $wordmark }
        # The wordmark already says AUTO-FIXER, so the text title steps aside for it.
        $title.Visibility = 'Visible'
        $line.Visibility = 'Visible'
        if ((Set-AfGuiArt -Image $art -File $file) -and $card.Wordmark) { $title.Visibility = 'Collapsed' }
        $timer.Interval = [TimeSpan]::FromMilliseconds($card.Ms)
    }
    $timer.Add_Tick($next)
    $skip = { $timer.Stop(); $splash.Close() }
    $splash.Add_KeyDown($skip)
    $splash.Add_MouseDown($skip)
    & $next
    $timer.Start()
    [void]$splash.ShowDialog()
}

function Test-AfGuiLoad {
    <#
    .SYNOPSIS
        Loads the window files without showing anything and returns one line per problem
        (none = good). Used by AutoFix-GUI.bat in CI and by the Pester tests.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $why = Test-AfGuiSupported
    if ($why) { return $why }
    @(Test-AfGuiMenu)
    try {
        $parts = New-AfGuiWindow
        $window = $parts.Window
        foreach ($n in $script:AfGuiNames) { if (-not $parts.Ui[$n]) { "MainWindow.xaml has no element named '$n'." } }
        foreach ($style in 'Tile', 'AccentButton', 'PlainButton', 'Card', 'RailItem') {
            if (-not $window.TryFindResource($style)) { "MainWindow.xaml has no '$style' style." }
        }
        $data = Read-AfThemeFile
        foreach ($p in (Get-AfThemePalette -Base Light -ThemeData $data), (Get-AfThemePalette -Base Dark -ThemeData $data), (Get-AfThemePalette -HighContrast -ThemeData $data)) {
            foreach ($v in @($p.Colors.Values) + @($p.Groups.Values | ForEach-Object { $_.Fg; $_.Bg }) + @($p.Tags.Values | ForEach-Object { $_.Fg; $_.Bg })) {
                try { [void](ConvertTo-AfBrush $v) } catch { "Colour '$v' ($($p.Base)) is not a brush: $($_.Exception.Message)" }
            }
        }
        # Put the theme into the window the way Start-AfGui does, so WPF itself checks
        # every brush (a wrapped brush fails here, as it would on a real PC).
        foreach ($setting in 'Light', 'Dark') {
            $state = @{ Settings = [pscustomobject]@{ Theme = $setting }; ThemeData = $data; ThemeSignature = '' }
            try {
                [void](Update-AfGuiTheme -Window $window -State $state -Force)
                if (-not ($window.Background -is [System.Windows.Media.Brush])) { "The $setting theme did not give the window a background brush." }
            }
            catch { 'The {0} theme could not be applied: {1}' -f $setting, $_.Exception.Message }
        }
        $window.Close()
    }
    catch { 'The window did not load: {0}' -f $_.Exception.Message }
}

function Start-AfGui {
    <#
    .SYNOPSIS
        Opens the Auto-Fixer window. Uses the same settings.json and engine as the console
        menu. This version runs the read-only scan; repairs stay in AutoFix.bat for now.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SettingsPath,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [ValidateRange(1, 90)] [int] $Days = 14,
        # The Plain look for this run only, like the console's -Plain.
        [switch] $Plain
    )

    $why = Test-AfGuiSupported
    if ($why) { throw $why }
    $parts = New-AfGuiWindow
    $window = $parts.Window
    $ui = $parts.Ui
    $window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo

    $state = @{
        Settings = (Read-AfSettings -Path $SettingsPath); SettingsPath = $SettingsPath; OutputRoot = $OutputRoot; Days = $Days
        ForcePlain = $Plain.IsPresent; ThemeData = (Read-AfThemeFile); ThemeSignature = ''; Base = 'Light'
        Menu = (Read-AfGuiMenu); Redactor = (New-AfRedactor); IsAdmin = (Test-AfIsAdmin)
        RailLabels = (New-Object System.Collections.Generic.List[object]); Page = ''; Syncing = $false; Loading = $false
        Scan = $null; Note = $null; LastHtml = $null; Narrow = $false; FirstRunStyle = 'Branded'
    }
    [void](Update-AfGuiTheme -Window $window -State $state -Force)

    # Left bar: Home, every tile, then Settings and About at the bottom.
    $homeItem = [pscustomobject]@{ id = 'home'; label = '&Home'; icon = 'E80F'; group = 'app'; tags = @(); action = 'home'; description = 'All tasks.' }
    [void]$ui.Rail.Items.Add((New-AfGuiRailItem -Item $homeItem -State $state))
    foreach ($item in $state.Menu.Tiles) {
        [void]$ui.Rail.Items.Add((New-AfGuiRailItem -Item $item -State $state))
        $tile = New-AfGuiTile -Item $item -Window $window
        $tile.Add_Click({ Invoke-AfGuiItem -Ui $ui -State $state -Item $this.Tag })
        [void]$ui.TileHost.Children.Add($tile)
    }
    foreach ($item in $state.Menu.Footer) { [void]$ui.RailFooter.Items.Add((New-AfGuiRailItem -Item $item -State $state)) }
    $state.AllItems = @($homeItem) + @($state.Menu.Tiles) + @($state.Menu.Footer)

    $onRail = {
        # $this is the list that changed.
        if ($state.Syncing -or -not $this.SelectedItem) { return }
        Invoke-AfGuiItem -Ui $ui -State $state -Item $this.SelectedItem.Tag
    }
    $ui.Rail.Add_SelectionChanged($onRail)
    $ui.RailFooter.Add_SelectionChanged($onRail)

    # Mouse wheel over the Activity box scrolls the box first, then the page once the box hits its end.
    $ui.ScanActivity.Add_PreviewMouseWheel({ param($s, $e) Step-AfGuiScrollChain -Inner $s -Outer $ui.PageScroll -WheelArgs $e })

    # About: the same facts as the console About page.
    $about = @(
        @('Auto-Fixer', ('Version {0}' -f $script:AfVersion)),
        @('Publisher', 'raven575'),
        @('Written by', $script:AfCreditsLine),
        @('License', 'MIT License, Copyright (c) 2026 raven575'),
        @('Project', $script:AfProjectUrl),
        @('Privacy', 'No telemetry. Logs stay on this PC unless you share them.')
    )
    foreach ($pair in $about) {
        [void]$ui.AboutHost.Children.Add((New-AfGuiText -Text $pair[0] -Brush 'MutedBrush' -Size 12))
        $v = New-AfGuiText -Text $pair[1] -Brush 'TextBrush' -Wrap
        $v.Margin = '0,0,0,10'
        [void]$ui.AboutHost.Children.Add($v)
    }

    # First start: choose the mode. Nothing is saved until a choice is made.
    $finishFirstRun = {
        param([string] $Mode)
        $style = 'Branded'
        if ($ui.FirstRunPlain.IsChecked) { $style = 'Plain' }
        Complete-AfGuiFirstRun -Ui $ui -State $state -Mode $Mode -Style $style
    }
    # Picking a look previews it straight away (wordmark in the left bar).
    $ui.FirstRunHerd.Add_Checked({ $state.FirstRunStyle = 'Branded'; Update-AfGuiChrome -Ui $ui -State $state })
    $ui.FirstRunPlain.Add_Checked({ $state.FirstRunStyle = 'Plain'; Update-AfGuiChrome -Ui $ui -State $state })
    $ui.FirstRunStandard.Add_Click({ & $finishFirstRun 'Standard' })
    $ui.FirstRunTechnician.Add_Click({
            $mode = 'Standard'
            if (Show-AfGuiQuestion -Window $window -Text (Get-AfGuiText 'Technician')) { $mode = 'Technician' }
            & $finishFirstRun $mode
        })

    # Settings: saved on every change, like the console.
    $ui.ModeStandard.Add_Checked({ if (-not $state.Loading) { $state.Settings.Mode = 'Standard'; Save-AfGuiSettings -Ui $ui -State $state -Window $window } })
    $ui.ModeTechnician.Add_Checked({
            if ($state.Loading) { return }
            if (Show-AfGuiQuestion -Window $window -Text (Get-AfGuiText 'Technician')) { $state.Settings.Mode = 'Technician'; Save-AfGuiSettings -Ui $ui -State $state -Window $window }
            else { Sync-AfGuiSettingsPage -Ui $ui -State $state }
        })
    $ui.ShowSensitiveBox.Add_Click({ $state.Settings.ShowSensitive = [bool]$ui.ShowSensitiveBox.IsChecked; Save-AfGuiSettings -Ui $ui -State $state -Window $window })
    $ui.SaveSensitiveBox.Add_Click({
            $on = [bool]$ui.SaveSensitiveBox.IsChecked
            if ($on -and -not (Show-AfGuiQuestion -Window $window -Text (Get-AfGuiText 'SaveSensitive'))) { $on = $false }
            $state.Settings.SaveSensitive = $on; Save-AfGuiSettings -Ui $ui -State $state -Window $window; Sync-AfGuiSettingsPage -Ui $ui -State $state
        })
    $ui.OnlineBox.Add_Click({
            $on = [bool]$ui.OnlineBox.IsChecked
            if ($on -and -not (Show-AfGuiQuestion -Window $window -Text (Get-AfGuiText 'Online') -Icon 'Question')) { $on = $false }
            $state.Settings.Online = $on; Save-AfGuiSettings -Ui $ui -State $state -Window $window; Sync-AfGuiSettingsPage -Ui $ui -State $state
        })
    $ui.StyleBranded.Add_Checked({ if (-not $state.Loading) { $state.Settings.Style = 'Branded'; Save-AfGuiSettings -Ui $ui -State $state -Window $window } })
    $ui.StylePlain.Add_Checked({ if (-not $state.Loading) { $state.Settings.Style = 'Plain'; Save-AfGuiSettings -Ui $ui -State $state -Window $window } })
    $ui.ThemeSystem.Add_Checked({ if (-not $state.Loading) { $state.Settings.Theme = 'System'; Save-AfGuiSettings -Ui $ui -State $state -Window $window } })
    $ui.ThemeLight.Add_Checked({ if (-not $state.Loading) { $state.Settings.Theme = 'Light'; Save-AfGuiSettings -Ui $ui -State $state -Window $window } })
    $ui.ThemeDark.Add_Checked({ if (-not $state.Loading) { $state.Settings.Theme = 'Dark'; Save-AfGuiSettings -Ui $ui -State $state -Window $window } })

    # Scan.
    $state.ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $state.ScanTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $state.ScanTimer.Add_Tick({ Update-AfGuiScan -Ui $ui -State $state -Window $window })
    $ui.ScanStart.Add_Click({ Start-AfGuiScan -Ui $ui -State $state -Window $window })
    $ui.ScanOpenReport.Add_Click({ if ($state.LastHtml -and (Test-Path -LiteralPath $state.LastHtml)) { Invoke-Item -LiteralPath $state.LastHtml } })

    # Follow Windows: checks the light/dark mode, accent colour and high contrast every
    # 1.5 s on the window's own thread and recolours when one changes.
    $themeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $themeTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    # A theme change also swaps the black/white Plain wordmark.
    $themeTimer.Add_Tick({ if (Update-AfGuiTheme -Window $window -State $state) { Update-AfGuiChrome -Ui $ui -State $state } })
    $window.Add_SourceInitialized({ if (Update-AfGuiTheme -Window $window -State $state -Force) { Update-AfGuiChrome -Ui $ui -State $state } })

    # Narrow window: the left bar folds to icons, like Windows Settings.
    $window.Add_SizeChanged({
            $narrow = $window.ActualWidth -lt 760
            if ($narrow -eq $state.Narrow) { return }
            $state.Narrow = $narrow
            $vis = 'Visible'
            if ($narrow) { $ui.RailColumn.Width = New-Object System.Windows.GridLength 60; $vis = 'Collapsed' }
            else { $ui.RailColumn.Width = New-Object System.Windows.GridLength 264 }
            $ui.AppNamePanel.Visibility = $vis
            foreach ($l in $state.RailLabels) { $l.Visibility = $vis }
        })

    # Keys: Alt+letter (or the letter alone on Home, like the console) runs that item; Esc goes Home.
    $window.Add_PreviewKeyDown({
            $e = $args[1]
            if ($state.Page -eq 'PageFirstRun') {
                if ($e.Key -eq 'S' -or $e.SystemKey -eq 'S') { $e.Handled = $true; & $finishFirstRun 'Standard' }
                elseif ($e.Key -eq 'T' -or $e.SystemKey -eq 'T') { $e.Handled = $true; $ui.FirstRunTechnician.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) }
                return
            }
            if ($e.Key -eq 'Escape') {
                if ($state.Page -ne 'PageHome') { $e.Handled = $true; Invoke-AfGuiItem -Ui $ui -State $state -Item $homeItem }
                return
            }
            $key = $null
            if ($e.Key -eq 'System') { $key = [string]$e.SystemKey }
            elseif ($state.Page -eq 'PageHome' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'None') { $key = [string]$e.Key }
            if (-not $key -or $key.Length -ne 1) { return }
            foreach ($item in $state.AllItems) {
                if ((Get-AfAccessKey -Label ([string]$item.label)) -eq $key) { $e.Handled = $true; Invoke-AfGuiItem -Ui $ui -State $state -Item $item; return }
            }
        })

    $window.Add_Closing({
            $e = $args[1]
            if (-not $state.Scan) { return }
            if (Show-AfGuiQuestion -Window $window -Text ('A scan is still running. Stop it and close Auto-Fixer?' + [Environment]::NewLine + 'Nothing on this PC has been changed.')) {
                try { $state.Scan.PowerShell.Stop() } catch { Write-Verbose $_.Exception.Message }
            }
            else { $e.Cancel = $true }
        })
    $window.Add_Closed({ $themeTimer.Stop(); $state.ScanTimer.Stop() })

    $splashPlain = $state.ForcePlain -or ($state.Settings -and $state.Settings.Style -eq 'Plain')
    # A splash problem must never stop the tool from opening.
    try { Show-AfGuiSplash -Resources $window.Resources -Plain $splashPlain -Version $script:AfVersion -Base $state.Base }
    catch { Write-Verbose ('Splash skipped: {0}' -f $_.Exception.Message) }

    Update-AfGuiChrome -Ui $ui -State $state
    if (-not $state.Settings) {
        Set-AfGuiRailLock -Ui $ui -Locked $true
        Show-AfGuiPage -Ui $ui -State $state -Page 'PageFirstRun' -Title 'Welcome to Auto-Fixer'
    }
    else { Invoke-AfGuiItem -Ui $ui -State $state -Item $homeItem }
    $themeTimer.Start()
    [void]$window.ShowDialog()
}
