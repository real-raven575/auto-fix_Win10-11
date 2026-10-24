<#
    SFC + DISM Repair Tool  v1.1  (raven575 work tool, 2026-10-23)

    One-key menu: 1-5 (or S K N R C) run one command right away,
    6 (or A) runs all six, 7 builds your own sequence from the letters, 8 exits.
      - per-step and overall percent complete, elapsed time and time remaining
      - toggles: LOGS (on), PAUSE after each step (on), RETURN to menu with a
        summary (on), REBOOT after complete (off, 60 s countdown, any key cancels)
      - a stall watchdog: 10 min with no output AND no servicing activity
        (CBS.log, dism.log, TiWorker/TrustedInstaller CPU) stops the step
        and offers Retry / back to the Menu / Quit
      - a plain text log per run, plus history.csv used to learn time estimates

    Start it with Run-SfcDismTool.bat (it asks for administrator rights).
#>

$ErrorActionPreference = 'Stop'

# ---------------- settings you can change ----------------
$StallMinutes         = 10   # no output AND no servicing activity this long = stalled
$RebootDelaySec       = 60   # countdown before the optional reboot
$HistoryRunsToAverage = 5    # how many past runs on this PC feed the time estimate

# ---------------- ask for admin rights ----------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Asking for administrator rights...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } catch {
        Write-Host 'Administrator rights were declined. SFC and DISM need them, so the tool cannot run.' -ForegroundColor Red
        Read-Host 'Press Enter to close'
    }
    exit
}

# A 32-bit PowerShell on 64-bit Windows must use Sysnative, or SFC fails to start its service.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $SysDir = Join-Path $env:windir 'Sysnative'
} else {
    $SysDir = Join-Path $env:windir 'System32'
}

# ---------------- the commands ----------------
$Steps = @{
    SFC     = @{ Display = 'sfc /scannow';                                      Short = 'SFC scan';             Exe = 'sfc.exe';  Args = '/scannow';                                    DefaultMin = 15 }
    CHECK   = @{ Display = 'DISM /Online /Cleanup-Image /CheckHealth';           Short = 'DISM CheckHealth';     Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /CheckHealth';           DefaultMin = 1 }
    SCAN    = @{ Display = 'DISM /Online /Cleanup-Image /ScanHealth';            Short = 'DISM ScanHealth';      Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /ScanHealth';            DefaultMin = 10 }
    RESTORE = @{ Display = 'DISM /Online /Cleanup-Image /RestoreHealth';         Short = 'DISM RestoreHealth';   Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /RestoreHealth';         DefaultMin = 20 }
    CLEANUP = @{ Display = 'DISM /Online /Cleanup-Image /StartComponentCleanup'; Short = 'DISM ComponentCleanup'; Exe = 'dism.exe'; Args = '/Online /Cleanup-Image /StartComponentCleanup'; DefaultMin = 15 }
}
$StepOrder = @('SFC', 'CHECK', 'SCAN', 'RESTORE', 'CLEANUP')

$Letters = [ordered]@{ S = 'SFC'; K = 'CHECK'; N = 'SCAN'; R = 'RESTORE'; C = 'CLEANUP' }
$RunAll  = @('SFC', 'CHECK', 'SCAN', 'RESTORE', 'CLEANUP', 'SFC')

$State = @{
    Logs         = $true    # write a text log for each run
    Pause        = $true    # ask "Continue?" after each step (RUN ALL switches this OFF)
    ReturnToMenu = $true    # go back to the menu (with a summary) when a run ends
    Reboot       = $false   # restart Windows when the whole run finishes
}
$script:LastSummary = @()

# ---------------- log folder ----------------
$LogDir = Join-Path $PSScriptRoot 'Logs'
try {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $probe = Join-Path $LogDir '.write-test'
    Set-Content -LiteralPath $probe -Value 'x'
    Remove-Item -LiteralPath $probe
} catch {
    $LogDir = Join-Path $env:PUBLIC 'Documents\SfcDismTool-Logs'
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$HistoryFile = Join-Path $LogDir 'history.csv'

# ---------------- keep the PC awake while a step runs ----------------
Add-Type -Namespace SfcDismTool -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
function Set-StayAwake([bool]$on) {
    # ES_CONTINUOUS (0x80000000) + ES_SYSTEM_REQUIRED (0x1) while on; ES_CONTINUOUS alone clears it
    if ($on) { [void][SfcDismTool.Power]::SetThreadExecutionState([uint32]2147483649) }
    else     { [void][SfcDismTool.Power]::SetThreadExecutionState([uint32]2147483648) }
}

# ---------------- small helpers ----------------
function Format-When([datetime]$t) { $t.ToString('yyyy-MM-dd HH:mm:ss') + ' (UTC' + $t.ToString('zzz') + ')' }

function Format-Span([double]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Round($sec))
    '{0:00}:{1:00}:{2:00}' -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

function Format-Approx([double]$sec) {
    $min = [math]::Max(1, [math]::Round($sec / 60))
    if ($min -lt 60) { return "~$min min" }
    '~{0} h {1} min' -f [math]::Floor($min / 60), ($min % 60)
}

function Get-EstimateSec([string]$key) {
    $default = $Steps[$key].DefaultMin * 60
    if (-not (Test-Path -LiteralPath $HistoryFile)) { return $default }
    try {
        $rows = @(Import-Csv -LiteralPath $HistoryFile | Where-Object { $_.Step -eq $key -and $_.Computer -eq $env:COMPUTERNAME })
        if ($rows.Count -eq 0) { return $default }
        $recent = $rows | Select-Object -Last $HistoryRunsToAverage
        return [math]::Max(30, [math]::Round(($recent | ForEach-Object { [double]$_.Seconds } | Measure-Object -Average).Average))
    } catch { return $default }
}

function Add-History([string]$key, [double]$sec) {
    try {
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Step = $key; Seconds = [math]::Round($sec); Date = (Get-Date).ToString('s') } |
            Export-Csv -LiteralPath $HistoryFile -Append -NoTypeInformation
    } catch { }
}

function Get-Pct([string]$s) {
    # SFC prints "Verification 45% complete."  DISM prints "[=====   45.0%   ]" (some locales use 45,0%)
    $m = [regex]::Matches($s, '(\d{1,3}(?:[.,]\d+)?)\s*%')
    if ($m.Count -eq 0) { return $null }
    $v = [double]::Parse($m[$m.Count - 1].Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    if ($v -gt 100) { return $null }
    $v
}

function Get-ExitText([int]$code) {
    $hex = '0x{0:X8}' -f $code
    switch ($hex) {
        '0x00000000' { return '0 (success)' }
        '0x00000057' { return '87 (bad parameter)' }
        '0x000002E4' { return '740 (needs administrator rights)' }
        '0x800F081F' { return "$hex (repair source files could not be found)" }
        '0x800F0906' { return "$hex (could not download repair source files)" }
        '0x800F0954' { return "$hex (repair source blocked, often WSUS or Group Policy)" }
        default      { return "$code ($hex)" }
    }
}

# Servicing activity "fingerprint": log sizes/write times plus CPU seconds of the servicing processes.
# If this changes, Windows is still working even when the command window is quiet.
$WatchLogs  = @((Join-Path $env:windir 'Logs\CBS\CBS.log'), (Join-Path $env:windir 'Logs\DISM\dism.log'))
$WatchProcs = @('TiWorker', 'TrustedInstaller', 'DismHost', 'sfc', 'dism')
function Get-ActivitySignature {
    $parts = @()
    foreach ($f in $WatchLogs) {
        $item = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
        if ($item) { $parts += '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks }
    }
    $cpuMs = 0
    foreach ($p in @(Get-Process -Name $WatchProcs -ErrorAction SilentlyContinue)) {
        try { $cpuMs += $p.TotalProcessorTime.TotalMilliseconds } catch { }
    }
    $parts += [math]::Floor($cpuMs / 1000)
    $parts -join '|'
}

function Read-YesNo([string]$prompt) {
    $a = (Read-Host "$prompt [Y/n]").Trim()
    return ($a -eq '' -or $a -match '^(y|yes)$')
}

function Write-Log([string]$text) {
    if (-not $State.Logs) { return }
    Add-Content -LiteralPath $script:LogFile -Value $text -Encoding UTF8
}

function Read-OneKey {
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }   # drop stray key presses
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq 'Escape') { return 'ESC' }
    ([string]$k.KeyChar).ToUpper()
}

function Get-TotalEst([string[]]$queue) { $t = 0.0; foreach ($k in $queue) { $t += Get-EstimateSec $k }; $t }

# ---------------- run one command ----------------
function Invoke-Step {
    param([string]$Key, [int]$Index, [int]$Count, [double]$EstSec,
          [double]$DoneEstSec, [double]$AfterEstSec, [double]$TotalEstSec, [datetime]$BatchStart)

    $step = $Steps[$Key]
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = Join-Path $SysDir $step.Exe
    $psi.Arguments              = $step.Args
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    Write-Host ''
    Write-Host (" [{0}/{1}] {2}" -f $Index, $Count, $step.Display) -ForegroundColor Cyan
    Write-Host ("        started {0}, expected {1}" -f (Format-When (Get-Date)), (Format-Approx $EstSec)) -ForegroundColor DarkGray

    $start      = Get-Date
    $lastOutput = $start
    $lastServ   = $start
    $sig        = Get-ActivitySignature
    $nextProbe  = $start.AddSeconds(15)
    $pct        = $null
    $pending    = ''
    $messages   = New-Object System.Collections.Generic.List[string]
    $eof        = $false
    $exitSeen   = $null
    $outcome    = 'Completed'
    $proc       = $null

    try {
        $proc    = [System.Diagnostics.Process]::Start($psi)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $stream  = $proc.StandardOutput.BaseStream
        $buf     = New-Object byte[] 4096
        $readTask = $stream.ReadAsync($buf, 0, $buf.Length)

        while ($true) {
            # 1. read whatever the command printed (waits up to 0.5 s)
            if (-not $eof) {
                if ($readTask.Wait(500)) {
                    $n = $readTask.Result
                    if ($n -le 0) {
                        $eof = $true
                    } else {
                        $lastOutput = Get-Date
                        # SFC writes UTF-16 when redirected; dropping the zero bytes makes both tools readable
                        $text = [Text.Encoding]::Default.GetString($buf, 0, $n).Replace("`0", '')
                        $pending += $text
                        $segments = $pending -split "[\r\n]"
                        $pending = $segments[$segments.Count - 1]
                        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
                            $s = $segments[$i].Trim()
                            if (-not $s) { continue }
                            $p = Get-Pct $s
                            if ($null -ne $p) { $pct = $p }
                            else { Write-Host "        $s"; $messages.Add($s) }
                        }
                        $p = Get-Pct $pending
                        if ($null -ne $p) { $pct = $p }
                        if ($pending.Length -gt 2000) { $pending = $pending.Substring($pending.Length - 500) }
                        $readTask = $stream.ReadAsync($buf, 0, $buf.Length)
                    }
                }
            } else {
                Start-Sleep -Milliseconds 300
            }

            $now = Get-Date

            # 2. finished?
            if ($proc.HasExited) {
                if ($null -eq $exitSeen) { $exitSeen = $now }
                if ($eof -or ($now - $exitSeen).TotalSeconds -ge 5) { break }
            }

            # 3. servicing activity check every 15 s
            if ($now -ge $nextProbe) {
                $newSig = Get-ActivitySignature
                if ($newSig -ne $sig) { $sig = $newSig; $lastServ = $now }
                $nextProbe = $now.AddSeconds(15)
            }

            # 4. stall watchdog: quiet window AND quiet services for $StallMinutes
            $quietOut  = ($now - $lastOutput).TotalSeconds
            $quietServ = ($now - $lastServ).TotalSeconds
            if ($quietOut -ge $StallMinutes * 60 -and $quietServ -ge $StallMinutes * 60) {
                $outcome = 'Stalled'
                Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -Wait
                break
            }

            # 5. progress display
            $elapsed = ($now - $start).TotalSeconds
            if ($null -ne $pct) {
                $stepPct  = $pct
                $pctLabel = '{0:0.0}%' -f $pct
                if ($pct -ge 5) { $stepRemain = $elapsed * (100 - $pct) / $pct }
                else            { $stepRemain = $EstSec - $elapsed }
            } else {
                $stepPct    = [math]::Min(95, 100 * $elapsed / $EstSec)
                $pctLabel   = '~{0:0}% (time-based; this command shows no %)' -f $stepPct
                $stepRemain = $EstSec - $elapsed
            }
            if ($stepRemain -lt 0) { $stepRemain = 0 }
            $overallPct    = [math]::Min(100, 100 * ($DoneEstSec + $EstSec * $stepPct / 100) / $TotalEstSec)
            $overallRemain = $stepRemain + $AfterEstSec
            $overallElap   = ($now - $BatchStart).TotalSeconds
            $quiet         = [math]::Min($quietOut, $quietServ)

            Write-Progress -Id 1 -Activity ("OVERALL: step {0} of {1}" -f $Index, $Count) `
                -Status ("{0:0}% complete | elapsed {1} | est. remaining {2}" -f $overallPct, (Format-Span $overallElap), (Format-Span $overallRemain)) `
                -PercentComplete ([int]$overallPct)
            Write-Progress -Id 2 -ParentId 1 -Activity ("[{0}/{1}] {2}" -f $Index, $Count, $step.Display) `
                -Status ("{0} | elapsed {1} | est. remaining {2} | expected {3}" -f $pctLabel, (Format-Span $elapsed), (Format-Span $stepRemain), (Format-Approx $EstSec)) `
                -PercentComplete ([int][math]::Min(100, $stepPct)) `
                -CurrentOperation ("No activity for {0} (auto-stop at {1} min)" -f (Format-Span $quiet), $StallMinutes)
            $Host.UI.RawUI.WindowTitle = '{0:0}% overall - {1}' -f $overallPct, $step.Short
        }

        if ($outcome -eq 'Completed') {
            $proc.WaitForExit()
            $errText = ''
            if ($errTask.Wait(2000)) { $errText = $errTask.Result.Replace("`0", '').Trim() }
            if ($errText) { foreach ($line in ($errText -split "[\r\n]+")) { if ($line.Trim()) { $messages.Add($line.Trim()) } } }
        }
    } finally {
        # Ctrl+C or any error: never leave the command running in the background
        if ($proc -and -not $proc.HasExited) {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" -WindowStyle Hidden -Wait
        }
    }

    $end = Get-Date
    $exitCode = $null
    if ($outcome -eq 'Completed') { $exitCode = $proc.ExitCode }

    $result = (@($messages | Where-Object { $_ -match 'Windows Resource Protection|operation completed|component store|repairable|corrupt|Error' }) |
               Select-Object -Last 2) -join ' '
    if (-not $result -and $messages.Count -gt 0) { $result = $messages[$messages.Count - 1] }
    if ($outcome -eq 'Stalled') { $result = "Stopped by the watchdog: no output and no servicing activity for $StallMinutes minutes." }

    @{ Outcome = $outcome; Start = $start; End = $end; Seconds = ($end - $start).TotalSeconds; ExitCode = $exitCode; Result = $result }
}

# ---------------- run a list of commands ----------------
function Start-Batch([string[]]$queue) {
    $ests = @(foreach ($k in $queue) { [double](Get-EstimateSec $k) })
    $totalEst = ($ests | Measure-Object -Sum).Sum

    Clear-Host
    Write-Host ''
    Write-Host (' RUNNING {0} step(s), expected {1}   |   Pause {2}   Logs {3}   Reboot {4}' -f `
        $queue.Count, (Format-Approx $totalEst), (Get-OnOffWord $State.Pause), (Get-OnOffWord $State.Logs), (Get-OnOffWord $State.Reboot)) -ForegroundColor Cyan
    Write-Host ('   Order: {0}' -f (@($queue | ForEach-Object { $Steps[$_].Short }) -join ' > ')) -ForegroundColor DarkGray
    $busy = @(Get-Process -Name 'sfc', 'dism' -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        Write-Host ' Another SFC or DISM is already running. Running two at once usually makes one wait or fail.' -ForegroundColor Yellow
    }

    $batchStart = Get-Date
    $script:LogFile = Join-Path $LogDir ('SfcDism_{0}_{1}.txt' -f $env:COMPUTERNAME, $batchStart.ToString('yyyy-MM-dd_HHmmss'))
    if ($State.Logs) {
        $os = ''
        try { $c = Get-CimInstance Win32_OperatingSystem; $os = '{0} (build {1})' -f $c.Caption, $c.BuildNumber } catch { }
        Write-Log 'SFC + DISM Repair Tool log'
        Write-Log ('Computer  : {0}' -f $env:COMPUTERNAME)
        Write-Log ('Windows   : {0}' -f $os)
        Write-Log ('Run by    : {0}' -f $identity.Name)
        Write-Log ('Run start : {0}' -f (Format-When $batchStart))
        Write-Log ('Plan      : {0} step(s), expected total {1}, pause after each step {2}, reboot after complete {3}' -f `
                   $queue.Count, (Format-Span $totalEst), (Get-OnOffWord $State.Pause), (Get-OnOffWord $State.Reboot))
        Write-Log ('-' * 60)
    }

    $summary  = New-Object System.Collections.Generic.List[string]
    $doneEst  = 0.0
    $finished = $false
    $aborted  = $false
    $next     = 'menu'
    $i        = 0
    Set-StayAwake $true
    try {
        while ($i -lt $queue.Count) {
            $after = 0.0
            for ($j = $i + 1; $j -lt $ests.Count; $j++) { $after += $ests[$j] }

            $r = Invoke-Step -Key $queue[$i] -Index ($i + 1) -Count $queue.Count -EstSec $ests[$i] `
                             -DoneEstSec $doneEst -AfterEstSec $after -TotalEstSec $totalEst -BatchStart $batchStart

            Write-Log ('[{0}/{1}] {2}' -f ($i + 1), $queue.Count, $Steps[$queue[$i]].Display)
            Write-Log ('  Started   : {0}' -f (Format-When $r.Start))
            Write-Log ('  Expected  : {0}' -f (Format-Span $ests[$i]))
            Write-Log ('  Actual    : {0}' -f (Format-Span $r.Seconds))
            if ($r.Outcome -eq 'Completed') {
                Write-Log ('  Completed : {0}' -f (Format-When $r.End))
                Write-Log ('  Exit code : {0}' -f (Get-ExitText $r.ExitCode))
            } else {
                Write-Log ('  Stopped   : {0}' -f (Format-When $r.End))
            }
            if ($r.Result) { Write-Log ('  Result    : {0}' -f $r.Result) }
            Write-Log ''

            if ($r.Outcome -eq 'Stalled')   { $tag = 'STALLED' }
            elseif ($r.ExitCode -eq 0)      { $tag = 'OK' }
            else                            { $tag = 'FAILED' }
            $short = [string]$r.Result
            if ($short.Length -gt 70) { $short = $short.Substring(0, 67) + '...' }
            $summary.Add(('  {0,-8}{1,-24}{2}  {3}' -f $tag, $Steps[$queue[$i]].Short, (Format-Span $r.Seconds), $short))

            if ($r.Outcome -eq 'Stalled') {
                Write-Progress -Id 2 -Activity 'step' -Completed
                Write-Progress -Id 1 -Activity 'overall' -Completed
                Write-Host ''
                Write-Host (" STALLED: {0} showed no output and Windows servicing showed no activity for {1} minutes." -f $Steps[$queue[$i]].Display, $StallMinutes) -ForegroundColor Red
                Write-Host ' The command was stopped.' -ForegroundColor Red
                Write-Host ' [R] Retry this step    [M] Back to the menu    [Q] Quit' -ForegroundColor Yellow
                $choice = ''
                while ($choice -notin @('R', 'M', 'Q')) { $choice = Read-OneKey }
                if ($choice -eq 'R') { Write-Log '  -> Retry chosen'; continue }
                $aborted = $true
                if ($choice -eq 'M') { Write-Log '  -> Back to the menu; remaining steps skipped'; $next = 'menu' }
                else                 { Write-Log '  -> Quit chosen; remaining steps skipped'; $next = 'quit' }
                $i++
                break
            }

            if ($r.ExitCode -eq 0) { Add-History $queue[$i] $r.Seconds }   # only clean runs teach the estimate
            $doneEst += $ests[$i]
            $i++

            if ($State.Pause -and $i -lt $queue.Count) {
                Write-Progress -Id 2 -Activity 'step' -Completed
                Write-Progress -Id 1 -Activity 'overall' -Completed
                Write-Host ''
                if (-not (Read-YesNo (" Continue with step {0}: {1}?" -f ($i + 1), $Steps[$queue[$i]].Display))) {
                    Write-Log ('Stopped by user before step {0}; remaining steps skipped.' -f ($i + 1))
                    $aborted = $true
                    break
                }
            }
        }
        $finished = $true
    } finally {
        Set-StayAwake $false
        Write-Progress -Id 2 -Activity 'step' -Completed
        Write-Progress -Id 1 -Activity 'overall' -Completed
        if (-not $finished) { Write-Log ('Run interrupted (window closed or Ctrl+C) at {0}' -f (Format-When (Get-Date))) }
    }
    for ($j = $i; $j -lt $queue.Count; $j++) { $summary.Add(('  {0,-8}{1}' -f 'SKIPPED', $Steps[$queue[$j]].Short)) }

    $batchEnd = Get-Date
    Write-Log ('-' * 60)
    Write-Log ('Run end   : {0}' -f (Format-When $batchEnd))
    Write-Log ('Total     : expected {0}, actual {1}' -f (Format-Span $totalEst), (Format-Span ($batchEnd - $batchStart).TotalSeconds))
    $Host.UI.RawUI.WindowTitle = 'SFC + DISM Repair Tool'

    $head = if ($aborted) { 'LAST RUN (stopped early)' } else { 'LAST RUN (all steps ran)' }
    $script:LastSummary = @(
        ('  {0}  finished {1}, took {2} (expected {3})' -f $head, (Format-When $batchEnd), (Format-Span ($batchEnd - $batchStart).TotalSeconds), (Format-Span $totalEst))
    ) + $summary.ToArray()
    if ($State.Logs) { $script:LastSummary += "  Log: $script:LogFile" } else { $script:LastSummary += '  Log: OFF for this run' }

    Write-Host ''
    if ($aborted) { Write-Host ' Run stopped early.' -ForegroundColor Yellow }
    else          { Write-Host ' All selected steps have run. Any FAILED step shows in red on the summary.' -ForegroundColor Green }

    if (-not $aborted -and $State.Reboot) {
        Write-Log ('Reboot    : countdown of {0} s started at {1}' -f $RebootDelaySec, (Format-When (Get-Date)))
        & shutdown.exe /r /t $RebootDelaySec /c "SFC + DISM Repair Tool finished. Restarting in $RebootDelaySec seconds." | Out-Host
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
        Write-Host ''
        Write-Host (" RESTARTING in {0} seconds. Press ANY KEY to cancel the restart." -f $RebootDelaySec) -ForegroundColor Yellow
        $deadline = (Get-Date).AddSeconds($RebootDelaySec)
        $cancelled = $false
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)
                & shutdown.exe /a | Out-Host
                $cancelled = $true
                Write-Host ' Restart cancelled.' -ForegroundColor Green
                Write-Log ('Reboot    : cancelled by user at {0}' -f (Format-When (Get-Date)))
                $script:LastSummary += '  Reboot: cancelled'
                break
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $cancelled) { Start-Sleep -Seconds 30; return 'quit' }   # Windows is restarting
    } elseif ($aborted -and $State.Reboot) {
        Write-Log 'Reboot    : skipped because the run stopped early'
        $script:LastSummary += '  Reboot: skipped because the run stopped early'
    }

    if ($next -eq 'quit') { return 'quit' }
    if ($State.ReturnToMenu) { return 'menu' }

    # RETURN to menu is OFF: show the summary here and close on a key press
    Write-Host ''
    $script:LastSummary | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host ' Press any key to close.'
    [void](Read-OneKey)
    return 'quit'
}

# ---------------- screens ----------------
function Get-OnOffWord([bool]$v) { if ($v) { 'ON' } else { 'OFF' } }
function Show-OnOff([bool]$v) { if ($v) { '[ ON  ]' } else { '[ OFF ]' } }

function Show-Sequence {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host ' PICK YOUR SEQUENCE' -ForegroundColor Cyan
        Write-Host ''
        foreach ($l in $Letters.Keys) {
            Write-Host ('   {0}  {1,-52} {2}' -f $l, $Steps[$Letters[$l]].Display, (Format-Approx (Get-EstimateSec $Letters[$l])))
        }
        Write-Host ''
        Write-Host '   Type the letters in the order you want, then press Enter.'
        Write-Host '   Example: SNRS  =  sfc > DISM scan > DISM restore > sfc'
        Write-Host '   Press Enter on an empty line to go back to the menu.'
        Write-Host ''
        $in = (Read-Host ' Sequence').ToUpper() -replace '[\s,>\-+]', ''
        if (-not $in) { return 'menu' }
        $bad = @($in.ToCharArray() | Where-Object { -not $Letters.Contains([string]$_) })
        if ($bad.Count -gt 0) {
            Write-Host (" '{0}' is not one of S K N R C. Try again." -f (($bad | Select-Object -Unique) -join ' ')) -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            continue
        }
        if ($in.Length -gt 20) {
            Write-Host ' Please use 20 steps or fewer.' -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            continue
        }
        $queue = @($in.ToCharArray() | ForEach-Object { $Letters[[string]$_] })
        return (Start-Batch $queue)
    }
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host ' ==============================================================' -ForegroundColor Cyan
    Write-Host '   SFC + DISM REPAIR TOOL        press one key, it starts' -ForegroundColor Cyan
    Write-Host ' ==============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('   (1) [S]  sfc /scannow ............................ {0}' -f (Format-Approx (Get-EstimateSec 'SFC')))
    Write-Host ('   (2) [K]  DISM CheckHealth ........................ {0}' -f (Format-Approx (Get-EstimateSec 'CHECK')))
    Write-Host ('   (3) [N]  DISM ScanHealth ......................... {0}' -f (Format-Approx (Get-EstimateSec 'SCAN')))
    Write-Host ('   (4) [R]  DISM RestoreHealth ...................... {0}' -f (Format-Approx (Get-EstimateSec 'RESTORE')))
    Write-Host ('   (5) [C]  DISM StartComponentCleanup .............. {0}' -f (Format-Approx (Get-EstimateSec 'CLEANUP')))
    Write-Host ('   (6) [A]  RUN ALL: sfc, 4 DISM, sfc again ......... {0}' -f (Format-Approx (Get-TotalEst $RunAll)))
    Write-Host '            (switches PAUSE to OFF)'
    Write-Host ''
    Write-Host '   (7)      Pick Your Sequence (type letters, e.g. SNRS)'
    Write-Host ''
    Write-Host '   (8)      EXIT'
    Write-Host ''
    Write-Host '  OPTIONS (press the letter to switch ON/OFF)' -ForegroundColor Cyan
    Write-Host ('   [L]  LOGS ................................. {0}' -f (Show-OnOff $State.Logs))
    Write-Host ('   [P]  PAUSE after each step ................ {0}' -f (Show-OnOff $State.Pause))
    Write-Host ('   [M]  RETURN to menu after complete ........ {0}' -f (Show-OnOff $State.ReturnToMenu))
    Write-Host ('   [B]  REBOOT after complete ................ {0}' -f (Show-OnOff $State.Reboot))
    Write-Host '   [O]  Open the log folder'
    Write-Host ''
    if ($script:LastSummary.Count -gt 0) {
        Write-Host ' --------------------------------------------------------------' -ForegroundColor DarkGray
        foreach ($line in $script:LastSummary) {
            $color = 'Gray'
            if ($line -match '^\s+(FAILED|STALLED)') { $color = 'Red' }
            elseif ($line -match '^\s+SKIPPED')      { $color = 'Yellow' }
            elseif ($line -match '^\s+OK')           { $color = 'Green' }
            Write-Host $line -ForegroundColor $color
        }
        Write-Host ''
    }
}

# ---------------- main loop ----------------
$Host.UI.RawUI.WindowTitle = 'SFC + DISM Repair Tool'
$quit = $false
while (-not $quit) {
    Show-Menu
    $pick = Read-OneKey
    $next = 'menu'
    switch ($pick) {
        { $_ -in '1', 'S' } { $next = Start-Batch @('SFC') }
        { $_ -in '2', 'K' } { $next = Start-Batch @('CHECK') }
        { $_ -in '3', 'N' } { $next = Start-Batch @('SCAN') }
        { $_ -in '4', 'R' } { $next = Start-Batch @('RESTORE') }
        { $_ -in '5', 'C' } { $next = Start-Batch @('CLEANUP') }
        { $_ -in '6', 'A' } { $State.Pause = $false; $next = Start-Batch $RunAll }
        '7'                 { $next = Show-Sequence }
        { $_ -in '8', 'ESC' } { $next = 'quit' }
        'L' { $State.Logs = -not $State.Logs }
        'P' { $State.Pause = -not $State.Pause }
        'M' { $State.ReturnToMenu = -not $State.ReturnToMenu }
        'B' { $State.Reboot = -not $State.Reboot }
        'O' { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$LogDir`"" }
    }
    if ($next -eq 'quit') { $quit = $true }
}
