# Collectors that scan text log files: Windows Error Reporting, CBS/DISM and
# setupapi. Each has a pure ConvertFrom-* parser (tested on sample files in
# Tests/Data) and a thin Get-* wrapper that finds the files on this machine.

# Log files can be hundreds of MB; only the newest lines matter for a 14-day window.
$script:AfTailLines = 50000

function ConvertFrom-AfWerReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines,
        [string] $Path = '',
        [datetime] $FallbackTime = (Get-Date)
    )

    $raw = @{}
    foreach ($line in $Lines) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $raw[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1).Trim() }
    }
    if ($raw.Count -eq 0) { return }

    # Sig[n].Name / Sig[n].Value pairs become named fields, e.g. "Application Name" = "app.exe".
    $fields = @{}
    foreach ($key in @($raw.Keys)) {
        if ($key -match '^Sig\[(\d+)\]\.Name$') {
            $valueKey = 'Sig[{0}].Value' -f $Matches[1]
            if ($raw.ContainsKey($valueKey)) { $fields[$raw[$key]] = $raw[$valueKey] }
        }
    }
    foreach ($name in 'EventType', 'FriendlyEventName', 'AppName', 'AppPath') {
        if ($raw.ContainsKey($name)) { $fields[$name] = $raw[$name] }
    }

    # EventTime is a Windows FILETIME (100 ns ticks since 1601, UTC).
    $time = $FallbackTime
    [long]$fileTime = 0
    if ($raw.ContainsKey('EventTime') -and [long]::TryParse($raw['EventTime'], [ref]$fileTime) -and $fileTime -gt 0) {
        $time = [datetime]::FromFileTimeUtc($fileTime).ToLocalTime()
    }

    $app = $fields['Application Name']
    if (-not $app) { $app = $fields['AppName'] }
    $eventType = $fields['EventType']
    $message = '{0}: {1}' -f $eventType, $app
    if ($fields.ContainsKey('Fault Module Name')) { $message += ' (faulting module {0})' -f $fields['Fault Module Name'] }

    New-AfEvidence -Source 'WER' -TimeCreated $time -Provider 'Windows Error Reporting' -Level 2 `
        -Message $message -Path $Path -Fields $fields
}

function Get-AfWerEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $Since,
        [string] $WerRoot = (Join-Path $env:ProgramData 'Microsoft\Windows\WER')
    )

    foreach ($folder in 'ReportArchive', 'ReportQueue') {
        $dir = Join-Path $WerRoot $folder
        if (-not (Test-Path $dir)) { continue }
        $reports = Get-ChildItem -Path $dir -Filter 'Report.wer' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since }
        foreach ($report in $reports) {
            $lines = Get-Content -Path $report.FullName -Encoding Unicode -ErrorAction SilentlyContinue
            if ($lines) { ConvertFrom-AfWerReport -Lines $lines -Path $report.FullName -FallbackTime $report.LastWriteTime }
        }
    }
}

function ConvertFrom-AfCbsLog {
    <#
    .SYNOPSIS
        CBS.log and dism.log lines start with "yyyy-MM-dd HH:mm:ss, Level". Keeps the
        lines that report damage. Leaves out status lines that only use the word
        (counters that read 0, "flag is clear", "was fixed", repair transaction
        notes), and component-store damage that a later line in the same log says
        was fixed ("All CSI corruption was fixed", "numCorruptions = 0"). SFC's
        "Cannot repair member file" lines are always kept: only SFC itself can clear them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [datetime] $Since,
        [string] $Path = '',
        [int] $MaxItems = 200
    )

    $pattern = 'Cannot repair|corrupt|0x800f081f|0x800f0906'
    $status = '(?i)corruption:\s*0\s*$|numCorruptions = 0|flag is clear|is clear\s*$|was fixed|StoreCorruptionRepair transaction|Seconds between|Count of times corruption detected|Failed to clear CorruptionDetectedDuringAcr|Processing complete, session\(Corruption Repairing\)'
    $store = '(?i)CSI\b.*corruption|meta ?data corruption|payload corruption|manifest corruption'
    $storeClean = '(?i)All CSI corruption was fixed|numCorruptions = 0|Total Detected Corruption:\s*0\s*$'

    $found = New-Object System.Collections.Generic.List[object]
    $lastClean = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line.Length -lt 20) { continue }
        if ($line -match $storeClean) { $lastClean = $i }
        if ($line -notmatch $pattern -or $line -match $status) { continue }
        $time = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($line.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$time)
        if (-not $ok -or $time -lt $Since) { continue }
        $found.Add(@{ Index = $i; Time = $time; Text = $line.Substring(21).Trim(); Store = ($line -match $store) })
    }

    $count = 0
    foreach ($hit in $found) {
        if ($hit.Store -and $hit.Index -lt $lastClean) { continue }
        New-AfEvidence -Source $Source -TimeCreated $hit.Time -Provider $Source -Level 2 -Message $hit.Text -Path $Path
        $count++
        if ($count -ge $MaxItems) { break }
    }
}

function Get-AfServicingLogEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $Since,
        [string] $WindowsRoot = $env:SystemRoot
    )

    $logs = @(
        @{ Source = 'CBS'; Path = Join-Path $WindowsRoot 'Logs\CBS\CBS.log' },
        @{ Source = 'DISM'; Path = Join-Path $WindowsRoot 'Logs\DISM\dism.log' }
    )
    foreach ($log in $logs) {
        if (-not (Test-Path $log.Path)) { continue }
        $lines = Get-Content -Path $log.Path -Tail $script:AfTailLines -ErrorAction Stop
        ConvertFrom-AfCbsLog -Lines $lines -Source $log.Source -Since $Since -Path $log.Path
    }
}

function ConvertFrom-AfSetupApiLog {
    # Each device install is a section: ">>>  [name]", ">>>  Section start <time>",
    # then "<<<  [Exit status: FAILURE(0x...)]" when it failed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines,
        [Parameter(Mandatory)] [datetime] $Since,
        [string] $Path = ''
    )

    $section = ''
    $start = [datetime]::MinValue
    foreach ($line in $Lines) {
        if ($line -match '^>>>\s+\[(.+)\]\s*$') {
            $section = $Matches[1]
            $start = [datetime]::MinValue
        }
        elseif ($line -match '^>>>\s+Section start (\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})') {
            $start = [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        }
        elseif ($line -match '^<<<\s+\[Exit status:\s*FAILURE\(([^)]+)\)\]') {
            if ($start -ge $Since) {
                New-AfEvidence -Source 'SetupApi' -TimeCreated $start -Provider 'SetupAPI' -Level 2 `
                    -Message ('{0} failed with {1}' -f $section, $Matches[1]) -Path $Path `
                    -Fields @{ Section = $section; ExitStatus = $Matches[1] }
            }
        }
    }
}

function Get-AfSetupApiEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $Since,
        [string] $WindowsRoot = $env:SystemRoot
    )

    $path = Join-Path $WindowsRoot 'INF\setupapi.dev.log'
    if (-not (Test-Path $path)) { return }
    $lines = Get-Content -Path $path -Tail $script:AfTailLines -ErrorAction Stop
    ConvertFrom-AfSetupApiLog -Lines $lines -Since $Since -Path $path
}
