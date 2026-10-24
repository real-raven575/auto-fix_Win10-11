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
    Write-Host ('  |{0,-58}|' -f ('  auto-fix_Win {0}  -  Windows 10 / 11 repair tool' -f $script:AfVersion)) -ForegroundColor Cyan
    Write-Host ('  |{0,-58}|' -f ('  Mode: {0}' -f $Mode)) -ForegroundColor Cyan
    Write-Host ('  ' + $line) -ForegroundColor Cyan
}

function Clear-AfScreen {
    # Each menu screen starts on a clean console. Moving the cursor back to redraw
    # in place left stray lines in the Windows console, so the whole screen is redrawn.
    try { if (-not [Console]::IsOutputRedirected) { [Console]::Clear() } } catch { Write-Verbose 'No console to clear.' }
}

function Select-AfMenuItem {
    <#
    .SYNOPSIS
        Shows a screen with a list and returns the Key of the chosen item. Arrow
        keys move the marker and Enter picks it; an item's own key picks it at once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        # Each item: @{ Key = '1'; Label = 'Scan this PC' }
        [Parameter(Mandatory)] [object[]] $Items,
        [int] $Default = 0,
        # Draws what sits above the list (banner, explanation) on every redraw.
        [scriptblock] $Header = {},
        # One line shown above the list, such as the result of the last choice.
        [string] $Notice,
        # The item Esc picks, such as 'B' for Back. Every menu uses Esc the same way.
        [string] $EscapeKey,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $index = $Default
    $unknown = $false
    while ($true) {
        Clear-AfScreen
        & $Header
        if ($Notice) {
            Write-Host ''
            Write-Host ('  {0}' -f $Notice) -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host ('  {0}' -f $Title) -ForegroundColor White
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $marker = ' '
            $color = 'Gray'
            if ($i -eq $index) { $marker = '>'; $color = 'Cyan' }
            Write-Host ('  {0} {1}  {2}' -f $marker, $Items[$i].Key, $Items[$i].Label) -ForegroundColor $color
        }
        $hint = '  Use the arrow keys and Enter, or press a key from the list.'
        if ($EscapeKey) { $hint += ' Esc = {0}.' -f @($Items | Where-Object { $_.Key -eq $EscapeKey })[0].Label }
        Write-Host $hint -ForegroundColor DarkGray
        if ($unknown) { Write-Host '  Command unknown. Use the arrow keys and Enter, or press a key from the list.' -ForegroundColor Yellow }

        $key = [string](& $ReadKey)
        $unknown = $false
        if ($key -eq 'Up') { $index = ($index - 1 + $Items.Count) % $Items.Count }
        elseif ($key -eq 'Down') { $index = ($index + 1) % $Items.Count }
        elseif ($key -eq 'Enter') { return $Items[$index].Key }
        elseif ($key -eq 'Escape' -and $EscapeKey) { return $EscapeKey }
        else {
            $match = @($Items | Where-Object { $_.Key -eq $key })
            if ($match.Count -gt 0) { return $match[0].Key }
            $unknown = $true
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

function Confirm-AfOnline {
    # Turning the Online switch on. Returns $true only on Y.
    [CmdletBinding()]
    [OutputType([bool])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    Write-Host ''
    Write-Host '  With this on, a step may connect to the internet when it needs to. Each' -ForegroundColor Yellow
    Write-Host '  connection is announced first, and only these places are ever contacted:' -ForegroundColor Yellow
    Write-Host '    Windows Update (Microsoft): DISM RestoreHealth downloads clean system files.' -ForegroundColor Yellow
    Write-Host '  auto-fix_Win never sends your data anywhere.' -ForegroundColor Yellow
    return ((Read-AfYesNo -Prompt 'Turn it on?' -ReadKey $ReadKey) -eq $true)
}

function Select-AfMode {
    # First launch: Standard unless the user picks Technician and confirms it.
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    $header = {
        Show-AfBanner -Mode 'not chosen yet'
        Write-Host ''
        Write-Host '  First start: choose how auto-fix_Win works for you.' -ForegroundColor White
        Write-Host '    Standard    Recommended. Explains each step and asks before any change.'
        Write-Host '    Technician  For experienced users. One-key repairs such as SFC and DISM.'
        Write-Host '  You can change this later under Settings.' -ForegroundColor DarkGray
    }
    $items = @(
        @{ Key = '1'; Label = 'Standard (recommended)' }
        @{ Key = '2'; Label = 'Technician' }
    )
    $choice = Select-AfMenuItem -Title 'Mode' -Items $items -Header $header -ReadKey $ReadKey
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
    $notice = $null
    while ($true) {
        $items = @(
            @{ Key = '1'; Label = ('Mode: {0}' -f $Settings.Mode) }
            @{ Key = '2'; Label = ('Show sensitive data on screen: {0}' -f $onOff[[bool]$Settings.ShowSensitive]) }
            @{ Key = '3'; Label = ('Save reports without redaction: {0}' -f $onOff[[bool]$Settings.SaveSensitive]) }
            @{ Key = '4'; Label = ('Go online when a step needs it: {0}' -f $onOff[[bool]$Settings.Online]) }
            @{ Key = 'B'; Label = 'Back' }
        )
        $choice = Select-AfMenuItem -Title 'Settings' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        switch ($choice) {
            '1' {
                if ($Settings.Mode -eq 'Technician') { $Settings.Mode = 'Standard' }
                elseif (Confirm-AfTechnicianMode -ReadKey $ReadKey) { $Settings.Mode = 'Technician' }
                else { $notice = 'Mode not changed.' }
            }
            '2' { $Settings.ShowSensitive = -not $Settings.ShowSensitive }
            '3' {
                if ($Settings.SaveSensitive) { $Settings.SaveSensitive = $false }
                elseif (Confirm-AfSaveSensitive -ReadKey $ReadKey) { $Settings.SaveSensitive = $true }
                else { $notice = 'Saved reports stay redacted.' }
            }
            '4' {
                if ($Settings.Online) { $Settings.Online = $false }
                elseif (Confirm-AfOnline -ReadKey $ReadKey) { $Settings.Online = $true }
                else { $notice = 'auto-fix_Win stays offline.' }
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
        # Called with the settings; the default opens the SFC and DISM screen.
        [scriptblock] $RepairAction = { param($Settings) Invoke-AfRepairMenu -Settings $Settings -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $settings = Read-AfSettings -Path $SettingsPath
    if (-not $settings) {
        $settings = Get-AfDefaultSettings
        $settings.Mode = Select-AfMode -ReadKey $ReadKey
        Save-AfSettings -Settings $settings -Path $SettingsPath
    }

    $items = @(
        @{ Key = '1'; Label = 'Scan this PC (reads logs only, changes nothing)' }
        @{ Key = '2'; Label = 'Open last report' }
        @{ Key = '3'; Label = 'Settings' }
        @{ Key = '4'; Label = 'Repair system files (SFC and DISM)' }
        @{ Key = 'Q'; Label = 'Quit' }
    )
    $notice = $null
    while ($true) {
        $choice = Select-AfMenuItem -Title 'Main menu' -Items $items -Header { Show-AfBanner -Mode $settings.Mode } -Notice $notice -EscapeKey 'Q' -ReadKey $ReadKey
        $notice = $null
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
                # The menu clears the screen, so wait until the results have been read.
                Write-Host ''
                Write-Host '  Press any key to return to the menu.' -ForegroundColor DarkGray
                $null = & $ReadKey
            }
            '2' {
                $report = Find-AfLatestReport -OutputRoot $OutputRoot
                if ($report) { & $OpenAction $report }
                else { $notice = 'No report yet. Run a scan first.' }
            }
            '3' { $settings = Invoke-AfSettingsMenu -Settings $settings -Path $SettingsPath -ReadKey $ReadKey }
            '4' { & $RepairAction $settings }
            'Q' { return }
        }
    }
}
