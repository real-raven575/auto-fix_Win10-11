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

function Clear-AfKeyBuffer {
    # Drops keys pressed while a step ran, so a "Press any key" waits for a new one.
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
    catch { Write-Verbose 'No console keys to clear.' }
}

function Show-AfBanner {
    # The top of a screen. Branded and Plain draw the banner and strip and leave the
    # cursor under them; Ascii keeps the original four-line box.
    [CmdletBinding()]
    param([string] $Mode = 'Standard')

    $display = Get-AfDisplay
    if ($display.Style -ne 'Ascii') { Show-AfWorkTop -Display $display -Mode $Mode; return }
    $line = '+' + ('-' * 58) + '+'
    Write-Host ''
    Write-Host ('  ' + $line) -ForegroundColor Cyan
    Write-Host ('  |{0,-58}|' -f ('  Auto-Fixer {0}  -  Windows 10 / 11 repair tool' -f $script:AfVersion)) -ForegroundColor Cyan
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
        keys move the marker and Enter picks it. An item's number or its letter
        picks it at once. The letter is marked with & in the label and shown in
        brackets, the way older programs did: 'Se&ttings' shows as 'Se(t)tings'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        # Each item: @{ Key = 'S'; Label = '&Scan this PC' }. Optional: Tags = '[CHG]'
        # beside the label and Divider = $true for a line under it (Branded and Plain).
        [Parameter(Mandatory)] [object[]] $Items,
        [int] $Default = 0,
        # Ascii look: draws what sits above the list (banner, explanation) on every redraw.
        [scriptblock] $Header = {},
        # Branded and Plain: the explanation, shown in the menu box above the items.
        [string[]] $Info = @(),
        # Branded and Plain: lines for the WHAT THIS DOES panel, by item Key.
        [hashtable] $ItemInfo,
        # Main, Menu or About: where the hidden faces go. Main also follows the mode.
        [string] $Kind = 'Menu',
        [string] $Mode = 'Standard',
        [int] $BoxRight = 79,
        # One line shown above the list, such as the result of the last choice.
        [string] $Notice,
        # The item Esc picks, such as 'B' for Back. Every menu uses Esc the same way.
        [string] $EscapeKey,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $index = $Default
    $unknown = $false
    $escapeLabel = $null
    if ($EscapeKey) { $escapeLabel = ([string]@($Items | Where-Object { $_.Key -eq $EscapeKey })[0].Label).Replace('&', '') }
    $unknownText = 'Command unknown. Use the arrow keys and Enter, or press the number or the (letter).'
    $picked = $null
    while ($null -eq $picked) {
        $display = Get-AfDisplay
        if ($display.Style -ne 'Ascii') {
            $message = $Notice
            if ($unknown) { $message = $unknownText }
            $screen = New-AfMenuScreen -Display $display -Title $Title -Items $Items -Index $index -Info $Info -ItemInfo $ItemInfo `
                -Message $message -EscapeLabel $escapeLabel -Kind $Kind -Mode $Mode -BoxRight $BoxRight
            Write-AfScreen -Screen $screen -Display $display
        }
        else {
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
                Write-Host ('  {0} {1}  ' -f $marker, ($i + 1)) -ForegroundColor $color -NoNewline
                $label = [string]$Items[$i].Label
                $at = $label.IndexOf('&')
                if ($at -ge 0 -and $at -lt $label.Length - 1) {
                    Write-Host $label.Substring(0, $at) -ForegroundColor $color -NoNewline
                    Write-Host ('({0})' -f $label[$at + 1]) -ForegroundColor Yellow -NoNewline
                    Write-Host $label.Substring($at + 2) -ForegroundColor $color
                }
                else { Write-Host $label -ForegroundColor $color }
            }
            $hint = '  Use the arrow keys and Enter, or press the number or the (letter).'
            if ($EscapeKey) { $hint += ' Esc = {0}.' -f $escapeLabel }
            Write-Host $hint -ForegroundColor DarkGray
            if ($unknown) { Write-Host ('  {0}' -f $unknownText) -ForegroundColor Yellow }
        }

        $key = [string](& $ReadKey)
        $unknown = $false
        if ($key -eq 'Up') { $index = ($index - 1 + $Items.Count) % $Items.Count }
        elseif ($key -eq 'Down') { $index = ($index + 1) % $Items.Count }
        elseif ($key -eq 'Enter') { $picked = $Items[$index].Key }
        elseif ($key -eq 'Escape' -and $EscapeKey) { $picked = $EscapeKey }
        else {
            $match = @($Items | Where-Object { $_.Key -eq $key })
            $number = 0
            if ($match.Count -gt 0) { $picked = $match[0].Key }
            elseif ([int]::TryParse($key, [ref]$number) -and $number -ge 1 -and $number -le [math]::Min(9, $Items.Count)) { $picked = $Items[$number - 1].Key }
            else { $unknown = $true }
        }
    }
    # Whatever the choice prints next (a question, a scan) goes under a clean banner.
    if ($display.Style -ne 'Ascii') { Show-AfWorkTop -Display $display -Mode $Mode }
    return $picked
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
    Write-Host '  Auto-Fixer never sends your data anywhere.' -ForegroundColor Yellow
    return ((Read-AfYesNo -Prompt 'Turn it on?' -ReadKey $ReadKey) -eq $true)
}

function Confirm-AfQuit {
    # Quitting from any menu. Returns $true only on Y.
    [CmdletBinding()]
    [OutputType([bool])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    Write-Host ''
    return ((Read-AfYesNo -Prompt 'Quit Auto-Fixer. Are you sure?' -ReadKey $ReadKey) -eq $true)
}

function Select-AfMode {
    # First launch: Standard unless the user picks Technician and confirms it.
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    $header = {
        Show-AfBanner -Mode 'not chosen yet'
        Write-Host ''
        Write-Host '  First start: choose how Auto-Fixer works for you.' -ForegroundColor White
        Write-Host '    Standard    Recommended. Explains each step and asks before any change.'
        Write-Host '    Technician  For experienced users. One-key repairs such as SFC and DISM.'
        Write-Host '  You can change this later under Settings.' -ForegroundColor DarkGray
    }
    $info = @('First start: choose how Auto-Fixer works for you.', 'You can change this later under Settings.')
    $itemInfo = @{
        S = @('Recommended.', '', 'Explains each step and asks before any change.')
        T = @('For experienced users.', '', 'One-key repairs such as SFC and DISM.', '', 'Steps that delete data, are permanent or go online still warn first.')
        Q = @('Closes Auto-Fixer. Nothing is saved, so the next start asks again.')
    }
    $items = @(
        @{ Key = 'S'; Label = '&Standard (recommended)' }
        @{ Key = 'T'; Label = '&Technician' }
        @{ Key = 'Q'; Label = '&Quit' }
    )
    while ($true) {
        $choice = Select-AfMenuItem -Title 'Mode' -Items $items -Header $header -Info $info -ItemInfo $itemInfo -Mode 'not chosen yet' -ReadKey $ReadKey
        # Nothing is saved on a quit here, so the next start asks again.
        if ($choice -ne 'Q') { break }
        if (Confirm-AfQuit -ReadKey $ReadKey) { return $null }
    }
    if ($choice -eq 'T') {
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
    $itemInfo = @{
        M = @('Standard explains each step and asks before any change.', '', 'Technician runs repairs such as SFC and DISM with one key.')
        S = @('Shows real names, serial numbers and addresses on screen.', '', 'Saved reports stay redacted.')
        V = @('Saves real values in report files.', '', 'Asks Y/N first, and again before every scan.')
        G = @('Lets a step go online when it needs to, and says where first.', '', 'Only Windows Update, for DISM RestoreHealth.')
        Y = @('Branded shows the Auto-Fixer art.', '', 'Plain shows the same screens without it.', '', 'Start with -Plain to use Plain for one run.')
        B = @('Back to the main menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $notice = $null
    while ($true) {
        $items = @(
            @{ Key = 'M'; Label = ('&Mode: {0}' -f $Settings.Mode) }
            @{ Key = 'S'; Label = ('&Show sensitive data on screen: {0}' -f $onOff[[bool]$Settings.ShowSensitive]) }
            @{ Key = 'V'; Label = ('Sa&ve reports without redaction: {0}' -f $onOff[[bool]$Settings.SaveSensitive]) }
            @{ Key = 'G'; Label = ('&Go online when a step needs it: {0}' -f $onOff[[bool]$Settings.Online]) }
            @{ Key = 'Y'; Label = ('Screen st&yle: {0}' -f $Settings.Style) }
            @{ Key = 'B'; Label = '&Back' }
            @{ Key = 'Q'; Label = '&Quit' }
        )
        $choice = Select-AfMenuItem -Title 'Settings' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -ItemInfo $itemInfo -Mode $Settings.Mode `
            -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        switch ($choice) {
            'M' {
                if ($Settings.Mode -eq 'Technician') { $Settings.Mode = 'Standard' }
                elseif (Confirm-AfTechnicianMode -ReadKey $ReadKey) { $Settings.Mode = 'Technician' }
                else { $notice = 'Mode not changed.' }
            }
            'S' { $Settings.ShowSensitive = -not $Settings.ShowSensitive }
            'V' {
                if ($Settings.SaveSensitive) { $Settings.SaveSensitive = $false }
                elseif (Confirm-AfSaveSensitive -ReadKey $ReadKey) { $Settings.SaveSensitive = $true }
                else { $notice = 'Saved reports stay redacted.' }
            }
            'G' {
                if ($Settings.Online) { $Settings.Online = $false }
                elseif (Confirm-AfOnline -ReadKey $ReadKey) { $Settings.Online = $true }
                else { $notice = 'Auto-Fixer stays offline.' }
            }
            'Y' {
                if ($Settings.Style -eq 'Plain') { $Settings.Style = 'Branded' } else { $Settings.Style = 'Plain' }
                if ($script:AfUi -and $script:AfUi.ForcePlain) { $notice = 'Saved. This run stays Plain because it was started with -Plain.' }
            }
            'B' { return $Settings }
            'Q' { if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return $Settings } }
        }
        Save-AfSettings -Settings $Settings -Path $Path
    }
}

function Invoke-AfNetworkMenu {
    <#
    .SYNOPSIS
        Network and domain tools. Network tools and saved network passwords are in both modes; every
        domain tool, even the read-only check, is Technician only (raven575's pick).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default action script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        # Each is called with the settings.
        [scriptblock] $Credentials = { param($S) Invoke-AfCredentialMenu -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Check = { param($S) Invoke-AfDomainCheck -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Join = { param($S) Invoke-AfDomainJoin -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Trust = { param($S) Invoke-AfDomainTrustRepair -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Leave = { param($S) Invoke-AfDomainLeave -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $LocalAdmin = { param($S) Invoke-AfLocalAdminTool -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $AzureAd = { param($S) Invoke-AfAzureAdLeave -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $NetTools = { param($S) Invoke-AfNetToolsMenu -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey }
    )

    $itemInfo = @{
        C = @('Lists saved passwords for network drives, then removes the ones you pick.', '', 'Changes system: YES', 'Asks Y/N first.')
        W = @('Status, ping, trace route, netstat, DNS lookup, port test, flush DNS and release/renew IP.', '', 'Changes system: only flush and renew, after Y/N')
        D = @('Shows the domain or workgroup and tests DNS, the domain controller, its ports, the clock and the trust.', '', 'Changes system: NO', 'Internet: never')
        J = @('Joins this PC to a domain after the checks pass.', '', 'Changes system: YES', 'Needs a restart.', '', 'Asks Y/N first.')
        T = @('Fixes "The trust relationship between this workstation and the primary domain failed".', '', 'Changes system: YES', 'Asks Y/N first.')
        L = @('Takes this PC off its domain into WORKGROUP.', '', 'Changes system: YES', 'Needs a restart.', '', 'Asks Y/N first.')
        U = @('Creates a local admin account, or resets a local account''s password, so nobody is locked out.', '', 'Changes system: YES', 'Asks Y/N first.')
        A = @('Takes this PC off Azure AD (Entra ID). Needs a working local admin first. Ask IT on a work PC.', '', 'Changes system: YES', 'Asks Y/N first.')
        B = @('Back to the main menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $notice = $null
    $info = @('Network tools, saved network passwords and domain tools.')
    if ($Settings.Mode -ne 'Technician') { $info = @('Network tools and saved network passwords. Technician mode adds the domain tools: check, join, trust repair, leave, local admin and Azure AD.') }
    while ($true) {
        $items = @(
            @{ Key = 'W'; Label = 'Net&work tools' }
            @{ Key = 'C'; Label = '&Clear saved drive passwords'; Tags = '[CHG]' }
        )
        if ($Settings.Mode -eq 'Technician') {
            $items += @{ Key = 'D'; Label = '&Domain check (read-only)' }
            $items += @{ Key = 'J'; Label = '&Join a domain'; Tags = '[ADMIN] [CHG]' }
            $items += @{ Key = 'T'; Label = 'Repair domain &trust'; Tags = '[ADMIN] [CHG]' }
            $items += @{ Key = 'L'; Label = '&Leave the domain'; Tags = '[ADMIN] [CHG]' }
            $items += @{ Key = 'U'; Label = '&User: local admin'; Tags = '[ADMIN] [CHG]' }
            $items += @{ Key = 'A'; Label = 'Leave &Azure AD'; Tags = '[ADMIN] [CHG]' }
        }
        $items[-1].Divider = $true
        $items += @{ Key = 'B'; Label = '&Back' }
        $items += @{ Key = 'Q'; Label = '&Quit' }

        $choice = Select-AfMenuItem -Title 'Network and domain' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        $action = @{ W = $NetTools; C = $Credentials; D = $Check; J = $Join; T = $Trust; L = $Leave; U = $LocalAdmin; A = $AzureAd }[$choice]
        try {
            $result = & $action $Settings
            if ($choice -eq 'C' -and $result -is [string]) { $notice = $result }
        }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        if ($script:AfQuitRequested) { return }
        # The network tools and saved passwords screens have their own menus; the others print results to read first.
        if ($choice -notin 'C', 'W') {
            Write-Host ''
            Write-Host '  Press any key to return to Network and domain.' -ForegroundColor DarkGray
            Clear-AfKeyBuffer
            $null = & $ReadKey
        }
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
        # Called with the settings; the default opens Network and domain.
        [scriptblock] $NetworkAction = { param($Settings) Invoke-AfNetworkMenu -Settings $Settings -OutputRoot $OutputRoot -ReadKey $ReadKey },
        # The Plain look for this run, whatever Settings says. Not saved.
        [switch] $Plain,
        # Console facts for tests; the default asks the console before every draw.
        [hashtable] $ConsoleFacts,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $script:AfUi = @{ Settings = $null; ForcePlain = $Plain.IsPresent; IsAdmin = (Test-AfIsAdmin); Facts = $ConsoleFacts; UsedVt = $false }
    try {
        $settings = Read-AfSettings -Path $SettingsPath
        $script:AfUi.Settings = $settings
        $display = Get-AfDisplay
        if ($display.Style -ne 'Ascii' -and -not $ConsoleFacts) {
            $splashMode = 'Standard'
            if ($settings) { $splashMode = $settings.Mode }
            Show-AfSplash -Display $display -Mode $splashMode
        }
        if (-not $settings) {
            $settings = Get-AfDefaultSettings
            $settings.Mode = Select-AfMode -ReadKey $ReadKey
            if (-not $settings.Mode) { return }
            Save-AfSettings -Settings $settings -Path $SettingsPath
        }
        $script:AfUi.Settings = $settings

        $items = @(
            @{ Key = 'S'; Label = 'Run a &scan (read-only)' }
            @{ Key = 'R'; Label = '&Repair Windows files'; Tags = '[ADMIN] [CHG]' }
            @{ Key = 'N'; Label = '&Network and domain'; Tags = '[CHG]' }
            @{ Key = 'P'; Label = 'Open the last re&port'; Divider = $true }
            @{ Key = 'T'; Label = 'Se&ttings' }
            @{ Key = 'A'; Label = '&About and credits' }
            @{ Key = 'Q'; Label = '&Quit' }
        )
        $repairTime = 'Time: {0}' -f (Format-AfApprox (@($script:AfRunAll | ForEach-Object { Get-AfRepairEstimate -Key $_ -HistoryPath (Join-Path $OutputRoot 'repair-history.csv') }) | Measure-Object -Sum).Sum)
        $itemInfo = @{
            S = @('Reads Windows logs for crashes and failures and writes a report.', '', 'Changes system: NO', 'Internet: never')
            R = @('Checks and repairs Windows system files (SFC, then DISM).', '', 'Changes system: YES', 'Internet: only if On', $repairTime, '', 'Asks before it runs.')
            N = @('Network tools (ping, trace route, release/renew and more) and saved network-drive passwords.', '', 'Technician mode: domain check, join, trust repair, leave, local admin and Azure AD.', '', 'Asks before any change.')
            P = @('Opens the newest report in your web browser.', '', 'Changes system: NO')
            T = @('Mode, privacy, the Online switch and the screen style.')
            A = @('Who made Auto-Fixer, its license and the Windows tools it uses.')
            Q = @('Closes Auto-Fixer.')
        }
        # Set by a submenu when the user quits from there.
        $script:AfQuitRequested = $false
        $notice = $null
        while ($true) {
            $choice = Select-AfMenuItem -Title 'Main menu' -Items $items -Header { Show-AfBanner -Mode $settings.Mode } -ItemInfo $itemInfo -Kind 'Main' -Mode $settings.Mode `
                -Notice $notice -EscapeKey 'Q' -ReadKey $ReadKey
            $notice = $null
            switch ($choice) {
                'S' {
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
                'P' {
                    $report = Find-AfLatestReport -OutputRoot $OutputRoot
                    if ($report) { & $OpenAction $report }
                    else { $notice = 'No report yet. Run a scan first.' }
                }
                'T' { $settings = Invoke-AfSettingsMenu -Settings $settings -Path $SettingsPath -ReadKey $ReadKey; $script:AfUi.Settings = $settings }
                'R' { & $RepairAction $settings }
                'N' { & $NetworkAction $settings }
                'A' { Invoke-AfAboutMenu -Mode $settings.Mode -ReadKey $ReadKey }
                'Q' { if (Confirm-AfQuit -ReadKey $ReadKey) { return } }
            }
            if ($script:AfQuitRequested) { return }
        }
    }
    finally { Exit-AfScreen }
}
