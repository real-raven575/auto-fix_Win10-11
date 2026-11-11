# Printers (raven575 2026-11-10: "common printer fixes, spooler reset, etc").
# Plan: plans/printer-fixes-plan-2026-11-10.md in the project files.
#   - a printer check runs first and changes nothing
#   - every fix says what it will do and asks Y/N; clearing every job asks twice
#   - print job document names and owners are never read, only counts and ages
#   - printer names are redacted on screen (unless Show sensitive is on) and always in
#     the log; port addresses are never shown or logged, only the port kind
#   - no internet, nothing installed: Win32_* classes, sc.exe and one HKCU value
#   - Technician mode adds spooler recovery, remove a printer, remove an unused driver

$script:AfSpoolDir = '{0}\System32\spool\PRINTERS' -f ([string]$env:SystemRoot).TrimEnd('\')
$script:AfPrintKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'
$script:AfPrintProcessorRoots = @(
    'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Print Processors'
    'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows NT x86\Print Processors'
)
# Drivers that ship with Windows; U never offers them.
$script:AfBuiltInDriverPattern = '^(Microsoft |Remote Desktop Easy Print|Generic / Text Only|Generic IBM Graphics|Universal Print Class Driver)'
# Drivers that ship with Windows come from these setup (INF) files, whatever their name.
$script:AfInboxInfPattern = '^(ntprint\d*|prnms\d+)\.inf$'

function Get-AfSpoolerExitText {
    # sc.exe and service exit codes in plain words, with the number always shown.
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Code)

    $meaning = @{
        0 = 'done'; 5 = 'access denied, start Auto-Fixer as administrator'
        1051 = 'other running services depend on it'; 1052 = 'not a valid command for this service'
        1053 = 'the service did not answer in time'; 1056 = 'it was already running'
        1058 = 'the service is disabled'; 1060 = 'the service is not installed'
        1061 = 'the service cannot take commands right now'; 1062 = 'it was not running'
    }
    if ($meaning.ContainsKey($Code)) { return ('{0} ({1})' -f $Code, $meaning[$Code]) }
    return ('{0} (not a known code; "net helpmsg {0}" explains it)' -f $Code)
}

function Get-AfPrinterPortKind {
    # USB, network and so on, from the port name. The port name itself is never shown.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Port)

    if ($Port -match '^\\\\') { return 'Shared' }
    if ($Port -match '^USB') { return 'USB' }
    if ($Port -match '^WSD') { return 'WSD' }
    if ($Port -match '^(LPT|COM)\d') { return 'Local' }
    if ($Port -match '^(FILE:|PORTPROMPT:|nul:|SHRFAX:)') { return 'File' }
    if ($Port -match '^(TS|TPVM)\d') { return 'Remote' }
    if ($Port -match '^(IP_)?\d{1,3}(\.\d{1,3}){3}') { return 'Network' }
    if ($Port) { return 'Other' }
    return 'None'
}

function Get-AfPrinterStatusText {
    # Win32_Printer state in words. "Use printer offline" wins over the printer's own state.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Printer)

    if ($Printer.WorkOffline) { return 'Offline (set)' }
    $words = @{ 3 = 'Ready'; 4 = 'Printing'; 5 = 'Warming up'; 6 = 'Stopped'; 7 = 'Offline' }
    $code = [int]$Printer.PrinterStatus
    if ($words.ContainsKey($code)) { return $words[$code] }
    return 'Unknown'
}

function Get-AfJobPrinterName {
    # Win32_PrintJob names a job 'Printer name, 12'.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Name)

    $at = $Name.LastIndexOf(',')
    if ($at -lt 0) { return $Name }
    return $Name.Substring(0, $at)
}

function Get-AfPrinterEventCount {
    # Spooler crashes and PrintService errors in the last few days. Read-only.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int] $Days = 7)

    $since = (Get-Date).AddDays(-$Days)
    $crashes = 0
    $errors = 0
    # Service Control Manager names the service by its display name, which Windows translates.
    $display = [string](Get-Service -Name Spooler -ErrorAction SilentlyContinue).DisplayName
    try {
        $scm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $since } -ErrorAction Stop)
        $crashes += @($scm | Where-Object { $display -and [string]$_.Properties[0].Value -eq $display }).Count
    }
    catch { Write-Verbose 'No spooler stop events.' }
    try {
        $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction Stop)
        $crashes += @($app | Where-Object { [string]$_.Properties[0].Value -match '^spoolsv\.exe$' }).Count
    }
    catch { Write-Verbose 'No print spooler crash events in Application.' }
    try { $errors = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-PrintService/Admin'; Level = 2; StartTime = $since } -ErrorAction Stop).Count }
    catch { Write-Verbose 'No PrintService errors.' }
    return [pscustomobject]@{ Crashes = $crashes; PrintErrors = $errors; Days = $Days }
}

function Get-AfPrinterSource {
    # Where the check reads from. Tests pass their own script blocks.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        Service       = { Get-CimInstance -ClassName Win32_Service -Filter "Name='Spooler'" -ErrorAction Stop }
        Printers      = { @(Get-CimInstance -ClassName Win32_Printer -Property Name, PrinterStatus, WorkOffline, Default, PortName, DriverName -ErrorAction Stop) }
        # Only the job name (printer and number), time and state: never Document or Owner.
        Jobs          = { @(Get-CimInstance -ClassName Win32_PrintJob -Property Name, TimeSubmitted, StatusMask -ErrorAction SilentlyContinue) }
        # Throws when the folder cannot be read (it needs administrator rights), so the check can say so.
        SpoolFiles    = { @(Get-ChildItem -LiteralPath $script:AfSpoolDir -File -Force -ErrorAction Stop) }
        Events        = { Get-AfPrinterEventCount }
        LegacyDefault = { (Get-ItemProperty -LiteralPath $script:AfPrintKey -Name LegacyDefaultPrinterMode -ErrorAction SilentlyContinue).LegacyDefaultPrinterMode }
        Processors    = { @(foreach ($root in $script:AfPrintProcessorRoots) { Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName } }) }
        Recovery      = { @((Invoke-AfTool -Name 'sc.exe' -ArgumentList 'qfailure', 'Spooler').Lines) }
    }
}

function Get-AfPrinterCheck {
    <#
    .SYNOPSIS
        The read-only printer check: the Print Spooler, every printer and its waiting
        jobs, the spool folder, recent crashes and third-party print processors.
        Changes nothing. -OnStep is called with (number, count, words) before each part.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Source = (Get-AfPrinterSource),
        [datetime] $Now = (Get-Date),
        [scriptblock] $OnStep = { }
    )

    & $OnStep 1 6 'Print Spooler service'
    $svc = & $Source.Service
    $state = 'Not installed'
    $start = 'Unknown'
    if ($svc) { $state = [string]$svc.State; $start = [string]$svc.StartMode }

    & $OnStep 2 6 'Printers and waiting jobs'
    $jobs = @(& $Source.Jobs)
    $printers = New-Object System.Collections.ArrayList
    foreach ($p in @(& $Source.Printers)) {
        $name = [string]$p.Name
        $mine = @($jobs | Where-Object { (Get-AfJobPrinterName ([string]$_.Name)) -eq $name })
        $times = @($mine | Where-Object { $_.TimeSubmitted } | ForEach-Object { [datetime]$_.TimeSubmitted } | Sort-Object)
        $oldest = $null
        if ($times.Count) { $oldest = [int][math]::Max(0, [math]::Floor(($Now - $times[0]).TotalMinutes)) }
        [void]$printers.Add([pscustomobject]@{
                Name          = $name
                Status        = Get-AfPrinterStatusText -Printer $p
                Offline       = [bool]$p.WorkOffline
                Default       = [bool]$p.Default
                PortKind      = Get-AfPrinterPortKind -Port ([string]$p.PortName)
                Driver        = [string]$p.DriverName
                Jobs          = $mine.Count
                OldestMinutes = $oldest
                ErrorJobs     = @($mine | Where-Object { ([uint32]$_.StatusMask -band 2) -ne 0 }).Count
            })
    }

    & $OnStep 3 6 'Spool folder'
    $files = @()
    $spoolReadable = $true
    try { $files = @(& $Source.SpoolFiles) }
    catch { $spoolReadable = $false; Write-Verbose ('Spool folder not readable: {0}' -f $_.Exception.Message) }
    $bytes = [long]0
    foreach ($f in $files) { $bytes += [long]$f.Length }

    & $OnStep 4 6 'Spooler crashes and print errors (7 days)'
    $events = & $Source.Events

    & $OnStep 5 6 'Default printer setting and print processors'
    $legacy = & $Source.LegacyDefault
    $processors = @(@(& $Source.Processors) | Where-Object { $_ -and $_ -ne 'winprint' } | Sort-Object -Unique)

    & $OnStep 6 6 'Spooler recovery setting'
    $recovery = @(& $Source.Recovery)

    return [pscustomobject]@{
        SpoolerState          = $state
        StartMode             = $start
        Crashes               = [int]$events.Crashes
        PrintErrors           = [int]$events.PrintErrors
        Printers              = $printers.ToArray()
        JobCount              = $jobs.Count
        SpoolReadable         = $spoolReadable
        SpoolFileCount        = $files.Count
        SpoolBytes            = $bytes
        WindowsManagesDefault = ([int]$legacy -ne 1)
        OtherProcessors       = $processors
        RecoveryRestarts      = (@($recovery | Where-Object { $_ -match 'RESTART' }).Count -gt 0)
        RecoveryLines         = $recovery
    }
}

function Get-AfPrinterSuggestion {
    # What the check found, each with the fix key that helps ('-' = advice only).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Check, [string] $Mode = 'Standard')

    $list = New-Object System.Collections.ArrayList
    $add = { param($Key, $Text) [void]$list.Add([pscustomobject]@{ Key = $Key; Text = $Text }) }
    if ($Check.SpoolerState -eq 'Not installed') {
        & $add '-' 'The Print Spooler service is missing. Run Repair Windows files (main menu 2) first.'
        return $list.ToArray()
    }
    if ($Check.StartMode -eq 'Disabled' -or $Check.StartMode -eq 'Manual') {
        & $add 'S' ('The Print Spooler starts as {0}, so printing can stop after a restart.' -f $Check.StartMode)
    }
    if ($Check.SpoolerState -ne 'Running' -and $Check.StartMode -ne 'Disabled') { & $add 'R' 'The Print Spooler is not running.' }
    if ($Check.Crashes -gt 0) {
        & $add 'R' ('The Print Spooler crashed {0} time(s) in the last 7 days.' -f $Check.Crashes)
        if ($Mode -eq 'Technician' -and -not $Check.RecoveryRestarts) { & $add 'V' 'Windows does not restart the spooler after a crash.' }
    }
    if (@($Check.OtherProcessors).Count) {
        & $add '-' ('Print processors from other makers: {0}. A common cause of spooler crashes; update that printer''s software.' -f (@($Check.OtherProcessors) -join ', '))
    }
    foreach ($p in $Check.Printers) {
        if ($p.Offline) { & $add 'O' ('{0} is set to Use printer offline.' -f $p.Name) }
        if ($p.ErrorJobs -gt 0 -or ($p.Jobs -gt 0 -and $p.OldestMinutes -ge 30)) {
            & $add 'J' ('{0} has {1} job(s) waiting, the oldest {2} min.' -f $p.Name, $p.Jobs, [int]$p.OldestMinutes)
        }
    }
    if ($Check.SpoolFileCount -gt 0 -and $Check.JobCount -eq 0) {
        & $add 'C' ('{0} leftover file(s) in the spool folder with no job to match.' -f $Check.SpoolFileCount)
    }
    if ($Check.PrintErrors -gt 0) {
        & $add '-' ('PrintService logged {0} error(s) in 7 days (Event Viewer: Microsoft > Windows > PrintService > Admin).' -f $Check.PrintErrors)
    }
    if (-not @($Check.Printers).Count) { & $add '-' 'No printers are installed.' }
    if (-not $list.Count) { & $add '-' 'No printer problems found.' }
    return $list.ToArray()
}

function Show-AfPrinterCheck {
    # Prints the check on screen. -Show redacts names (or not, with Show sensitive on).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Check, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Suggestions, [scriptblock] $Show = { param($Text) $Text })

    $yesNo = @{ $true = 'Yes'; $false = 'No' }
    $color = 'Green'
    if ($Check.SpoolerState -ne 'Running') { $color = 'Yellow' }
    Write-Host ''
    Write-Host ('  Print Spooler       : {0} (starts {1})' -f $Check.SpoolerState, $Check.StartMode) -ForegroundColor $color
    Write-Host ('  Restarts on a crash : {0}' -f $yesNo[[bool]$Check.RecoveryRestarts])
    Write-Host ('  Last 7 days         : {0} spooler crash(es), {1} PrintService error(s)' -f $Check.Crashes, $Check.PrintErrors)
    if ($Check.SpoolReadable -eq $false) { Write-Host '  Spool folder        : could not check (needs administrator)' -ForegroundColor Yellow }
    else { Write-Host ('  Spool folder        : {0} file(s), {1}' -f $Check.SpoolFileCount, (Format-AfSize $Check.SpoolBytes)) }
    Write-Host ('  Windows picks the default printer: {0}' -f $yesNo[[bool]$Check.WindowsManagesDefault])
    Write-Host ''
    Write-Host ('  {0,-2}{1,-32} {2,-14} {3,-8} {4,5} {5,7}' -f '', 'Printer', 'Status', 'Port', 'Jobs', 'Oldest') -ForegroundColor White
    foreach ($p in $Check.Printers) {
        $mark = ''
        if ($p.Default) { $mark = '*' }
        $name = & $Show $p.Name
        if ($name.Length -gt 32) { $name = $name.Substring(0, 29) + '...' }
        $old = ''
        if ($null -ne $p.OldestMinutes) { $old = '{0} min' -f $p.OldestMinutes }
        $line = '  {0,-2}{1,-32} {2,-14} {3,-8} {4,5} {5,7}' -f $mark, $name, $p.Status, $p.PortKind, $p.Jobs, $old
        if ($p.Offline -or $p.ErrorJobs -gt 0) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
    }
    if (@($Check.Printers).Count) { Write-Host '  * = default printer' -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  What we suggest:' -ForegroundColor White
    foreach ($s in $Suggestions) {
        $text = & $Show $s.Text
        if ($s.Key -eq '-') { Write-Host ('    -  {0}' -f $text) -ForegroundColor DarkGray }
        else { Write-Host ('    {0}  {1}' -f $s.Key, $text) -ForegroundColor Cyan }
    }
}

function Write-AfPrinterLog {
    # One line in the printer log, when there is one.
    [CmdletBinding()]
    param($Log, [AllowEmptyString()] [string] $Text)
    if ($Log) { Write-AfToolLog $Log $Text }
}

function Get-AfCimPrinter {
    # The live Win32_Printer object for a name (no WQL quoting needed this way).
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)

    $found = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if (-not $found.Count) { throw ('Printer not found: {0}' -f $Name) }
    return $found[0]
}

function Remove-AfPrinterJob {
    # Cancels the waiting jobs of one printer. Returns how many were found and how many stayed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PrinterName,
        [scriptblock] $GetJobs = { @(Get-CimInstance -ClassName Win32_PrintJob -Property Name -ErrorAction Stop) },
        [scriptblock] $RemoveJob = { param($Job) Remove-CimInstance -InputObject $Job -ErrorAction Stop }
    )

    $mine = @(& $GetJobs | Where-Object { (Get-AfJobPrinterName ([string]$_.Name)) -eq $PrinterName })
    $left = 0
    foreach ($job in $mine) {
        try { & $RemoveJob $job }
        catch { $left++; Write-Verbose ('Job not removed: {0}' -f $_.Exception.Message) }
    }
    return [pscustomobject]@{ Found = $mine.Count; Left = $left }
}

function Get-AfPrinterOps {
    # Everything a fix does to the PC, in one place. Tests pass their own.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        IsAdmin        = { Test-AfIsAdmin }
        Sc             = { param([string[]] $Arguments) Invoke-AfTool -Name 'sc.exe' -ArgumentList $Arguments }
        GetState       = { [string](Get-Service -Name Spooler -ErrorAction Stop).Status }
        Sleep          = { Start-Sleep -Seconds 1 }
        ListSpoolFiles = { @(Get-ChildItem -LiteralPath $script:AfSpoolDir -File -Force -ErrorAction SilentlyContinue) }
        RemoveFile     = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        RemoveJobs     = { param($Name) Remove-AfPrinterJob -PrinterName $Name }
        SetOffline     = { param($Name, $Value) Set-CimInstance -InputObject (Get-AfCimPrinter -Name $Name) -Property @{ WorkOffline = [bool]$Value } -ErrorAction Stop }
        SetDefault     = { param($Name) [int](Invoke-CimMethod -InputObject (Get-AfCimPrinter -Name $Name) -MethodName SetDefaultPrinter -ErrorAction Stop).ReturnValue }
        TestPage       = { param($Name) [int](Invoke-CimMethod -InputObject (Get-AfCimPrinter -Name $Name) -MethodName PrintTestPage -ErrorAction Stop).ReturnValue }
        GetLegacy      = { (Get-ItemProperty -LiteralPath $script:AfPrintKey -Name LegacyDefaultPrinterMode -ErrorAction SilentlyContinue).LegacyDefaultPrinterMode }
        SetLegacy      = { param($Value) Set-ItemProperty -LiteralPath $script:AfPrintKey -Name LegacyDefaultPrinterMode -Value ([int]$Value) -Type DWord -ErrorAction Stop }
        RemovePrinter  = { param($Name) Remove-CimInstance -InputObject (Get-AfCimPrinter -Name $Name) -ErrorAction Stop }
        GetDrivers     = { @(Get-CimInstance -ClassName Win32_PrinterDriver -Property Name, InfName -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = ([string]$_.Name).Split(',')[0]; Inf = [string]$_.InfName } } | Sort-Object -Property Name -Unique) }
        RemoveDriver   = { param($Name) Remove-PrinterDriver -Name $Name -ErrorAction Stop }
        RestorePoint   = { New-AfRestorePoint -Description 'Auto-Fixer: before removing a printer driver' }
    }
}

function Wait-AfSpoolerState {
    # Waits up to -Seconds for Stopped or Running, moving the progress bar once a second.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Want,
        [Parameter(Mandatory)] [hashtable] $Ops,
        [AllowNull()] [hashtable] $View,
        [string] $Text = '',
        [double] $From = 0,
        [int] $Seconds = 30
    )

    for ($i = 0; $i -le $Seconds; $i++) {
        if ((& $Ops.GetState) -eq $Want) { return $true }
        if ($i -eq $Seconds) { break }
        Update-AfProgressView -View $View -Lines @(('{0} ({1} s)' -f $Text, $i)) -Percent ($From + 40.0 * $i / $Seconds)
        & $Ops.Sleep
    }
    return $false
}

function Invoke-AfSpoolerCycle {
    <#
    .SYNOPSIS
        Stops the Print Spooler, runs -WhileStopped (if any), and starts it again,
        with a progress bar. Returns Tag (OK or FAILED), ExitCode, Detail and the
        result of -WhileStopped. A spooler that will not stop is reported, never killed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Ops,
        [scriptblock] $WhileStopped,
        [string] $Title = 'Restarting the Print Spooler',
        [string] $Mode,
        $Log
    )

    $result = { param($Tag, $Code, $Detail, $Extra) [pscustomobject]@{ Tag = $Tag; ExitCode = $Code; Detail = $Detail; WhileStopped = $Extra } }
    $view = Open-AfProgressView -Title $Title -Mode $Mode
    try {
        Update-AfProgressView -View $view -Lines @('Stopping the Print Spooler') -Percent 2
        $stop = & $Ops.Sc ('stop', 'Spooler')
        Write-AfPrinterLog $Log ('sc stop Spooler  : exit {0}' -f (Get-AfSpoolerExitText -Code $stop.ExitCode))
        if ($stop.ExitCode -ne 0 -and $stop.ExitCode -ne 1062) {
            return (& $result 'FAILED' $stop.ExitCode ('Could not stop the Print Spooler: exit {0}.' -f (Get-AfSpoolerExitText -Code $stop.ExitCode)) $null)
        }
        if (-not (Wait-AfSpoolerState -Want 'Stopped' -Ops $Ops -View $view -Text 'Waiting for the Print Spooler to stop' -From 5)) {
            return (& $result 'FAILED' 1053 'The Print Spooler did not stop within 30 seconds. Nothing was deleted. Restart the PC, then try again.' $null)
        }
        $extra = $null
        if ($WhileStopped) {
            Update-AfProgressView -View $view -Lines @('Working while the Print Spooler is stopped') -Percent 48
            $extra = & $WhileStopped
        }
        Update-AfProgressView -View $view -Lines @('Starting the Print Spooler') -Percent 55
        $start = & $Ops.Sc ('start', 'Spooler')
        Write-AfPrinterLog $Log ('sc start Spooler : exit {0}' -f (Get-AfSpoolerExitText -Code $start.ExitCode))
        if ($start.ExitCode -ne 0 -and $start.ExitCode -ne 1056) {
            return (& $result 'FAILED' $start.ExitCode ('Could not start the Print Spooler: exit {0}.' -f (Get-AfSpoolerExitText -Code $start.ExitCode)) $extra)
        }
        if (-not (Wait-AfSpoolerState -Want 'Running' -Ops $Ops -View $view -Text 'Waiting for the Print Spooler to start' -From 58)) {
            return (& $result 'FAILED' 1053 'The Print Spooler did not start within 30 seconds.' $extra)
        }
        Update-AfProgressView -View $view -Lines @('The Print Spooler is running') -Percent 100
        return (& $result 'OK' 0 'The Print Spooler is running again.' $extra)
    }
    finally { Close-AfProgressView -View $view }
}

function Select-AfPrinter {
    # A list of printers to pick one from. Returns the printer, $null for Back, or 'QUIT'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Printers,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [scriptblock] $Show = { param($Text) $Text },
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    $items = New-Object System.Collections.ArrayList
    $itemInfo = @{ B = @('Back to Printers. Nothing is changed.'); Q = @('Closes Auto-Fixer. Asks first.') }
    for ($i = 0; $i -lt $Printers.Count; $i++) {
        $p = $Printers[$i]
        $label = & $Show $p.Name
        # The menu box ends at column 51.
        if ($label.Length -gt 38) { $label = $label.Substring(0, 35) + '...' }
        $key = 'P{0}' -f $i
        [void]$items.Add(@{ Key = $key; Label = $label })
        $itemInfo[$key] = @(('Status: {0}' -f $p.Status), ('Port: {0}' -f $p.PortKind), ('Jobs waiting: {0}' -f $p.Jobs))
    }
    [void]$items.Add(@{ Key = 'B'; Label = '&Back' })
    [void]$items.Add(@{ Key = 'Q'; Label = '&Quit' })
    $choice = Select-AfMenuItem -Title $Title -Items $items.ToArray() -Header { Show-AfBanner -Mode $Settings.Mode } -ItemInfo $itemInfo `
        -Mode $Settings.Mode -EscapeKey 'B' -ReadKey $ReadKey
    if ($choice -eq 'B') { return $null }
    if ($choice -eq 'Q') {
        if (Confirm-AfQuit -ReadKey $ReadKey) { return 'QUIT' }
        return $null
    }
    return $Printers[[int]$choice.Substring(1)]
}

function Invoke-AfPrinterFix {
    <#
    .SYNOPSIS
        Runs one printer fix by its menu key, after saying what it does and asking Y/N.
        Returns Tag (OK, FAILED, CANCELLED, QUIT) and Detail. Every change and its
        exit code goes in the log.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ReadKey', Justification = 'Used by the ask and pick script blocks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ScreenRedactor', Justification = 'Used by the show script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] $Check,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        $Log,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [hashtable] $Ops = (Get-AfPrinterOps),
        $ScreenRedactor = (New-AfRedactor -Disabled)
    )

    $show = { param($Text) Protect-AfText -Redactor $ScreenRedactor -Text ([string]$Text) }
    $done = { param($Tag, $Detail) [pscustomobject]@{ Tag = $Tag; Detail = $Detail } }
    $ask = { param($Prompt) (Read-AfYesNo -Prompt $Prompt -ReadKey $ReadKey) -eq $true }
    $say = { param($Text, $Color) if (-not $Color) { $Color = 'Gray' }; Write-Host ('  {0}' -f $Text) -ForegroundColor $Color }
    $no = { & $say 'Nothing was changed.' 'Yellow'; & $done 'CANCELLED' 'Nothing was changed.' }
    $pick = { param($List, $Title) Select-AfPrinter -Printers @($List) -Title $Title -Settings $Settings -Show $show -ReadKey $ReadKey }

    if (@('V', 'M', 'U') -contains $Key -and $Settings.Mode -ne 'Technician') { return (& $done 'CANCELLED' 'Technician mode only.') }
    if (@('R', 'C', 'J', 'S', 'V', 'M', 'U') -contains $Key -and -not (& $Ops.IsAdmin)) {
        & $say 'This fix needs administrator rights.' 'Yellow'
        & $say 'Start Auto-Fixer with AutoFix.bat and answer Yes to the Windows prompt.' 'Yellow'
        return (& $done 'CANCELLED' 'Needs administrator rights.')
    }

    Write-Host ''
    switch ($Key) {
        'R' {
            & $say 'Restart the Print Spooler: stops it and starts it again. Waiting jobs stay in the queue.' 'White'
            if (-not (& $ask 'Restart the Print Spooler now?')) { return (& $no) }
            $r = Invoke-AfSpoolerCycle -Ops $Ops -Mode $Settings.Mode -Log $Log
            return (& $done $r.Tag $r.Detail)
        }
        'C' {
            & $say ('Clear all print jobs: {0} job(s) in the queue, {1} file(s) in the spool folder.' -f $Check.JobCount, $Check.SpoolFileCount) 'White'
            & $say 'It stops the Print Spooler, deletes the waiting job files and starts it again.'
            & $say 'Every waiting job on every printer is lost. Print them again afterwards.' 'Yellow'
            if (-not (& $ask 'Clear all print jobs?')) { return (& $no) }
            if (-not (& $ask 'Are you sure? Waiting jobs cannot be brought back.')) { return (& $no) }
            $clear = {
                $files = @(& $Ops.ListSpoolFiles)
                $left = 0
                foreach ($f in $files) {
                    try { & $Ops.RemoveFile $f.FullName }
                    catch { $left++; Write-Verbose ('Not deleted: {0}' -f $_.Exception.Message) }
                }
                [pscustomobject]@{ Found = $files.Count; Left = $left }
            }
            $r = Invoke-AfSpoolerCycle -Ops $Ops -WhileStopped $clear -Title 'Clearing stuck print jobs' -Mode $Settings.Mode -Log $Log
            if ($r.WhileStopped) {
                Write-AfPrinterLog $Log ('Spool files      : {0} found, {1} deleted, {2} could not be deleted' -f $r.WhileStopped.Found, ($r.WhileStopped.Found - $r.WhileStopped.Left), $r.WhileStopped.Left)
                & $say ('Deleted {0} of {1} job file(s).' -f ($r.WhileStopped.Found - $r.WhileStopped.Left), $r.WhileStopped.Found)
                if ($r.Tag -eq 'OK' -and $r.WhileStopped.Left -gt 0) { return (& $done 'FAILED' ('{0} job file(s) could not be deleted.' -f $r.WhileStopped.Left)) }
            }
            return (& $done $r.Tag $r.Detail)
        }
        'J' {
            $list = @($Check.Printers | Where-Object { $_.Jobs -gt 0 })
            if (-not $list.Count) { & $say 'No printer has jobs waiting.' 'Yellow'; return (& $done 'CANCELLED' 'No jobs waiting.') }
            $p = & $pick $list 'Cancel the jobs of which printer?'
            if ($p -eq 'QUIT') { return (& $done 'QUIT' '') }
            if (-not $p) { return (& $no) }
            & $say ('Cancels the {0} waiting job(s) on {1}. Other printers keep theirs.' -f $p.Jobs, (& $show $p.Name)) 'White'
            if (-not (& $ask 'Cancel these jobs?')) { return (& $no) }
            $r = & $Ops.RemoveJobs $p.Name
            Write-AfPrinterLog $Log ('Cancel jobs      : {0}: {1} found, {2} left' -f $p.Name, $r.Found, $r.Left)
            if ($r.Left -gt 0) { return (& $done 'FAILED' ('{0} of {1} job(s) could not be cancelled.' -f $r.Left, $r.Found)) }
            return (& $done 'OK' ('Cancelled {0} job(s).' -f $r.Found))
        }
        'O' {
            $list = @($Check.Printers | Where-Object { $_.Offline })
            if (-not $list.Count) { & $say 'No printer is set to Use printer offline. A printer shown Offline may be switched off or unplugged.' 'Yellow'; return (& $done 'CANCELLED' 'None set offline.') }
            $p = & $pick $list 'Turn which printer back online?'
            if ($p -eq 'QUIT') { return (& $done 'QUIT' '') }
            if (-not $p) { return (& $no) }
            & $say ('Turns off Use printer offline for {0}.' -f (& $show $p.Name)) 'White'
            if (-not (& $ask 'Turn it back online?')) { return (& $no) }
            & $Ops.SetOffline $p.Name $false
            Write-AfPrinterLog $Log ('Online again     : {0} (Use printer offline was on)' -f $p.Name)
            return (& $done 'OK' 'Use printer offline is off.')
        }
        'D' {
            if (-not @($Check.Printers).Count) { & $say 'No printers are installed.' 'Yellow'; return (& $done 'CANCELLED' 'No printers.') }
            $p = & $pick $Check.Printers 'Make which printer the default?'
            if ($p -eq 'QUIT') { return (& $done 'QUIT' '') }
            if (-not $p) { return (& $no) }
            & $say ('Makes {0} the default printer for this Windows account.' -f (& $show $p.Name)) 'White'
            if (-not (& $ask 'Set the default printer?')) { return (& $no) }
            $code = & $Ops.SetDefault $p.Name
            Write-AfPrinterLog $Log ('Default printer  : {0}, return code {1}' -f $p.Name, $code)
            if ($code -ne 0) { return (& $done 'FAILED' ('Windows returned code {0}.' -f $code)) }
            if ($Check.WindowsManagesDefault) {
                & $say 'Let Windows manage my default printer is on, so Windows may change it back.' 'Yellow'
                if (& $ask 'Turn that setting off?') {
                    $old = & $Ops.GetLegacy
                    & $Ops.SetLegacy 1
                    Write-AfPrinterLog $Log ('LegacyDefaultPrinterMode: was {0}, now 1 (Windows no longer picks the default)' -f $(if ($null -eq $old) { 'not set' } else { $old }))
                }
            }
            return (& $done 'OK' 'Default printer set.')
        }
        'T' {
            if (-not @($Check.Printers).Count) { & $say 'No printers are installed.' 'Yellow'; return (& $done 'CANCELLED' 'No printers.') }
            $p = & $pick $Check.Printers 'Print a test page on which printer?'
            if ($p -eq 'QUIT') { return (& $done 'QUIT' '') }
            if (-not $p) { return (& $no) }
            & $say ('Sends Windows'' own test page to {0}. It uses one sheet of paper.' -f (& $show $p.Name)) 'White'
            if (-not (& $ask 'Print the test page?')) { return (& $no) }
            $code = & $Ops.TestPage $p.Name
            Write-AfPrinterLog $Log ('Test page        : {0}, return code {1}' -f $p.Name, $code)
            if ($code -ne 0) { return (& $done 'FAILED' ('Windows returned code {0}.' -f $code)) }
            return (& $done 'OK' 'Test page sent. Check the printer.')
        }
        'S' {
            if ($Check.StartMode -eq 'Auto') { & $say 'The Print Spooler already starts Automatic.' 'Green'; return (& $done 'CANCELLED' 'Already Automatic.') }
            & $say ('Sets the Print Spooler to start Automatic (now: {0}).' -f $Check.StartMode) 'White'
            if (-not (& $ask 'Change the start type?')) { return (& $no) }
            $r = & $Ops.Sc ('config', 'Spooler', 'start=', 'auto')
            Write-AfPrinterLog $Log ('sc config start=auto: was {0}, exit {1}' -f $Check.StartMode, (Get-AfSpoolerExitText -Code $r.ExitCode))
            if ($r.ExitCode -ne 0) { return (& $done 'FAILED' ('exit {0}' -f (Get-AfSpoolerExitText -Code $r.ExitCode))) }
            return (& $done 'OK' ('Start type is Automatic (was {0}). R starts it now.' -f $Check.StartMode))
        }
        'V' {
            & $say 'Spooler recovery: Windows restarts the Print Spooler 60 seconds after a crash (first and second time).' 'White'
            foreach ($line in @($Check.RecoveryLines | Where-Object { $_ -match '\S' })) { Write-AfPrinterLog $Log ('Recovery before  : {0}' -f $line.Trim()) }
            if (-not (& $ask 'Set the recovery options?')) { return (& $no) }
            $r = & $Ops.Sc ('failure', 'Spooler', 'reset=', '86400', 'actions=', 'restart/60000/restart/60000//')
            Write-AfPrinterLog $Log ('sc failure Spooler: exit {0}' -f (Get-AfSpoolerExitText -Code $r.ExitCode))
            if ($r.ExitCode -ne 0) { return (& $done 'FAILED' ('exit {0}' -f (Get-AfSpoolerExitText -Code $r.ExitCode))) }
            # Read the setting back so the log proves what Windows now has.
            $after = & $Ops.Sc ('qfailure', 'Spooler')
            foreach ($line in @($after.Lines | Where-Object { $_ -match '\S' })) { Write-AfPrinterLog $Log ('Recovery after   : {0}' -f $line.Trim()) }
            return (& $done 'OK' 'The Print Spooler restarts by itself after a crash. The old and new settings are in the log.')
        }
        'M' {
            if (-not @($Check.Printers).Count) { & $say 'No printers are installed.' 'Yellow'; return (& $done 'CANCELLED' 'No printers.') }
            $p = & $pick $Check.Printers 'Remove which printer?'
            if ($p -eq 'QUIT') { return (& $done 'QUIT' '') }
            if (-not $p) { return (& $no) }
            & $say ('Removes {0} from this PC. Its driver stays; add the printer again in Settings > Printers.' -f (& $show $p.Name)) 'White'
            if ($p.Jobs -gt 0) { & $say ('Its {0} waiting job(s) are lost.' -f $p.Jobs) 'Yellow' }
            if (-not (& $ask 'Remove this printer?')) { return (& $no) }
            & $Ops.RemovePrinter $p.Name
            Write-AfPrinterLog $Log ('Removed printer  : {0} (driver {1} kept)' -f $p.Name, $p.Driver)
            return (& $done 'OK' 'Printer removed.')
        }
        'U' {
            $used = @($Check.Printers | ForEach-Object { $_.Driver })
            # A driver may come as a name or as Name + Inf; built-in ones (by name or by Windows INF) are never offered.
            $drivers = @(@(& $Ops.GetDrivers) | ForEach-Object {
                    $name = if ($_ -is [string]) { $_ } else { [string]$_.Name }
                    $inf = if ($_ -is [string]) { '' } else { [string]$_.Inf }
                    $infLeaf = if ($inf) { Split-Path -Path $inf -Leaf } else { '' }
                    if ($name -and $used -notcontains $name -and $name -notmatch $script:AfBuiltInDriverPattern -and $infLeaf -notmatch $script:AfInboxInfPattern) { $name }
                })
            if (-not $drivers.Count) { & $say 'No unused printer drivers. Drivers in use and the ones built into Windows are never offered.' 'Yellow'; return (& $done 'CANCELLED' 'No unused drivers.') }
            $rows = @($drivers | ForEach-Object { [pscustomobject]@{ Name = $_; Status = 'Not in use'; PortKind = '-'; Jobs = 0 } })
            $d = & $pick $rows 'Remove which unused driver?'
            if ($d -eq 'QUIT') { return (& $done 'QUIT' '') }
            if (-not $d) { return (& $no) }
            & $say ('Removes the printer driver {0}. No printer uses it.' -f $d.Name) 'White'
            if (& $ask 'Make a restore point first?') {
                $rp = & $Ops.RestorePoint
                if ($rp.Ok) { & $say 'Restore point made.' 'Green'; Write-AfPrinterLog $Log 'Restore point    : made' }
                else { & $say ('No restore point: {0}' -f $rp.Reason) 'Yellow'; Write-AfPrinterLog $Log ('Restore point    : not made ({0})' -f $rp.Reason) }
            }
            if (-not (& $ask 'Remove this driver?')) { return (& $no) }
            & $Ops.RemoveDriver $d.Name
            Write-AfPrinterLog $Log ('Removed driver   : {0}' -f $d.Name)
            return (& $done 'OK' 'Driver removed.')
        }
    }
    return (& $done 'CANCELLED' ('Unknown fix {0}.' -f $Key))
}

function Invoke-AfPrinterMenu {
    <#
    .SYNOPSIS
        Printers, from the main menu: the read-only check first, then the fixes.
        After each fix the check runs again and the new state is shown.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'GetCheck', Justification = 'Used by the runCheck script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        # Called with -OnStep; returns a check like Get-AfPrinterCheck.
        [scriptblock] $GetCheck = { param($OnStep) Get-AfPrinterCheck -OnStep $OnStep },
        # Called with -Key -Check -Log -ScreenRedactor; the default asks first and runs the fix.
        [scriptblock] $RunFix,
        # Called between screens; tests pass { }.
        [scriptblock] $ClearScreen = { Clear-AfScreen; Show-AfBanner -Mode $Settings.Mode }
    )

    if (-not $RunFix) {
        $RunFix = { param($Key, $Check, $Log, $ScreenRedactor) Invoke-AfPrinterFix -Key $Key -Check $Check -Settings $Settings -Log $Log -ReadKey $ReadKey -ScreenRedactor $ScreenRedactor }
    }
    $technician = $Settings.Mode -eq 'Technician'
    $redactor = New-AfRedactor
    $screenRedactor = $redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $show = { param($Text) Protect-AfText -Redactor $screenRedactor -Text ([string]$Text) }
    $runCheck = {
        $view = Open-AfProgressView -Title 'Printer check (read-only)' -Mode $Settings.Mode
        $onStep = { param($Number, $Count, $Text) Update-AfProgressView -View $view -Lines @(('Step {0} of {1}: {2}' -f $Number, $Count, $Text)) -Percent (100.0 * ($Number - 1) / $Count) }
        try { $c = & $GetCheck -OnStep $onStep }
        finally { Close-AfProgressView -View $view }
        # Printer names can hold a server, office or person's name.
        Add-AfRedactionName -Redactor $redactor -Names @($c.Printers | ForEach-Object { $_.Name })
        $c
    }

    & $ClearScreen
    $check = & $runCheck
    $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'printer' -Redactor $redactor -Task 'Printers'
    $suggestions = @(Get-AfPrinterSuggestion -Check $check -Mode $Settings.Mode)
    Write-AfPrinterLog $log ('Spooler          : {0}, starts {1}, restarts on crash {2}' -f $check.SpoolerState, $check.StartMode, $check.RecoveryRestarts)
    Write-AfPrinterLog $log ('Last 7 days      : {0} crash(es), {1} PrintService error(s)' -f $check.Crashes, $check.PrintErrors)
    if ($check.SpoolReadable -eq $false) { Write-AfPrinterLog $log ('Spool folder     : could not check (needs administrator); jobs in queue {0}' -f $check.JobCount) }
    else { Write-AfPrinterLog $log ('Spool folder     : {0} file(s), {1} byte(s); jobs in queue {2}' -f $check.SpoolFileCount, $check.SpoolBytes, $check.JobCount) }
    foreach ($p in $check.Printers) {
        Write-AfPrinterLog $log ('Printer          : {0} | {1} | {2} | jobs {3} | default {4}' -f $p.Name, $p.Status, $p.PortKind, $p.Jobs, $p.Default)
    }
    foreach ($s in $suggestions) { Write-AfPrinterLog $log ('Suggest {0}        : {1}' -f $s.Key, $s.Text) }
    Show-AfPrinterCheck -Check $check -Suggestions $suggestions -Show $show
    Write-Host ''
    Write-Host '  Press any key to see the fixes.' -ForegroundColor DarkGray
    Clear-AfKeyBuffer
    $null = & $ReadKey

    $itemInfo = @{
        R = @('Stops and starts the Print Spooler. Waiting jobs stay.', '', 'Changes system: YES', 'Asks Y/N first.')
        C = @('Stops the spooler, deletes every waiting job file, starts it again.', '', 'Changes system: YES', 'Deletes waiting jobs', 'Asks twice.')
        J = @('Cancels the waiting jobs of one printer you pick. Others keep theirs.', '', 'Changes system: YES', 'Asks Y/N first.')
        O = @('Turns off Use printer offline for a printer you pick.', '', 'Changes system: YES', 'Asks Y/N first.')
        D = @('Sets the default printer, and can stop Windows from changing it.', '', 'Changes system: YES', 'Asks Y/N first.')
        T = @('Prints Windows'' own test page. Uses one sheet of paper.', '', 'Changes system: NO', 'Asks Y/N first.')
        S = @('Sets the Print Spooler to start Automatic, when it is Manual or Disabled.', '', 'Changes system: YES', 'Asks Y/N first.')
        V = @('Windows restarts the Print Spooler by itself after a crash.', '', 'Changes system: YES', 'Old setting logged.')
        M = @('Removes one printer. Its driver stays.', '', 'Changes system: YES', 'Asks Y/N first.')
        U = @('Removes a printer driver no printer uses. Built-in drivers are never offered.', '', 'Changes system: YES', 'Restore point offered.')
        B = @('Back to the main menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    while ($true) {
        $items = New-Object System.Collections.ArrayList
        [void]$items.Add(@{ Key = 'R'; Label = '&Restart spooler'; Tags = '[ADMIN] [CHG]' })
        [void]$items.Add(@{ Key = 'C'; Label = '&Clear all print jobs'; Tags = '[ADMIN] [CHG]' })
        [void]$items.Add(@{ Key = 'J'; Label = '&Jobs: one printer'; Tags = '[ADMIN] [CHG]' })
        [void]$items.Add(@{ Key = 'O'; Label = 'Printer &online again'; Tags = '[CHG]' })
        [void]$items.Add(@{ Key = 'D'; Label = '&Default printer'; Tags = '[CHG]' })
        [void]$items.Add(@{ Key = 'T'; Label = 'Print a &test page' })
        [void]$items.Add(@{ Key = 'S'; Label = 'Spooler &start type'; Tags = '[ADMIN] [CHG]'; Divider = -not $technician })
        if ($technician) {
            [void]$items.Add(@{ Key = 'V'; Label = 'Spooler reco&very'; Tags = '[ADMIN] [CHG]' })
            [void]$items.Add(@{ Key = 'M'; Label = 'Re&move a printer'; Tags = '[ADMIN] [CHG]' })
            [void]$items.Add(@{ Key = 'U'; Label = 'Remove &unused driver'; Tags = '[ADMIN] [CHG]'; Divider = $true })
        }
        [void]$items.Add(@{ Key = 'B'; Label = '&Back' })
        [void]$items.Add(@{ Key = 'Q'; Label = '&Quit' })
        $first = @($suggestions | Where-Object { $_.Key -ne '-' } | Select-Object -First 1)
        $notice = 'No printer problems found.'
        if ($first.Count) { $notice = 'Suggested: {0} - {1}' -f $first[0].Key, (& $show $first[0].Text) }
        if ($notice.Length -gt 76) { $notice = $notice.Substring(0, 73) + '...' }

        $choice = Select-AfMenuItem -Title 'Printers' -Items $items.ToArray() -Header { Show-AfBanner -Mode $Settings.Mode } -ItemInfo $itemInfo `
            -Mode $Settings.Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        & $ClearScreen
        $r = $null
        try { $r = & $RunFix -Key $choice -Check $check -Log $log -ScreenRedactor $screenRedactor }
        catch {
            $r = [pscustomobject]@{ Tag = 'FAILED'; Detail = $_.Exception.Message }
        }
        if ($r -and $r.Tag -eq 'QUIT') { $script:AfQuitRequested = $true; return }
        if ($r -and $r.Tag -ne 'CANCELLED') {
            $color = @{ OK = 'Green'; FAILED = 'Red' }[[string]$r.Tag]
            if (-not $color) { $color = 'Yellow' }
            Write-AfPrinterLog $log ('{0,-7}{1}: {2}' -f $r.Tag, $choice, $r.Detail)
            Write-Host ''
            Write-Host ('  {0,-8}{1}' -f $r.Tag, (& $show $r.Detail)) -ForegroundColor $color
            # The same check again, so the screen shows what changed.
            $check = & $runCheck
            $suggestions = @(Get-AfPrinterSuggestion -Check $check -Mode $Settings.Mode)
            $spool = '{0} spool file(s)' -f $check.SpoolFileCount
            if ($check.SpoolReadable -eq $false) { $spool = 'spool folder not checked (needs administrator)' }
            $now = 'Now: Print Spooler {0}, {1} job(s) waiting, {2}.' -f $check.SpoolerState, $check.JobCount, $spool
            Write-AfPrinterLog $log $now
            Write-Host ('  {0}' -f $now)
        }
        Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $log.Path)) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Press any key to return to Printers.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
