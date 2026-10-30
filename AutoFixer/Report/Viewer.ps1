# Shows a saved scan inside Auto-Fixer, for remote sessions with no web browser.
# It reads results.json only, so it shows exactly what was saved (redacted unless
# the technician chose otherwise) and never reads Windows logs or changes anything.

$script:AfSeverityOrder = @('Critical', 'High', 'Medium', 'Low', 'Info')

function Read-AfReportModel {
    # The saved model from results.json. Throws a plain reason when it can't be read.
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
    # Saved scans, newest first: Path, RunId and the time the file was written.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot, [int] $Count = 9)

    if (-not (Test-Path -LiteralPath $OutputRoot)) { return }
    Get-ChildItem -LiteralPath $OutputRoot -Recurse -Filter 'results.json' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Count | ForEach-Object {
            [pscustomobject]@{ Path = $_.FullName; RunId = $_.Directory.Name; Written = $_.LastWriteTime }
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

# The widest list line that fits a full-width menu box (columns 10-79); Signatures.Tests holds every title to it.
$script:AfListLabelWidth = 70

function Get-AfFindingLabel {
    # One list line: '[HIGH] Title (12)'. Never cut: the list uses the full width.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Finding)

    # An & would mark a menu letter, so titles never carry one.
    '[{0}] {1} ({2})' -f ([string]$Finding.severity).ToUpperInvariant(), ([string]$Finding.title).Replace('&', '+'), $Finding.count
}

function Get-AfEvidenceLabel {
    # One list line per log entry: '2026-10-28 14:03  System  event 7'.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Evidence)

    '{0}  {1}  event {2}' -f (Format-AfReportTime $Evidence.time), $Evidence.source, $Evidence.eventId
}

function Split-AfMessage {
    # A log message wrapped at spaces, keeping its own line breaks. Words, and so links,
    # are never split or cut, so a long link stays whole on its line for Ctrl+click.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text, [int] $Width = 72)

    $blank = $false
    foreach ($para in (([string]$Text).Trim() -split '\r?\n')) {
        $para = $para.Trim() -replace '\s+', ' '
        if (-not $para) {
            if (-not $blank) { '' }
            $blank = $true
            continue
        }
        $blank = $false
        Split-AfText -Text $para -Width $Width
    }
}

function Get-AfEvidenceLines {
    # One log entry in full.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Evidence)

    '    {0}  {1}  {2}  event {3}' -f (Format-AfReportTime $Evidence.time), $Evidence.source, $Evidence.provider, $Evidence.eventId
    if ($Evidence.path) { '      File: {0}' -f $Evidence.path }
    foreach ($line in (Split-AfMessage -Text ([string]$Evidence.message) -Width 72)) { ('      ' + $line).TrimEnd() }
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
    # One finding: explanation and fixes, then (with -Evidence) every log entry in full.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Finding, [switch] $Evidence)

    ''
    foreach ($part in (Split-AfText -Text ('[{0}] {1}' -f ([string]$Finding.severity).ToUpperInvariant(), $Finding.title) -Width 76)) { '  ' + $part }
    '    {0}, {1} entries, first {2}, last {3}' -f $Finding.category, $Finding.count, (Format-AfReportTime $Finding.firstSeen), (Format-AfReportTime $Finding.lastSeen)
    ''
    if ($Finding.explanation) { foreach ($part in (Split-AfText -Text ([string]$Finding.explanation) -Width 74)) { '    ' + $part } }
    ''
    '  Suggested fixes'
    foreach ($part in (Split-AfText -Text (Get-AfFixText -Fixes @($Finding.fixes)) -Width 74)) { '    ' + $part }
    if (-not $Evidence) { return }
    ''
    '  Evidence ({0} entries, newest first)' -f $Finding.count
    foreach ($ev in @($Finding.evidence)) {
        Get-AfEvidenceLines -Evidence $ev
        ''
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
    '  {0}, {1}' -f $Model.machine.computerName, $Model.machine.os
    foreach ($line in (Get-AfReportSummaryLines -Model $Model)) { '  ' + $line }
    ''
    '  Findings'
    if (@($Model.findings).Count -eq 0) { '    Nothing matched a known problem signature.' }
    foreach ($f in @($Model.findings)) { Get-AfFindingLines -Finding $f -Evidence }
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

    $path = $null
    if ($RunId) { $path = Join-Path (Join-Path $OutputRoot $RunId) 'results.json' }
    else { $path = @(Get-AfReportRun -OutputRoot $OutputRoot -Count 1 | ForEach-Object Path)[0] }
    if (-not $path) { throw 'No report yet. Run a scan first.' }
    try { $model = Read-AfReportModel -Path $path }
    catch { throw ("This report can't be read: {0}." -f $_.Exception.Message) }
    Get-AfReportLines -Model $model
}

function Select-AfPagedPick {
    <#
    .SYNOPSIS
        A full-width pick list, paged so every line fits the box and has a number. Returns the
        picked line's index, the -Lead item's Key, or $null for Back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [AllowEmptyCollection()] [string[]] $Labels = @(),
        # Lines shown above the list.
        [string[]] $Info = @(),
        # An item before the list, such as @{ Key = 'A'; Label = '&About this problem' }.
        [hashtable] $Lead,
        [string] $Mode = 'Standard',
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    # The menu box has 14 rows: the lines above the list and a gap, the lead item, the
    # page, Next, Previous, the divider and Back. Numbers 1-9 reach at most 9 items.
    $pageSize = 14 - $Info.Count - 1 - 4
    if ($Lead) { $pageSize-- }
    $pageSize = [math]::Max(1, [math]::Min(9, $pageSize))
    $pages = [math]::Max(1, [math]::Ceiling($Labels.Count / $pageSize))
    $page = 0
    # Ascii screens show the lines above the list through the header.
    $header = {
        Show-AfBanner -Mode $Mode
        foreach ($line in $Info) { Write-Host ('  ' + $line) }
    }
    while ($true) {
        $first = $page * $pageSize
        $items = @()
        if ($Lead) { $items += @{ Key = $Lead.Key; Label = $Lead.Label } }
        for ($i = $first; $i -lt [math]::Min($first + $pageSize, $Labels.Count); $i++) { $items += @{ Key = ('L{0}' -f $i); Label = $Labels[$i] } }
        if ($page -lt $pages - 1) { $items += @{ Key = 'N'; Label = '&Next page' } }
        if ($page -gt 0) { $items += @{ Key = 'P'; Label = '&Previous page' } }
        if ($items.Count) { $items[-1].Divider = $true }
        $items += @{ Key = 'B'; Label = '&Back' }

        $pageTitle = $Title
        if ($pages -gt 1) { $pageTitle = '{0}, page {1} of {2}' -f $Title, ($page + 1), $pages }
        $choice = Select-AfMenuItem -Title $pageTitle -Items $items -Header $header -Info $Info -Mode $Mode -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'N') { $page++ }
        elseif ($choice -eq 'P') { $page-- }
        elseif ($choice -eq 'B') { return $null }
        elseif ($Lead -and $choice -eq $Lead.Key) { return [string]$choice }
        else { return [int]$choice.Substring(1) }
    }
}

function Select-AfFinding {
    # The findings list, worst first. Returns the finding or $null for Back.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Model,
        [string] $Mode = 'Standard',
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $findings = @($Model.findings)
    $labels = @($findings | ForEach-Object { Get-AfFindingLabel -Finding $_ })
    $pick = Select-AfPagedPick -Title 'Findings' -Labels $labels -Info @('Worst first. Pick one for its explanation, fixes and log entries.') -Mode $Mode -ReadKey $ReadKey
    if ($null -eq $pick) { return $null }
    return $findings[$pick]
}

function Invoke-AfFindingView {
    # One finding: its explanation and fixes, then each log entry, folded to one line
    # until it is picked. Picking shows the whole message, never cut.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Finding,
        [string] $Mode = 'Standard',
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $evidence = @($Finding.evidence)
    $labels = @($evidence | ForEach-Object { Get-AfEvidenceLabel -Evidence $_ })
    $info = @((Get-AfFindingLabel -Finding $Finding), ('{0} log entries, newest first. Pick one to read it in full.' -f $evidence.Count))
    $banner = { Show-AfBanner -Mode $Mode }
    while ($true) {
        $pick = Select-AfPagedPick -Title 'Finding' -Labels $labels -Info $info -Lead @{ Key = 'A'; Label = '&About this problem and its fixes' } -Mode $Mode -ReadKey $ReadKey
        if ($null -eq $pick) { return }
        if ($pick -is [string]) { Show-AfPagedLines -Lines @(Get-AfFindingLines -Finding $Finding) -Header $banner -ReadKey $ReadKey }
        else { Show-AfPagedLines -Lines @('', (Get-AfEvidenceLines -Evidence $evidence[$pick])) -Header $banner -ReadKey $ReadKey }
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
                    Invoke-AfFindingView -Finding $finding -Mode $Mode -ReadKey $ReadKey
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
        O = @('Opens the newest report.html in your web browser.', '', 'Changes system: NO')
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
