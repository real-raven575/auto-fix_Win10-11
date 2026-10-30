# Shows a saved scan inside Auto-Fixer, for remote sessions with no web browser.
# It reads the saved scan file only (AF-...-scan.json, or results.json from older runs),
# so it shows exactly what was saved (redacted unless the technician chose otherwise) and never reads Windows logs or changes anything.

$script:AfSeverityOrder = @('Critical', 'High', 'Medium', 'Low', 'Info')

function Read-AfReportModel {
    # The saved model from a scan file. Throws a plain reason when it can't be read.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'the file is missing' }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'the file is empty' }
    try { $model = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'the file is not valid JSON' }
    if ($model.schemaVersion -ne 1 -or $null -eq $model.PSObject.Properties['findings']) { throw 'the file is not an Auto-Fixer results file' }
    # An empty or null list reads back as nothing, never as one empty item.
    $model.findings = @($model.findings | Where-Object { $null -ne $_ })
    foreach ($f in $model.findings) {
        if ($f.PSObject.Properties['evidence']) { $f.evidence = @($f.evidence | Where-Object { $null -ne $_ }) }
    }
    if ($model.PSObject.Properties['steps']) { $model.steps = @($model.steps | Where-Object { $null -ne $_ }) }
    return $model
}

function Get-AfReportRun {
    # Saved scans, newest first: Path (.json), Html, RunId and the time the file was written.
    # Finds PC-<id>\AF-<id>-<run>-scan.json and older <run>\results.json folders alike.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot, [int] $Count = 9)

    if (-not (Test-Path -LiteralPath $OutputRoot)) { return }
    Get-ChildItem -LiteralPath $OutputRoot -Recurse -Filter '*.json' -File |
        Where-Object { $_.Name -eq 'results.json' -or $_.Name -match '^AF-[A-Z2-9]{6}-.+-scan\.json$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Count | ForEach-Object {
            if ($_.Name -eq 'results.json') { $runId = $_.Directory.Name; $html = Join-Path $_.DirectoryName 'report.html' }
            else { $runId = $_.Name -replace '^AF-[A-Z2-9]{6}-(.+)-scan\.json$', '$1'; $html = $_.FullName -replace '\.json$', '.html' }
            [pscustomobject]@{ Path = $_.FullName; Html = $html; RunId = $runId; Written = $_.LastWriteTime }
        }
}

function Format-AfReportTime {
    # results.json keeps round-trip times; PowerShell 7 reads them as dates, 5.1 as text.
    param($Value)

    if ($null -eq $Value -or [string]$Value -eq '') { return 'unknown' }
    try { return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm') } catch { return [string]$Value }
}

function Get-AfSeverityCount {
    # 'CRITICAL 1  HIGH 2  MEDIUM 0  LOW 0  INFO 0', in words so colour is never needed.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Model)

    $findings = @($Model.findings)
    (@(foreach ($s in $script:AfSeverityOrder) {
                '{0} {1}' -f $s.ToUpperInvariant(), @($findings | Where-Object { $_.severity -eq $s }).Count
            }) -join '  ')
}

function Get-AfReportSummaryLines {
    # The top of the results screen. Each line fits the menu box (46 columns).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Model)

    $count = @($Model.findings).Count
    if ($count -gt 0) { '{0} problem(s) found in the last {1} days.' -f $count, $Model.days }
    else { 'No known problems found in the last {0} days.' -f $Model.days }
    Get-AfSeverityCount -Model $Model
    $stability = 'n/a'
    if ($null -ne $Model.stabilityIndex) { $stability = '{0:N1} / 10' -f [double]$Model.stabilityIndex }
    'Stability {0}, {1} log entries checked' -f $stability, $Model.evidenceCount
    $admin = 'No'
    if ($Model.machine.isAdmin) { $admin = 'Yes' }
    'Scanned {0}, administrator: {1}' -f (Format-AfReportTime $Model.startedAt), $admin
    if ($Model.redacted) { 'Sensitive data: redacted' }
    else { 'NOT redacted - handle with care' }
}

function Get-AfFindingLabel {
    # One list line: '[HIGH] Title (12)', cut to fit beside the WHAT THIS DOES panel.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Finding, [int] $Width = 38)

    # An & would mark a menu letter, so titles never carry one.
    $title = ([string]$Finding.title).Replace('&', '+')
    $tail = ' ({0})' -f $Finding.count
    $head = '[{0}] ' -f ([string]$Finding.severity).ToUpperInvariant()
    $room = $Width - $head.Length - $tail.Length
    if ($title.Length -gt $room) { $title = $title.Substring(0, [math]::Max(0, $room - 3)) + '...' }
    return $head + $title + $tail
}

function Get-AfFixText {
    # 'FIX-SFC (main menu 2, Repair system files: S)', the same words as report.html.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()] [object[]] $Fixes)

    $Fixes = @($Fixes | Where-Object { $_ })
    if ($Fixes.Count -eq 0) { return 'Advice only' }
    (@($Fixes | ForEach-Object {
                $label = [string]$_
                if ($script:AfFixMenuLabels.ContainsKey($label)) { $label += ' (' + $script:AfFixMenuLabels[$label] + ')' }
                $label
            }) -join ', ')
}

function Get-AfFindingLines {
    # Everything about one finding as lines that fit 80 columns: explanation, fixes, evidence.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Finding)

    ''
    foreach ($part in (Split-AfText -Text ('[{0}] {1}' -f ([string]$Finding.severity).ToUpperInvariant(), $Finding.title) -Width 76)) { '  ' + $part }
    '    {0}, {1} entries, first {2}, last {3}' -f $Finding.category, $Finding.count, (Format-AfReportTime $Finding.firstSeen), (Format-AfReportTime $Finding.lastSeen)
    ''
    if ($Finding.explanation) { foreach ($part in (Split-AfText -Text ([string]$Finding.explanation) -Width 74)) { '    ' + $part } }
    ''
    '  Suggested fixes'
    foreach ($part in (Split-AfText -Text (Get-AfFixText -Fixes @($Finding.fixes)) -Width 74)) { '    ' + $part }
    ''
    '  Evidence ({0} entries, newest first)' -f $Finding.count
    foreach ($ev in @($Finding.evidence)) {
        '    {0}  {1}  {2} {3}' -f (Format-AfReportTime $ev.time), $ev.source, $ev.provider, $ev.eventId
        # Cut like report.html, so a long log message can't fill pages.
        $msg = ([string]$ev.message) -replace '\s+', ' '
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
        if ($msg) { foreach ($part in (Split-AfText -Text $msg -Width 72)) { '      ' + $part } }
    }
}

function Get-AfStepLines {
    # The 'What was checked' list.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Model)

    ''
    '  What was checked'
    foreach ($s in @($Model.steps)) {
        foreach ($part in (Split-AfText -Text ('{0,-8} {1} ({2} items, {3} s): {4}' -f $s.status, $s.name, $s.count, $s.seconds, $s.summary) -Width 74)) { '    ' + $part }
    }
    ''
    '  Auto-Fixer only read logs during this scan. Nothing on this PC was changed.'
}

function Get-AfReportLines {
    # The whole report as plain text, for -ShowLastReport and redirected output.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Model)

    'Auto-Fixer report {0}' -f $Model.runId
    if ($Model.machine.PSObject.Properties['pcId']) { '  PC id {0}' -f $Model.machine.pcId }
    '  {0}, {1}' -f $Model.machine.computerName, $Model.machine.os
    foreach ($line in (Get-AfReportSummaryLines -Model $Model)) { '  ' + $line }
    ''
    '  Findings'
    if (@($Model.findings).Count -eq 0) { '    Nothing matched a known problem signature.' }
    foreach ($f in @($Model.findings)) { Get-AfFindingLines -Finding $f }
    Get-AfStepLines -Model $Model
}

function Show-AutoFixerReport {
    <#
    .SYNOPSIS
        Returns a saved scan as plain text lines, so it can be piped or saved. The
        newest scan unless -RunId names another. Throws a plain reason when there is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $OutputRoot = (Join-Path $env:ProgramData 'AutoFixer\Runs'),
        [string] $RunId
    )

    if ($RunId) {
        $path = @(Get-AfReportRun -OutputRoot $OutputRoot -Count ([int]::MaxValue) | Where-Object RunId -eq $RunId | ForEach-Object Path)[0]
        if (-not $path) { throw ('No saved scan has run id {0}.' -f $RunId) }
    }
    else { $path = @(Get-AfReportRun -OutputRoot $OutputRoot -Count 1 | ForEach-Object Path)[0] }
    if (-not $path) { throw 'No report yet. Run a scan first.' }
    try { $model = Read-AfReportModel -Path $path }
    catch { throw ("This report can't be read: {0}." -f $_.Exception.Message) }
    Get-AfReportLines -Model $model
}

function Select-AfFinding {
    # The findings list, 9 to a page so every one has a number. Returns the finding or $null for Back.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Model,
        [string] $Mode = 'Standard',
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $findings = @($Model.findings)
    $pageSize = 9
    $pages = [math]::Max(1, [math]::Ceiling($findings.Count / $pageSize))
    $page = 0
    while ($true) {
        $first = $page * $pageSize
        $items = @()
        $itemInfo = @{}
        for ($i = $first; $i -lt [math]::Min($first + $pageSize, $findings.Count); $i++) {
            $f = $findings[$i]
            $key = 'F{0}' -f $i
            $items += @{ Key = $key; Label = (Get-AfFindingLabel -Finding $f) }
            $itemInfo[$key] = @([string]$f.severity, ('{0} entries' -f $f.count), ('Last seen {0}' -f (Format-AfReportTime $f.lastSeen)), '', 'Enter shows the explanation, fixes and evidence.')
        }
        if ($page -lt $pages - 1) { $items += @{ Key = 'N'; Label = '&Next page' } }
        if ($page -gt 0) { $items += @{ Key = 'P'; Label = '&Previous page' } }
        $items[-1].Divider = $true
        $items += @{ Key = 'B'; Label = '&Back' }
        $itemInfo.N = @('The next findings.')
        $itemInfo.P = @('The findings before these.')
        $itemInfo.B = @('Back to the results.')

        $title = 'Findings'
        if ($pages -gt 1) { $title = 'Findings, page {0} of {1}' -f ($page + 1), $pages }
        $header = { Show-AfBanner -Mode $Mode }
        $choice = Select-AfMenuItem -Title $title -Items $items -Header $header -ItemInfo $itemInfo -Mode $Mode -EscapeKey 'B' -ReadKey $ReadKey
        switch ($choice) {
            'N' { $page++ }
            'P' { $page-- }
            'B' { return $null }
            default { return $findings[[int]$choice.Substring(1)] }
        }
    }
}

function Invoke-AfResultsViewer {
    <#
    .SYNOPSIS
        The results screen for one saved scan: summary, findings list, finding detail
        and what was checked. Sets $script:AfQuitRequested when the user quits here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Mode = 'Standard',
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    try { $model = Read-AfReportModel -Path $Path }
    catch {
        Write-Host ''
        Write-Host ("  This report can't be read: {0}." -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host '  Press any key to go back.' -ForegroundColor DarkGray
        $null = & $ReadKey
        return
    }

    $summary = @(Get-AfReportSummaryLines -Model $model)
    $banner = { Show-AfBanner -Mode $Mode }
    $header = {
        & $banner
        Write-Host ''
        foreach ($line in $summary) { Write-Host ('  ' + $line) }
    }
    $count = @($model.findings).Count
    $itemInfo = @{
        F = @('One line per problem, worst first.', '', 'Pick one for its explanation, suggested fixes and evidence.')
        C = @('Every check the scan ran, with its result and time.')
        B = @('Back to the report menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    while ($true) {
        $items = @()
        if ($count -gt 0) { $items += @{ Key = 'F'; Label = ('&Findings ({0})' -f $count) } }
        $items += @{ Key = 'C'; Label = 'What was &checked'; Divider = $true }
        $items += @{ Key = 'B'; Label = '&Back' }
        $items += @{ Key = 'Q'; Label = '&Quit' }
        $title = 'Scan results {0}' -f $model.runId
        $choice = Select-AfMenuItem -Title $title -Items $items -Header $header -Info $summary -ItemInfo $itemInfo -Mode $Mode -EscapeKey 'B' -ReadKey $ReadKey
        switch ($choice) {
            'F' {
                while ($true) {
                    $finding = Select-AfFinding -Model $model -Mode $Mode -ReadKey $ReadKey
                    if (-not $finding) { break }
                    Show-AfPagedLines -Lines @(Get-AfFindingLines -Finding $finding) -Header $banner -ReadKey $ReadKey
                }
            }
            'C' { Show-AfPagedLines -Lines @(Get-AfStepLines -Model $model) -Header $banner -ReadKey $ReadKey }
            'B' { return }
            'Q' { if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return } }
        }
    }
}

function Invoke-AfReportMenu {
    # Main menu item 4: view the newest scan here, open it in a browser, or pick an earlier one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [string] $Mode = 'Standard',
        # Called with the report.html path.
        [scriptblock] $OpenAction = { param($ReportPath) Invoke-Item -LiteralPath $ReportPath },
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $items = @(
        @{ Key = 'V'; Label = '&View the results here' }
        @{ Key = 'O'; Label = '&Open in the web browser' }
        @{ Key = 'E'; Label = '&Earlier reports'; Divider = $true }
        @{ Key = 'B'; Label = '&Back' }
        @{ Key = 'Q'; Label = '&Quit' }
    )
    $itemInfo = @{
        V = @('Shows the newest scan in this window. Works over remote sessions.', '', 'Changes system: NO')
        O = @('Opens the newest saved report in your web browser.', '', 'Changes system: NO')
        E = @('Pick one of the last 9 scans to view here.')
        B = @('Back to the main menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $header = { Show-AfBanner -Mode $Mode }
    $notice = $null
    while ($true) {
        $choice = Select-AfMenuItem -Title 'Reports' -Items $items -Header $header -ItemInfo $itemInfo -Mode $Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        $latest = @(Get-AfReportRun -OutputRoot $OutputRoot -Count 1)
        switch ($choice) {
            'V' {
                if ($latest.Count -gt 0) { Invoke-AfResultsViewer -Path $latest[0].Path -Mode $Mode -ReadKey $ReadKey }
                else { $notice = 'No report yet. Run a scan first.' }
            }
            'O' {
                $html = Find-AfLatestReport -OutputRoot $OutputRoot
                if ($html) { & $OpenAction $html }
                else { $notice = 'No report yet. Run a scan first.' }
            }
            'E' {
                $runs = @(Get-AfReportRun -OutputRoot $OutputRoot -Count 9)
                if ($runs.Count -eq 0) { $notice = 'No report yet. Run a scan first.' }
                else {
                    $runItems = @(for ($i = 0; $i -lt $runs.Count; $i++) { @{ Key = ('R{0}' -f $i); Label = ('{0}  run {1}' -f $runs[$i].Written.ToString('yyyy-MM-dd HH:mm'), $runs[$i].RunId) } })
                    $runItems[-1].Divider = $true
                    $runItems += @{ Key = 'B'; Label = '&Back' }
                    $pick = Select-AfMenuItem -Title 'Earlier reports' -Items $runItems -Header $header -Info @('Newest first.') -Mode $Mode -EscapeKey 'B' -ReadKey $ReadKey
                    if ($pick -ne 'B') { Invoke-AfResultsViewer -Path $runs[[int]$pick.Substring(1)].Path -Mode $Mode -ReadKey $ReadKey }
                }
            }
            'B' { return }
            'Q' { if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return } }
        }
        if ($script:AfQuitRequested) { return }
    }
}
