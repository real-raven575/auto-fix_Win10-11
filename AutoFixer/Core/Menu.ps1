# The console menu: first-launch mode choice, main menu and settings. Every key read
# goes through a -ReadKey script block that returns 'Up', 'Down', 'Enter', 'Escape'
# or one character, so tests can feed keys without a keyboard.

function Read-AfMenuKey {
    try {
        $info = [Console]::ReadKey($true)
        switch ($info.Key) {
            'UpArrow' { return 'Up' }
            'DownArrow' { return 'Down' }
            'Enter' { return 'Enter' }
            'Escape' { return 'Escape' }
        }
        return [string]$info.KeyChar
    }
    catch {
        # Consoles that can't read single keys: type the number, then Enter.
        $line = [string](Read-Host)
        if ($line) { return [string]$line[0] }
        return 'Enter'
    }
}

function Show-AfBanner {
    [CmdletBinding()]
    param([string] $Mode = 'Standard')

    $line = '+' + ('-' * 58) + '+'
    Write-Host ''
    Write-Host ('  ' + $line) -ForegroundColor Cyan
    Write-Host ('  |{0,-58}|' -f '  auto-fix_Win  -  Windows 10 / 11 repair tool') -ForegroundColor Cyan
    Write-Host ('  |{0,-58}|' -f ('  Mode: {0}' -f $Mode)) -ForegroundColor Cyan
    Write-Host ('  ' + $line) -ForegroundColor Cyan
}

function Select-AfMenuItem {
    <#
    .SYNOPSIS
        Shows a list and returns the Key of the chosen item. Arrow keys move the
        marker and Enter picks it; an item's own key picks it at once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        # Each item: @{ Key = '1'; Label = 'Scan this PC' }
        [Parameter(Mandatory)] [object[]] $Items,
        [int] $Default = 0,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $index = $Default
    $redraw = $true
    $top = $null
    while ($true) {
        if ($redraw) {
            # Draw over the old list where the console allows it, so arrows don't scroll.
            if ($null -ne $top) { try { [Console]::SetCursorPosition(0, $top) } catch { $top = $null } }
            Write-Host ''
            Write-Host ('  {0}' -f $Title) -ForegroundColor White
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $marker = ' '
                $color = 'Gray'
                if ($i -eq $index) { $marker = '>'; $color = 'Cyan' }
                Write-Host ('  {0} {1}  {2}' -f $marker, $Items[$i].Key, $Items[$i].Label) -ForegroundColor $color
            }
            Write-Host '  Use the arrow keys and Enter, or press a key from the list.' -ForegroundColor DarkGray
            try { $top = [Console]::CursorTop - ($Items.Count + 3) } catch { $top = $null }
            $redraw = $false
        }

        $key = [string](& $ReadKey)
        if ($key -eq 'Up') { $index = ($index - 1 + $Items.Count) % $Items.Count; $redraw = $true }
        elseif ($key -eq 'Down') { $index = ($index + 1) % $Items.Count; $redraw = $true }
        elseif ($key -eq 'Enter') { return $Items[$index].Key }
        else {
            $match = @($Items | Where-Object { $_.Key -eq $key })
            if ($match.Count -gt 0) { return $match[0].Key }
            Write-Host '  Command unknown. Use the arrow keys and Enter, or press a key from the list.' -ForegroundColor Yellow
            # The message sits below the list, so stop drawing over it.
            $top = $null
        }
    }
}

function Confirm-AfTechnicianMode {
    # The opt-in for Technician mode. Returns $true only on Y.
    [CmdletBinding()]
    [OutputType([bool])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    Write-Host ''
    Write-Host '  WARNING: Technician mode runs repairs such as SFC and DISM with one key,' -ForegroundColor Red
    Write-Host '  without the extra step-by-step questions Standard mode asks. Steps that' -ForegroundColor Red
    Write-Host '  delete data, are permanent or go online still warn first. Choose it only' -ForegroundColor Red
    Write-Host '  if you know these tools and accept responsibility for the changes.' -ForegroundColor Red
    return ((Read-AfYesNo -Prompt 'Are you sure?' -ReadKey $ReadKey) -eq $true)
}

function Select-AfMode {
    # First launch: Standard unless the user picks Technician and confirms it.
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    Write-Host ''
    Write-Host '  First start: choose how auto-fix_Win works for you.' -ForegroundColor White
    Write-Host '    Standard    Recommended. Explains each step and asks before any change.'
    Write-Host '    Technician  For experienced users. One-key repairs such as SFC and DISM.'
    Write-Host '  You can change this later under Settings.' -ForegroundColor DarkGray

    $items = @(
        @{ Key = '1'; Label = 'Standard (recommended)' }
        @{ Key = '2'; Label = 'Technician' }
    )
    $choice = Select-AfMenuItem -Title 'Mode' -Items $items -ReadKey $ReadKey
    if ($choice -eq '2') {
        if (Confirm-AfTechnicianMode -ReadKey $ReadKey) { return 'Technician' }
        Write-Host '  Staying in Standard mode.' -ForegroundColor Yellow
    }
    return 'Standard'
}

function Invoke-AfSettingsMenu {
    # Changes are saved as soon as they are made.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $Path,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $onOff = @{ $true = 'On'; $false = 'Off' }
    while ($true) {
        $items = @(
            @{ Key = '1'; Label = ('Mode: {0}' -f $Settings.Mode) }
            @{ Key = '2'; Label = ('Show sensitive data on screen: {0}' -f $onOff[[bool]$Settings.ShowSensitive]) }
            @{ Key = '3'; Label = ('Save reports without redaction: {0}' -f $onOff[[bool]$Settings.SaveSensitive]) }
            @{ Key = 'B'; Label = 'Back' }
        )
        $choice = Select-AfMenuItem -Title 'Settings' -Items $items -ReadKey $ReadKey
        switch ($choice) {
            '1' {
                if ($Settings.Mode -eq 'Technician') { $Settings.Mode = 'Standard' }
                elseif (Confirm-AfTechnicianMode -ReadKey $ReadKey) { $Settings.Mode = 'Technician' }
            }
            '2' { $Settings.ShowSensitive = -not $Settings.ShowSensitive }
            '3' {
                if ($Settings.SaveSensitive) { $Settings.SaveSensitive = $false }
                elseif (Confirm-AfSaveSensitive -ReadKey $ReadKey) { $Settings.SaveSensitive = $true }
            }
            'B' { return $Settings }
        }
        Save-AfSettings -Settings $Settings -Path $Path
    }
}

function Find-AfLatestReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot)

    if (-not (Test-Path -LiteralPath $OutputRoot)) { return $null }
    $report = Get-ChildItem -LiteralPath $OutputRoot -Recurse -Filter 'report.html' -File |
        Sort-Object LastWriteTime | Select-Object -Last 1
    if ($report) { return $report.FullName }
    return $null
}

function Invoke-AfMainMenu {
    <#
    .SYNOPSIS
        Runs the menu until the user quits. Asks for the mode on first launch.
        -ScanAction gets two switches: show on screen, and save unredacted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SettingsPath,
        [Parameter(Mandatory)] [string] $OutputRoot,
        # Called as: & $ScanAction $showSensitive $saveSensitive
        [Parameter(Mandatory)] [scriptblock] $ScanAction,
        # Called with the report path.
        [scriptblock] $OpenAction = { param($ReportPath) Invoke-Item -LiteralPath $ReportPath },
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $settings = Read-AfSettings -Path $SettingsPath
    if (-not $settings) {
        Show-AfBanner -Mode 'not chosen yet'
        $settings = Get-AfDefaultSettings
        $settings.Mode = Select-AfMode -ReadKey $ReadKey
        Save-AfSettings -Settings $settings -Path $SettingsPath
    }

    $items = @(
        @{ Key = '1'; Label = 'Scan this PC (reads logs only, changes nothing)' }
        @{ Key = '2'; Label = 'Open last report' }
        @{ Key = '3'; Label = 'Settings' }
        @{ Key = 'Q'; Label = 'Quit' }
    )
    while ($true) {
        Show-AfBanner -Mode $settings.Mode
        $choice = Select-AfMenuItem -Title 'Main menu' -Items $items -ReadKey $ReadKey
        switch ($choice) {
            '1' {
                # Saving real values asks every time, even when the setting is on.
                $save = $false
                if ($settings.SaveSensitive) {
                    $save = Confirm-AfSaveSensitive -ReadKey $ReadKey
                    if (-not $save) { Write-Host '  Keeping redaction on for this report.' -ForegroundColor Yellow }
                }
                # A failed scan reports the error and returns to the menu.
                try { & $ScanAction ([bool]$settings.ShowSensitive) $save }
                catch { Write-Host ('  The scan stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
            }
            '2' {
                $report = Find-AfLatestReport -OutputRoot $OutputRoot
                if ($report) { & $OpenAction $report }
                else { Write-Host '  No report yet. Run a scan first.' -ForegroundColor Yellow }
            }
            '3' { $settings = Invoke-AfSettingsMenu -Settings $settings -Path $SettingsPath -ReadKey $ReadKey }
            'Q' { return }
        }
    }
}
