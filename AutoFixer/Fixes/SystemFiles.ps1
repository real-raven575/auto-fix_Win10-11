# SFC and DISM repairs, ported from raven575's SFC + DISM Repair Tool v1.1
# (reference/sfc-dism-v1.1). Changes from v1.1, measured against the project rules:
#   - logs stay on this PC, under the run folder, and go through the redactor
#   - no computer or user name in logs, log file names or the history file
#   - RestoreHealth uses Windows Update only with the Online switch on, and says so first
#   - a restore point is offered before the first step that changes the PC
#   - the stall watchdog asks before it stops a step; it never stops one on its own
#   - taskkill.exe and shutdown.exe are called by their full path
#   - a step that changes the PC never starts from one stray key

$script:AfRepairSteps = [ordered]@{
    CHECK   = @{ Letter = 'K'; Name = 'DISM CheckHealth'; Menu = 'DISM Chec&kHealth'; Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /CheckHealth'; DefaultMin = 1; Changes = $false
        What = 'Reads whether Windows has already marked its component store as damaged.' }
    SCAN    = @{ Letter = 'N'; Name = 'DISM ScanHealth'; Menu = 'DISM Sca&nHealth'; Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /ScanHealth'; DefaultMin = 10; Changes = $false
        What = 'Checks the whole component store for damage. Reads only.' }
    SFC     = @{ Letter = 'S'; Name = 'SFC scan'; Menu = '&SFC scan'; Exe = 'sfc.exe'; Args = '/scannow'; DefaultMin = 15; Changes = $true
        What = 'Checks every protected Windows file and replaces damaged ones with clean copies.' }
    RESTORE = @{ Letter = 'R'; Name = 'DISM RestoreHealth'; Menu = 'DISM &RestoreHealth'; Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /RestoreHealth'; DefaultMin = 20; Changes = $true
        What = 'Repairs the component store that SFC copies its clean files from.' }
    CLEANUP = @{ Letter = 'C'; Name = 'DISM ComponentCleanup'; Menu = 'DISM Component&Cleanup'; Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /StartComponentCleanup'; DefaultMin = 15; Changes = $true
        What = 'Removes older, replaced versions of Windows components to free space. They cannot be brought back.' }
}
$script:AfRunAll = @('SFC', 'CHECK', 'SCAN', 'RESTORE', 'CLEANUP', 'SFC')
$script:AfStallMinutes = 10
$script:AfHistoryRunsToAverage = 5
# Shown before RestoreHealth connects. Windows Update is the only approved destination (raven575, 2026-10-24).
$script:AfWindowsUpdateNotice = 'Connecting to Windows Update (Microsoft) to download clean copies of damaged system files.'

function Get-AfSystemToolPath {
    # A 32-bit PowerShell on 64-bit Windows must use Sysnative, or SFC fails to start its service.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Name)

    $windows = $env:windir
    if (-not $windows) { $windows = 'C:\Windows' }
    $folder = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $folder = 'Sysnative' }
    return ('{0}\{1}\{2}' -f $windows.TrimEnd('\'), $folder, $Name)
}

function Get-AfRepairArgumentList {
    # Without the Online switch, RestoreHealth uses only the files already on this PC.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [bool] $Online
    )

    $arguments = $script:AfRepairSteps[$Key].Args
    if ($Key -eq 'RESTORE' -and -not $Online) { $arguments += ' /LimitAccess' }
    return $arguments
}

function Get-AfPercent {
    # SFC prints "Verification 45% complete."  DISM prints "[=====   45.0%   ]" (some locales use 45,0%).
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $found = [regex]::Matches($Text, '(\d{1,3}(?:[.,]\d+)?)\s*%')
    if ($found.Count -eq 0) { return $null }
    $value = [double]::Parse($found[$found.Count - 1].Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    if ($value -gt 100) { return $null }
    return $value
}

function Get-AfExitText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [int] $Code)

    $hex = '0x{0:X8}' -f $Code
    switch ($hex) {
        '0x00000000' { return '0 (success)' }
        '0x00000057' { return '87 (bad parameter)' }
        '0x000002E4' { return '740 (needs administrator rights)' }
        '0x00000BC2' { return '3010 (success, restart needed)' }
        '0x800F081F' { return "$hex (repair source files could not be found)" }
        '0x800F0906' { return "$hex (could not download repair source files)" }
        '0x800F0954' { return "$hex (repair source blocked, often WSUS or Group Policy)" }
    }
    return "$Code ($hex)"
}

function Format-AfSpan {
    param([double] $Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $span = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

function Format-AfApprox {
    param([double] $Seconds)
    $minutes = [math]::Max(1, [math]::Round($Seconds / 60))
    if ($minutes -lt 60) { return "~$minutes min" }
    return ('~{0} h {1} min' -f [math]::Floor($minutes / 60), ($minutes % 60))
}

function Get-AfRepairEstimate {
    # The average of the last 5 clean runs on this PC, or the default for the step.
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $HistoryPath
    )

    $default = [double]($script:AfRepairSteps[$Key].DefaultMin * 60)
    if (-not (Test-Path -LiteralPath $HistoryPath)) { return $default }
    try {
        $rows = @(Import-Csv -LiteralPath $HistoryPath | Where-Object { $_.Step -eq $Key -and [int]$_.ExitCode -eq 0 })
        if ($rows.Count -eq 0) { return $default }
        $recent = $rows | Select-Object -Last $script:AfHistoryRunsToAverage
        return [double][math]::Max(30, [math]::Round(($recent | ForEach-Object { [double]$_.Seconds } | Measure-Object -Average).Average))
    }
    catch { return $default }
}

function Add-AfRepairHistory {
    # Only the step, its time and its exit code: nothing that names the PC or the user.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HistoryPath,
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [double] $Seconds,
        [Parameter(Mandatory)] [int] $ExitCode
    )

    try {
        [pscustomobject]@{ Step = $Key; Seconds = [math]::Round($Seconds); ExitCode = $ExitCode; Date = (Get-Date).ToUniversalTime().ToString('s') + 'Z' } |
            Export-Csv -LiteralPath $HistoryPath -Append -NoTypeInformation -Encoding UTF8
    }
    catch { Write-Verbose ('Could not update the time history: {0}' -f $_.Exception.Message) }
}

function Get-AfActivitySignature {
    # Log sizes and write times plus CPU seconds of the servicing processes. If this
    # changes, Windows is still working even when SFC or DISM prints nothing.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $windows = $env:windir
    if (-not $windows) { $windows = 'C:\Windows' }
    $parts = @()
    foreach ($file in (Join-Path $windows 'Logs\CBS\CBS.log'), (Join-Path $windows 'Logs\DISM\dism.log')) {
        $item = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
        if ($item) { $parts += '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks }
    }
    $cpuMs = 0
    foreach ($process in @(Get-Process -Name 'TiWorker', 'TrustedInstaller', 'DismHost', 'sfc', 'dism' -ErrorAction SilentlyContinue)) {
        try { $cpuMs += $process.TotalProcessorTime.TotalMilliseconds } catch { Write-Verbose 'No CPU time for this process.' }
    }
    $parts += [math]::Floor($cpuMs / 1000)
    return ($parts -join '|')
}

function Stop-AfProcessTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $ProcessId)

    Start-Process -FilePath (Get-AfSystemToolPath 'taskkill.exe') -ArgumentList "/PID $ProcessId /T /F" -WindowStyle Hidden -Wait
}

function Set-AfStayAwake {
    # Keeps the PC from sleeping while a step runs (ES_CONTINUOUS + ES_SYSTEM_REQUIRED).
    [CmdletBinding()]
    param([bool] $On)

    try {
        if (-not ('AutoFixer.Power' -as [type])) {
            Add-Type -Namespace AutoFixer -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
        }
        if ($On) { [void][AutoFixer.Power]::SetThreadExecutionState([uint32]2147483649) }
        else { [void][AutoFixer.Power]::SetThreadExecutionState([uint32]2147483648) }
    }
    catch { Write-Verbose 'Could not change the sleep setting.' }
}

function Read-AfStallChoice {
    # The watchdog's question. Returns 'Stop' or 'Wait'; anything unclear keeps waiting.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int] $Minutes = $script:AfStallMinutes,
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    Write-Host ''
    Write-Host ('  No output and no Windows servicing activity for {0} minutes.' -f $Minutes) -ForegroundColor Yellow
    Write-Host '  The step may still be working. S = stop this step, W = keep waiting. ' -ForegroundColor Yellow -NoNewline
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $key = [string](& $ReadKey)
        if ($key -eq 'S') { Write-Host 'S'; return 'Stop' }
        if ($key -eq 'W') { Write-Host 'W'; return 'Wait' }
        Write-Host ''
        if ($attempt -eq 1) { Write-Host '  Command unknown. Press S or W to continue. ' -ForegroundColor Yellow -NoNewline }
    }
    Write-Host '  Command unknown again. Keeping the step running.' -ForegroundColor Yellow
    return 'Wait'
}

function Invoke-AfRepairProcess {
    <#
    .SYNOPSIS
        Runs one SFC or DISM command, reads its output as it comes, and reports
        progress. Returns Outcome (Completed or Stopped), ExitCode, Seconds and Messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Arguments,
        [double] $EstimatedSeconds = 60,
        [int] $StallSeconds = ($script:AfStallMinutes * 60),
        [int] $ProbeSeconds = 15,
        # Called as: & $OnProgress $percent $percentKnown $elapsedSeconds $secondsLeft $quietSeconds
        [scriptblock] $OnProgress = { },
        # Called with each line of output that is not a percentage.
        [scriptblock] $OnMessage = { },
        # Called with the quiet seconds once the step looks stalled; returns 'Stop' or 'Wait'.
        [scriptblock] $OnStall = { 'Wait' },
        [scriptblock] $ActivityProbe = { Get-AfActivitySignature }
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $start = Get-Date
    $lastOutput = $start
    $lastActivity = $start
    $signature = & $ActivityProbe
    $nextProbe = $start.AddSeconds($ProbeSeconds)
    $percent = $null
    $pending = ''
    $messages = New-Object System.Collections.Generic.List[string]
    $endOfOutput = $false
    $exitSeen = $null
    $outcome = 'Completed'
    $process = $null

    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stream = $process.StandardOutput.BaseStream
        $buffer = New-Object byte[] 4096
        $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)

        while ($true) {
            if (-not $endOfOutput) {
                if ($readTask.Wait(500)) {
                    $count = $readTask.Result
                    if ($count -le 0) { $endOfOutput = $true }
                    else {
                        $lastOutput = Get-Date
                        # SFC writes UTF-16 when redirected; dropping the zero bytes makes both tools readable.
                        $pending += [Text.Encoding]::Default.GetString($buffer, 0, $count).Replace("`0", '')
                        $segments = $pending -split "[\r\n]"
                        $pending = $segments[$segments.Count - 1]
                        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
                            $line = $segments[$i].Trim()
                            if (-not $line) { continue }
                            $found = Get-AfPercent $line
                            if ($null -ne $found) { $percent = $found }
                            else { $messages.Add($line); & $OnMessage $line }
                        }
                        $found = Get-AfPercent $pending
                        if ($null -ne $found) { $percent = $found }
                        if ($pending.Length -gt 2000) { $pending = $pending.Substring($pending.Length - 500) }
                        $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
                    }
                }
            }
            else { Start-Sleep -Milliseconds 300 }

            $now = Get-Date
            if ($process.HasExited) {
                if ($null -eq $exitSeen) { $exitSeen = $now }
                if ($endOfOutput -or ($now - $exitSeen).TotalSeconds -ge 5) { break }
            }

            if ($now -ge $nextProbe) {
                $newSignature = & $ActivityProbe
                if ($newSignature -ne $signature) { $signature = $newSignature; $lastActivity = $now }
                $nextProbe = $now.AddSeconds($ProbeSeconds)
            }

            # Stalled means no output AND no servicing activity. The user decides what happens.
            $quiet = [math]::Min(($now - $lastOutput).TotalSeconds, ($now - $lastActivity).TotalSeconds)
            if ($quiet -ge $StallSeconds) {
                if ((& $OnStall $quiet) -eq 'Stop') {
                    $outcome = 'Stopped'
                    Stop-AfProcessTree -ProcessId $process.Id
                    break
                }
                $lastOutput = Get-Date
                $lastActivity = $lastOutput
                $quiet = 0
            }

            $elapsed = ($now - $start).TotalSeconds
            $known = $null -ne $percent
            if ($known) {
                $stepPercent = $percent
                if ($percent -ge 5) { $left = $elapsed * (100 - $percent) / $percent } else { $left = $EstimatedSeconds - $elapsed }
            }
            else {
                $stepPercent = [math]::Min(95, 100 * $elapsed / [math]::Max(1, $EstimatedSeconds))
                $left = $EstimatedSeconds - $elapsed
            }
            & $OnProgress $stepPercent $known $elapsed ([math]::Max(0, $left)) $quiet
        }

        if ($outcome -eq 'Completed') {
            $process.WaitForExit()
            if ($errorTask.Wait(2000)) {
                foreach ($line in ($errorTask.Result.Replace("`0", '') -split "[\r\n]+")) {
                    if ($line.Trim()) { $messages.Add($line.Trim()); & $OnMessage $line.Trim() }
                }
            }
        }
    }
    finally {
        # Ctrl+C or any error: never leave the command running in the background.
        if ($process -and -not $process.HasExited) { Stop-AfProcessTree -ProcessId $process.Id }
    }

    $exitCode = $null
    if ($outcome -eq 'Completed') { $exitCode = $process.ExitCode }
    $end = Get-Date
    [pscustomobject]@{ Outcome = $outcome; ExitCode = $exitCode; Seconds = ($end - $start).TotalSeconds; Messages = $messages.ToArray() }
}

function Get-AfRestorePointSummary {
    # A second look, read-only: what System Restore lists, and the Volume Shadow Copy
    # snapshots that hold restore points, so a skipped point can be checked.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $points = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue)
    $text = 'System Restore lists {0} restore point(s)' -f $points.Count
    $times = @(foreach ($p in $points) {
            try { [datetime]::ParseExact(([string]$p.CreationTime).Substring(0, 14), 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture) }
            catch { Write-Verbose 'Unreadable restore point time.' }
        })
    if ($times.Count -gt 0) { $text += ', newest {0} UTC' -f ($times | Sort-Object | Select-Object -Last 1).ToString('yyyy-MM-dd HH:mm') }
    $shadows = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue)
    return ('{0}; Windows holds {1} shadow copy snapshot(s).' -f $text, $shadows.Count)
}

function New-AfRestorePoint {
    <#
    .SYNOPSIS
        Asks Windows for a restore point. Returns Ok and, when it fails, the reason.
        It never turns System Protection on.
    #>
    [CmdletBinding()]
    param([string] $Description = 'auto-fix_Win: before SFC and DISM repairs')

    try {
        $newest = { @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue | ForEach-Object { [int64]$_.SequenceNumber }) | Sort-Object | Select-Object -Last 1 }
        $before = & $newest
        $arguments = @{ Description = $Description; RestorePointType = [uint32]12; EventType = [uint32]100 }
        $result = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments $arguments -ErrorAction Stop
        if ($result.ReturnValue -ne 0) {
            return [pscustomobject]@{ Ok = $false; Reason = ('Windows could not make a restore point (code {0}). System Protection may be off for drive C:.' -f $result.ReturnValue) }
        }
        $after = & $newest
        if ($null -eq $after) {
            return [pscustomobject]@{ Ok = $false; Reason = ('Windows reported success but there is no restore point. System Protection may be off for drive C:. {0}' -f (Get-AfRestorePointSummary)) }
        }
        if ($after -eq $before) {
            return [pscustomobject]@{ Ok = $false; Reason = ('Windows skipped it, usually because a restore point was already made in the last 24 hours. {0}' -f (Get-AfRestorePointSummary)) }
        }
        return [pscustomobject]@{ Ok = $true; Reason = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = ('System Protection is off or not available: {0}' -f $_.Exception.Message) }
    }
}

function Invoke-AfRestart {
    # Restarts after a countdown that any key cancels.
    [CmdletBinding()]
    param([int] $DelaySeconds = 60)

    $shutdown = Get-AfSystemToolPath 'shutdown.exe'
    & $shutdown /r /t $DelaySeconds /c "auto-fix_Win finished its repairs. Windows restarts in $DelaySeconds seconds." | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host ('  Windows did not accept the restart (exit code {0}).' -f $LASTEXITCODE) -ForegroundColor Red; return }
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { Write-Verbose 'No console keys to clear.' }
    Write-Host ('  RESTARTING in {0} seconds. Press any key to cancel.' -f $DelaySeconds) -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($DelaySeconds)
    while ((Get-Date) -lt $deadline) {
        $pressed = $false
        try { $pressed = [Console]::KeyAvailable } catch { $pressed = $false }
        if ($pressed) {
            [void][Console]::ReadKey($true)
            & $shutdown /a | Out-Host
            Write-Host '  Restart cancelled.' -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 200
    }
}

function Test-AfRepairBusy {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (@(Get-Process -Name 'sfc', 'dism' -ErrorAction SilentlyContinue).Count -gt 0)
}

function Confirm-AfRepairPlan {
    # Technician mode: one plan screen for the whole run. Enter starts, Esc goes back.
    [CmdletBinding()]
    [OutputType([bool])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    Write-Host ''
    Write-Host '  Enter = start, Esc = back. ' -ForegroundColor White -NoNewline
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $key = [string](& $ReadKey)
        if ($key -eq 'Enter') { Write-Host ''; return $true }
        if ($key -eq 'Escape') { Write-Host ''; return $false }
        Write-Host ''
        if ($attempt -eq 1) { Write-Host '  Command unknown. Press Enter to start or Esc to go back. ' -ForegroundColor Yellow -NoNewline }
    }
    Write-Host '  Command unknown again. Going back, nothing was changed.' -ForegroundColor Yellow
    return $false
}

function Invoke-AfRepairBatch {
    <#
    .SYNOPSIS
        Runs SFC and DISM steps in order, with the confirms, restore point and
        announcements the mode needs, and writes a redacted repair.log.
    #>
    [CmdletBinding()]
    param(
        # Step keys in order, such as SFC, CHECK, SCAN, RESTORE, CLEANUP.
        [Parameter(Mandatory)] [string[]] $Queue,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        $Redactor = (New-AfRedactor),
        # Runs one command; gets FilePath, Arguments, EstimatedSeconds, OnProgress, OnMessage and OnStall by name.
        [scriptblock] $RunStep = { param($FilePath, $Arguments, $EstimatedSeconds, $OnProgress, $OnMessage, $OnStall) Invoke-AfRepairProcess @PSBoundParameters },
        [scriptblock] $RestorePoint = { New-AfRestorePoint },
        [scriptblock] $Restart = { Invoke-AfRestart },
        [scriptblock] $IsBusy = { Test-AfRepairBusy }
    )

    $technician = $Settings.Mode -eq 'Technician'
    $results = New-Object System.Collections.Generic.List[object]
    $run = [pscustomobject]@{ Steps = $results; LogPath = $null; RestartNeeded = $false; Stopped = $false; Online = $false }
    $addSkipped = {
        param([int] $From, [string] $Why)
        for ($j = $From; $j -lt $Queue.Count; $j++) {
            $results.Add([pscustomobject]@{ Key = $Queue[$j]; Name = $script:AfRepairSteps[$Queue[$j]].Name; Tag = 'SKIPPED'; Seconds = 0; ExitCode = $null; Result = $Why })
        }
    }

    Write-Host ''
    Write-Host '  Repair system files (SFC and DISM)' -ForegroundColor Cyan
    if (-not $IsAdmin) {
        foreach ($key in $Queue) { Write-Host ('  Skipped: {0} needs administrator rights.' -f $script:AfRepairSteps[$key].Name) -ForegroundColor Yellow }
        Write-Host '  Start auto-fix_Win with AutoFix.bat and say Yes to the Windows prompt.' -ForegroundColor DarkGray
        & $addSkipped 0 'Needs administrator rights'
        return $run
    }

    $historyPath = Join-Path $OutputRoot 'repair-history.csv'
    $estimates = @(foreach ($key in $Queue) { Get-AfRepairEstimate -Key $key -HistoryPath $historyPath })
    $totalEstimate = ($estimates | Measure-Object -Sum).Sum
    $changing = @($Queue | Where-Object { $script:AfRepairSteps[$_].Changes })

    Write-Host ('  {0} step(s), expected {1}. Order: {2}' -f $Queue.Count, (Format-AfApprox $totalEstimate), (@($Queue | ForEach-Object { $script:AfRepairSteps[$_].Name }) -join ' > ')) -ForegroundColor DarkGray
    if ($technician -and $changing.Count -gt 0) {
        Write-Host ''
        Write-Host '  These steps change this PC:' -ForegroundColor White
        foreach ($key in ($changing | Select-Object -Unique)) { Write-Host ('    {0}: {1}' -f $script:AfRepairSteps[$key].Name, $script:AfRepairSteps[$key].What) }
        if ($Queue -contains 'RESTORE' -and $Settings.Online) { Write-Host ('    RestoreHealth may connect to Windows Update (Microsoft).') }
        if (-not (Confirm-AfRepairPlan -ReadKey $ReadKey)) {
            & $addSkipped 0 'Not started'
            $run.Stopped = $true
            return $run
        }
    }
    if (& $IsBusy) { Write-Host '  Another SFC or DISM is already running. Running two at once usually makes one wait or fail.' -ForegroundColor Yellow }

    $null = New-Item -ItemType Directory -Path $OutputRoot -Force
    $folder = New-Item -ItemType Directory -Path (Join-Path $OutputRoot (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    $run.LogPath = Join-Path $folder.FullName 'repair.log'
    $logPath = $run.LogPath
    $log = { param([string] $Text) Add-Content -LiteralPath $logPath -Value (Protect-AfText -Redactor $Redactor -Text $Text) -Encoding UTF8 }

    $windows = 'unknown'
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $windows = '{0} (build {1})' -f $os.Caption, $os.BuildNumber } catch { Write-Verbose 'No Windows version.' }
    $batchStart = Get-Date
    & $log ('auto-fix_Win {0} repair log' -f $script:AfVersion)
    & $log ('Windows   : {0}' -f $windows)
    & $log ('Mode      : {0}; Online switch {1}' -f $Settings.Mode, @{ $true = 'on'; $false = 'off' }[[bool]$Settings.Online])
    & $log ('Run start : {0} UTC' -f $batchStart.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
    & $log ('Plan      : {0} step(s), expected {1}' -f $Queue.Count, (Format-AfSpan $totalEstimate))
    & $log ('-' * 60)

    $askedRestorePoint = $false
    $doneEstimate = 0.0
    $i = 0
    $onMessage = { param($Line) Write-Host ('        {0}' -f (Protect-AfText -Redactor $Redactor -Text $Line)) }
    $onStall = { Read-AfStallChoice -ReadKey $ReadKey }

    Set-AfStayAwake $true
    try {
        for ($i = 0; $i -lt $Queue.Count; $i++) {
            $key = $Queue[$i]
            $step = $script:AfRepairSteps[$key]

            if ($step.Changes) {
                if (-not $technician) {
                    Write-Host ''
                    Write-Host ('  Next: {0}, {1}' -f $step.Name, (Format-AfApprox $estimates[$i])) -ForegroundColor White
                    Write-Host ('  This changes your PC: {0}' -f $step.What)
                    if ((Read-AfYesNo -Prompt ('Start {0}?' -f $step.Name) -ReadKey $ReadKey) -ne $true) {
                        & $log ('Stopped by the user before {0}; remaining steps skipped.' -f $step.Name)
                        $run.Stopped = $true
                        break
                    }
                }
                if (-not $askedRestorePoint) {
                    $askedRestorePoint = $true
                    Write-Host ''
                    if ((Read-AfYesNo -Prompt 'Create a restore point first?' -ReadKey $ReadKey) -eq $true) {
                        Write-Host '  Creating a restore point...' -ForegroundColor DarkGray
                        $point = & $RestorePoint
                        if ($point.Ok) {
                            Write-Host '  Restore point created.' -ForegroundColor Green
                            & $log 'Restore point: created'
                        }
                        else {
                            Write-Host ('  No restore point: {0}' -f $point.Reason) -ForegroundColor Yellow
                            & $log ('Restore point: not created. {0}' -f $point.Reason)
                            if ((Read-AfYesNo -Prompt 'Continue without a restore point?' -ReadKey $ReadKey) -ne $true) {
                                & $log 'Stopped by the user: no restore point; remaining steps skipped.'
                                $run.Stopped = $true
                                break
                            }
                        }
                    }
                    else { & $log 'Restore point: declined' }
                }
            }

            $online = $false
            if ($key -eq 'RESTORE' -and $Settings.Online) {
                Write-Host ''
                Write-Host ('  {0}' -f $script:AfWindowsUpdateNotice) -ForegroundColor Cyan
                $online = $true
                if (-not $technician -and (Read-AfYesNo -Prompt 'Connect to Windows Update?' -ReadKey $ReadKey) -ne $true) {
                    $online = $false
                    Write-Host '  RestoreHealth will use only the files already on this PC.' -ForegroundColor Yellow
                }
            }
            if ($online) { $run.Online = $true; & $log 'Internet  : Windows Update (Microsoft), for RestoreHealth' }

            $arguments = Get-AfRepairArgumentList -Key $key -Online $online
            $after = 0.0
            for ($j = $i + 1; $j -lt $estimates.Count; $j++) { $after += $estimates[$j] }
            $estimate = $estimates[$i]
            $index = $i + 1
            # The progress block runs inside Invoke-AfRepairProcess and finds these by name,
            # so they carry a prefix that the runner's own variables never use.
            $progressDone = $doneEstimate
            $progressAfter = $after
            $progressName = '[{0}/{1}] {2}' -f $index, $Queue.Count, $step.Name
            $progressOverall = 'Overall: step {0} of {1}' -f $index, $Queue.Count
            $progressEstimate = $estimate
            $onProgress = {
                param($Percent, $Known, $Elapsed, $Left, $Quiet)
                $overall = [math]::Min(100, 100 * ($progressDone + $progressEstimate * $Percent / 100) / [math]::Max(1, $totalEstimate))
                $label = '{0:0.0}%' -f $Percent
                if (-not $Known) { $label = '~{0:0}% (time-based; this command shows no %)' -f $Percent }
                Write-Progress -Id 1 -Activity $progressOverall -PercentComplete ([int]$overall) `
                    -Status ('{0:0}% complete | elapsed {1} | about {2} left' -f $overall, (Format-AfSpan ((Get-Date) - $batchStart).TotalSeconds), (Format-AfSpan ($Left + $progressAfter)))
                Write-Progress -Id 2 -ParentId 1 -Activity $progressName -PercentComplete ([int][math]::Min(100, $Percent)) `
                    -Status ('{0} | elapsed {1} | about {2} left' -f $label, (Format-AfSpan $Elapsed), (Format-AfSpan $Left)) `
                    -CurrentOperation ('No activity for {0} (asks you at {1} min)' -f (Format-AfSpan $Quiet), $script:AfStallMinutes)
            }

            $filePath = Get-AfSystemToolPath $step.Exe
            Write-Host ''
            Write-Host (' [{0}/{1}] {2} {3}' -f $index, $Queue.Count, $step.Exe.Replace('.exe', ''), $arguments) -ForegroundColor Cyan
            Write-Host ('        started {0} UTC, expected {1}' -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss'), (Format-AfApprox $estimate)) -ForegroundColor DarkGray

            $r = & $RunStep -FilePath $filePath -Arguments $arguments -EstimatedSeconds $estimate -OnProgress $onProgress -OnMessage $onMessage -OnStall $onStall
            Write-Progress -Id 2 -Activity 'step' -Completed
            Write-Progress -Id 1 -Activity 'overall' -Completed

            $messages = @($r.Messages)
            $result = (@($messages | Where-Object { $_ -match 'Windows Resource Protection|operation completed|component store|repairable|corrupt|Error' }) | Select-Object -Last 2) -join ' '
            if (-not $result -and $messages.Count -gt 0) { $result = $messages[$messages.Count - 1] }
            if ($r.Outcome -eq 'Stopped') {
                $tag = 'STOPPED'
                $result = 'Stopped by the user after the watchdog saw no activity.'
            }
            elseif ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010) { $tag = 'OK' }
            else { $tag = 'FAILED' }
            if ($tag -eq 'OK' -and ($r.ExitCode -eq 3010 -or $result -match 'restart|reboot')) { $run.RestartNeeded = $true }

            & $log ('[{0}/{1}] {2} {3}' -f $index, $Queue.Count, $step.Exe, $arguments)
            & $log ('  Expected  : {0}' -f (Format-AfSpan $estimate))
            & $log ('  Actual    : {0}' -f (Format-AfSpan $r.Seconds))
            if ($null -ne $r.ExitCode) { & $log ('  Exit code : {0}' -f (Get-AfExitText $r.ExitCode)) }
            & $log ('  Outcome   : {0}' -f $tag)
            if ($result) { & $log ('  Result    : {0}' -f $result) }
            & $log ''
            $results.Add([pscustomobject]@{ Key = $key; Name = $step.Name; Tag = $tag; Seconds = $r.Seconds; ExitCode = $r.ExitCode; Result = $result })

            if ($null -ne $r.ExitCode) { Add-AfRepairHistory -HistoryPath $historyPath -Key $key -Seconds $r.Seconds -ExitCode $r.ExitCode }
            if ($key -eq 'RESTORE' -and -not $online -and $r.ExitCode -eq -2146498529) {
                # 0x800F081F: the clean files are not on this PC.
                Write-Host '  RestoreHealth needs clean files that are not on this PC. To let it download them from' -ForegroundColor Yellow
                Write-Host '  Windows Update (Microsoft), turn on "Go online when a step needs it" in Settings and run R again.' -ForegroundColor Yellow
            }
            if ($r.Outcome -eq 'Stopped') {
                & $log 'Remaining steps skipped after a stopped step.'
                $run.Stopped = $true
                $i++
                break
            }
            $doneEstimate += $estimate
        }
    }
    finally {
        Set-AfStayAwake $false
        Write-Progress -Id 1 -Activity 'overall' -Completed
    }
    if ($i -lt $Queue.Count) { & $addSkipped $i 'Not run' }

    $batchEnd = Get-Date
    & $log ('-' * 60)
    & $log ('Run end   : {0} UTC' -f $batchEnd.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
    & $log ('Total     : expected {0}, actual {1}' -f (Format-AfSpan $totalEstimate), (Format-AfSpan ($batchEnd - $batchStart).TotalSeconds))

    Write-Host ''
    Write-Host '  Summary' -ForegroundColor White
    $colors = @{ OK = 'Green'; FAILED = 'Red'; STOPPED = 'Red'; SKIPPED = 'Yellow' }
    foreach ($s in $results) {
        $exitText = ''
        if ($null -ne $s.ExitCode) { $exitText = 'exit ' + (Get-AfExitText $s.ExitCode) }
        Write-Host ('  {0,-8}{1,-24}{2}  {3}' -f $s.Tag, $s.Name, (Format-AfSpan $s.Seconds), $exitText) -ForegroundColor $colors[$s.Tag]
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $run.LogPath)) -ForegroundColor DarkGray

    if ($run.RestartNeeded -and -not $run.Stopped) {
        Write-Host ''
        Write-Host '  Windows needs a restart to finish these repairs.' -ForegroundColor Yellow
        $restartNow = $false
        if ($technician) {
            Write-Host '  R = restart now, any other key = later. ' -NoNewline
            $restartNow = ([string](& $ReadKey)) -eq 'R'
            Write-Host ''
        }
        else { $restartNow = (Read-AfYesNo -Prompt 'Restart now?' -ReadKey $ReadKey) -eq $true }
        if ($restartNow) { & $log 'Restart   : started by the user'; & $Restart }
    }
    return $run
}

function Invoke-AfRepairMenu {
    # The SFC and DISM screen, opened from the main menu.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Settings', Justification = 'Used by the header and the default RunBatch script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        # Called with the queue of step keys; the default runs them.
        [scriptblock] $RunBatch = { param([string[]] $Queue) $null = Invoke-AfRepairBatch -Queue $Queue -Settings $Settings -OutputRoot $OutputRoot -ReadKey $ReadKey }
    )

    $historyPath = Join-Path $OutputRoot 'repair-history.csv'
    $byLetter = @{}
    foreach ($key in $script:AfRepairSteps.Keys) { $byLetter[$script:AfRepairSteps[$key].Letter] = $key }
    $header = {
        Show-AfBanner -Mode $Settings.Mode
        Write-Host ''
        Write-Host '  Repair system files. Read-only steps start on one key; steps that change' -ForegroundColor White
        Write-Host '  your PC show what they change first. Needs administrator rights.' -ForegroundColor White
    }
    while ($true) {
        $items = @(foreach ($key in $script:AfRepairSteps.Keys) {
                $step = $script:AfRepairSteps[$key]
                $kind = 'read-only'
                if ($step.Changes) { $kind = 'changes the PC' }
                @{ Key = $step.Letter; Label = ('{0,-29}{1,-16}{2}' -f $step.Menu, $kind, (Format-AfApprox (Get-AfRepairEstimate -Key $key -HistoryPath $historyPath))) }
            })
        $allSeconds = 0.0
        foreach ($key in $script:AfRunAll) { $allSeconds += Get-AfRepairEstimate -Key $key -HistoryPath $historyPath }
        $items += @{ Key = 'A'; Label = ('{0,-29}{1,-16}{2}' -f 'Run &all (SFC, 4 DISM, SFC)', 'changes the PC', (Format-AfApprox $allSeconds)) }
        $items += @{ Key = 'B'; Label = '&Back' }
        $items += @{ Key = 'Q'; Label = '&Quit' }

        $choice = Select-AfMenuItem -Title 'Repair system files' -Items $items -Header $header -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        $queue = @($script:AfRunAll)
        if ($choice -ne 'A') { $queue = @($byLetter[$choice]) }
        try { & $RunBatch $queue }
        catch { Write-Host ('  The repair stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        Write-Host ''
        Write-Host '  Press any key to return to the repair menu.' -ForegroundColor DarkGray
        $null = & $ReadKey
    }
}
