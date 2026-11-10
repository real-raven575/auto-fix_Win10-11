<#
.SYNOPSIS
    Retries Microsoft Store app updates that failed with 0x80073D02 because the
    app was open (Auto-Fixer finding SIG-WU-002, fix ADVICE-CLOSE-APP-RETRY).
.DESCRIPTION
    Built on the HERD themed one-off template (Templates\HerdOneOff.ps1).
      1. Read-only: reads the Windows Update events (System log, last 30 days) and
         lists the apps whose update failed with 0x80073D02 and has not installed since.
      2. Read-only: matches each one to the installed app and finds its open windows
         (processes started from the app's install folder).
      3. Change, asks first: closes the open ones. With someone at the keyboard it asks
         per app and tries a gentle close first. A force close comes with a red warning
         that unsaved work is lost, and asks again.
         In Background Mode (-Go YES) the signed-in user gets a pop-up warning first
         (msg.exe), then 60 seconds to save, then the app is force-closed. If the
         warning cannot be shown, the app is skipped, never closed without a warning.
      4. Change, asks first: asks Microsoft Store to check for app updates and install
         them. This downloads from Microsoft Store servers (internet).
      5. Read-only: waits up to 5 minutes and reports each app: Updated or Still waiting.
      6. Change, asks first, never in Background Mode: reopens the apps it closed.
    Never closes the window this script runs in (Windows Terminal and PowerShell are
    Store apps too), and never touches Windows' own system apps or frameworks.
.PARAMETER Plain
    No colour: for screen readers, old consoles and copy-paste.
.PARAMETER Technician
    The orange Technician frame instead of the Standard cyan one.
.PARAMETER Background
    Background Mode: never asks. Also on by itself when there is no keyboard
    (RMM tools, SYSTEM, scheduled tasks).
.PARAMETER Go
    In Background Mode, change steps run only when this is exactly YES.
.PARAMETER Days
    How many days of Windows Update events to read. Default 30.
.PARAMETER WarnSeconds
    Background Mode: seconds between the pop-up warning and the force close. Default 60.
.PARAMETER WaitSeconds
    How long to wait for the updates to install before reporting. Default 300.
.NOTES
    HOW TO USE:
      Needs:    administrator. Internet for step 4 (Microsoft Store servers; NOT yet
                approved by raven575). Windows 10 or 11, Windows PowerShell 5.1.
      Order:    run after an Auto-Fixer scan shows "Store app updates blocked".
      Changes:  closes open Store apps (unsaved work in a force-closed app is lost;
                reopen it from Start), and starts a Store app update check (undo: none
                needed, it is the same as pressing "Get updates" in the Store).
      Terms:    Store app = an app installed or updated by Microsoft Store, such as
                Photos, Calculator, Xbox or Windows Terminal.
                0x80073D02 = Windows could not update the app because it was open.
                Background Mode as SYSTEM uses Windows' built-in device management
                bridge (MDM) to start the Store update check. As a normal administrator
                that bridge refuses, so the Store's "Downloads" page opens instead.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Retry-StoreAppUpdates.ps1 -WhatIf
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Retry-StoreAppUpdates.ps1 -Background -Go YES
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Plain,
    [switch] $Technician,
    [switch] $Background,
    [string] $Go = '',
    [ValidateRange(1, 365)] [int] $Days = 30,
    [ValidateRange(10, 600)] [int] $WarnSeconds = 60,
    [ValidateRange(0, 3600)] [int] $WaitSeconds = 300
)

# ---------------------------------------------------------------- shared look ---
$script:HerdTitle = 'Retry Store app updates'
$script:HerdPlain = [bool]$Plain -or [bool]$env:NO_COLOR
$script:HerdLog = New-Object System.Collections.Generic.List[string]
$script:HerdGo = $Go
$script:HerdBackground = [bool]$Background
try { if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { $script:HerdBackground = $true } }
catch { $script:HerdBackground = $true }
$script:HerdGlyph = @{
    H = [string][char]0x2500; V = [string][char]0x2502
    TopLeft = [string][char]0x250C; TopRight = [string][char]0x2510
    BottomLeft = [string][char]0x2514; BottomRight = [string][char]0x2518
}

function Get-HerdTheme {
    # The same colours as Auto-Fixer's Get-AfTheme (16-colour names only).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch] $Technician)

    if ($Technician) { return @{ Frame = 'DarkYellow'; Accent = 'Yellow' } }
    return @{ Frame = 'DarkCyan'; Accent = 'Cyan' }
}

function Get-HerdBarFill {
    # How many of -Width cells are done. Rounds down, so a full bar means 100%.
    [CmdletBinding()]
    [OutputType([int])]
    param([double] $Percent, [int] $Width)

    if ($Width -le 0) { return 0 }
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    return [int][math]::Floor($Width * $p / 100)
}

function Get-HerdStatusLine {
    # One result line, the same shape as an Auto-Fixer scan line.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Status, [string] $Step, [AllowEmptyString()] [string] $Summary, [double] $Seconds)

    return '[{0,-7}] {1} - {2} ({3} s)' -f $Status.ToLowerInvariant(), $Step, $Summary, [math]::Round($Seconds, 1)
}

function Protect-HerdText {
    # Masks this PC's computer, user and domain names, so a log or RESULT can be shared.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text)

    $masks = [ordered]@{ COMPUTERNAME = '<PC>'; USERDOMAIN = '<DOMAIN>'; USERNAME = '<USER>' }
    foreach ($name in $masks.Keys) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $value.Length -ge 2) { $Text = $Text -ireplace [regex]::Escape($value), $masks[$name] }
    }
    return $Text
}

function Add-HerdLog {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $script:HerdLog.Add(('{0:yyyy-MM-dd HH:mm:ss}Z {1}' -f [datetime]::UtcNow, (Protect-HerdText $Text)))
}

function Write-HerdLine {
    # Writes text in a colour, or plain when colour is off.
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text, [string] $Fg = 'Gray', [string] $Bg, [switch] $NoNewline)

    if ($script:HerdPlain) { Write-Host $Text -NoNewline:$NoNewline; return }
    if ($Bg) { Write-Host $Text -ForegroundColor $Fg -BackgroundColor $Bg -NoNewline:$NoNewline }
    else { Write-Host $Text -ForegroundColor $Fg -NoNewline:$NoNewline }
}

function Write-HerdHeader {
    # The framed title box, 78 wide, in the mode colour.
    [CmdletBinding()]
    param([string] $Title, [string[]] $Lines = @(), [switch] $Technician)

    $theme = Get-HerdTheme -Technician:$Technician
    $g = $script:HerdGlyph
    $name = ' {0} ' -f $Title.ToUpperInvariant()
    Write-HerdLine (' ' + $g.TopLeft + $g.H) $theme.Frame -NoNewline
    Write-HerdLine $name $theme.Accent -NoNewline
    Write-HerdLine (($g.H * (75 - $name.Length)) + $g.TopRight) $theme.Frame
    foreach ($line in $Lines) {
        $text = $line
        if ($text.Length -gt 74) { $text = $text.Substring(0, 74) }
        Write-HerdLine (' ' + $g.V + ' ') $theme.Frame -NoNewline
        Write-HerdLine $text.PadRight(74) 'White' -NoNewline
        Write-HerdLine (' ' + $g.V) $theme.Frame
    }
    Write-HerdLine (' ' + $g.BottomLeft + ($g.H * 76) + $g.BottomRight) $theme.Frame
    Write-Host ''
}

function Write-HerdWarning {
    # A highlighted warning: Black on Yellow tag, yellow text. Also goes to the log.
    [CmdletBinding()]
    param([string] $Text)

    Add-HerdLog "WARNING: $Text"
    if ($script:HerdPlain) { Write-Host "WARNING: $Text"; return }
    Write-Host ' WARNING ' -ForegroundColor Black -BackgroundColor Yellow -NoNewline
    Write-Host " $Text" -ForegroundColor Yellow
}

function Write-HerdFailure {
    # A highlighted failure: White on DarkRed tag, red text. Give the exit code and its meaning.
    [CmdletBinding()]
    param([string] $Text)

    Add-HerdLog "FAILED: $Text"
    if ($script:HerdPlain) { Write-Host "FAILED: $Text"; return }
    Write-Host ' FAILED ' -ForegroundColor White -BackgroundColor DarkRed -NoNewline
    Write-Host " $Text" -ForegroundColor Red
}

function Write-HerdProgress {
    # One bar row, redrawn in place. Redirected output gets no bar (logs stay clean).
    [CmdletBinding()]
    param([string] $Text, [double] $Percent)

    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    if ($redirected) { return }
    $width = 50
    $done = Get-HerdBarFill -Percent $Percent -Width $width
    $label = ('{0,3}%' -f [int][math]::Floor([math]::Max(0.0, [math]::Min(100.0, $Percent))))
    $words = $Text
    if ($words.Length -gt 20) { $words = $words.Substring(0, 20) }
    Write-Host ("`r " + $words.PadRight(21)) -NoNewline
    if ($script:HerdPlain) {
        Write-Host (('#' * $done) + ('-' * ($width - $done)) + ' ' + $label) -NoNewline
        return
    }
    if ($done -gt 0) { Write-Host (' ' * $done) -BackgroundColor Green -NoNewline }
    if ($done -lt $width) { Write-Host (' ' * ($width - $done)) -BackgroundColor DarkGray -NoNewline }
    Write-Host (' ' + $label) -ForegroundColor White -NoNewline
}

function Clear-HerdProgress {
    [CmdletBinding()]
    param()

    $redirected = $true
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    if (-not $redirected) { Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline }
}

function Test-HerdAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Confirm-HerdChange {
    # Says what a step will change, then asks Y/N. Only Y goes on.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $What)

    Write-HerdWarning "This step changes the PC: $What"
    $answer = Read-Host '  Go ahead? (Y/N)'
    $ok = $answer -match '^\s*[Yy]'
    Add-HerdLog ('Asked: {0} -> {1}' -f $What, $(if ($ok) { 'yes' } else { 'no' }))
    return $ok
}

function Invoke-HerdSteps {
    <#
    .SYNOPSIS
        Runs the steps in order, read-only ones first. Each step is a hashtable:
          Name     what the step does, in plain words
          Changes  $null for a read-only step, or a sentence saying what it changes
          Run      a scriptblock; it returns a short summary, or throws on failure
        Returns one result per step (Name, Status, Summary, Seconds).
        In Background Mode nothing is asked: a change step runs only with -Go YES.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [hashtable[]] $Steps)

    $ordered = @($Steps | Where-Object { -not $_.Changes }) + @($Steps | Where-Object { $_.Changes })
    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $step = $ordered[$i]
        Write-HerdProgress -Text ('Step {0} of {1}' -f ($i + 1), $ordered.Count) -Percent (100.0 * $i / $ordered.Count)
        $started = [datetime]::UtcNow
        $status = 'Done'; $summary = ''
        if ($step.Changes) {
            Clear-HerdProgress
            if (-not $PSCmdlet.ShouldProcess($step.Name, $step.Changes)) { $status = 'Skipped'; $summary = 'not run (-WhatIf)' }
            elseif ($script:HerdBackground) {
                if ($script:HerdGo -cne 'YES') { $status = 'Skipped'; $summary = 'Background Mode: needs -Go YES' }
                else { Add-HerdLog ('Background Mode, -Go YES: {0}' -f $step.Changes) }
            }
            elseif (-not (Confirm-HerdChange -What $step.Changes)) { $status = 'Skipped'; $summary = 'you said no' }
        }
        if ($status -eq 'Done') {
            try { $summary = [string](& $step.Run) }
            catch { $status = 'Failed'; $summary = @($_.Exception.Message -split "`r?`n")[0] }
        }
        $seconds = ([datetime]::UtcNow - $started).TotalSeconds
        Clear-HerdProgress
        $line = Get-HerdStatusLine -Status $status -Step ('{0} of {1}: {2}' -f ($i + 1), $ordered.Count, $step.Name) -Summary (Protect-HerdText $summary) -Seconds $seconds
        Add-HerdLog $line
        $colors = @{ Done = 'Green'; Skipped = 'Yellow'; Failed = 'Red' }
        Write-HerdLine $line $colors[$status]
        $results.Add([pscustomobject]@{ Name = $step.Name; Status = $status; Summary = $summary; Seconds = $seconds })
    }
    Write-HerdProgress -Text 'Finished' -Percent 100
    Clear-HerdProgress
    return , $results.ToArray()
}

function Save-HerdLog {
    # The log stays on this PC. Returns its path, or nothing if it could not be written.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Name)

    $folder = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AutoFixer\OneOff'
    $safe = ($Name -replace '[^A-Za-z0-9-]', '-')
    $path = Join-Path $folder ('{0}-{1:yyyyMMdd-HHmmss}Z.log' -f $safe, [datetime]::UtcNow)
    try {
        # The log is written even under -WhatIf: it records what was (not) done.
        New-Item -ItemType Directory -Path $folder -Force -WhatIf:$false | Out-Null
        Set-Content -Path $path -Value $script:HerdLog -Encoding UTF8 -WhatIf:$false
        return $path
    }
    catch {
        Write-HerdWarning ('Could not save the log to {0}: {1}' -f $folder, $_.Exception.Message)
        return $null
    }
}

function Get-HerdResultLines {
    # The RESULT block: counts, then one line per step that did not finish. Masked.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()] [object[]] $Results = @(), [AllowEmptyString()] [string] $LogPath)

    $count = { param($s) @($Results | Where-Object Status -eq $s).Count }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Done {0}   Skipped {1}   Failed {2}   (of {3} steps)' -f (& $count 'Done'), (& $count 'Skipped'), (& $count 'Failed'), $Results.Count))
    foreach ($r in @($Results | Where-Object Status -ne 'Done')) {
        $lines.Add(('{0}: {1} - {2}' -f $r.Status.ToUpperInvariant(), $r.Name, $r.Summary))
    }
    if ($LogPath) { $lines.Add(('Log: {0}' -f $LogPath)) }
    return , @($lines | ForEach-Object { Protect-HerdText $_ })
}


# ------------------------------------------------------- this script's helpers ---
$script:StoreApps = @()
$script:StoreStartUtc = [datetime]::UtcNow
$script:StoreScanStarted = $false

function ConvertTo-StoreAppName {
    # 'Installation Failure: ... error 0x80073D02: 9NBLGGH4R32N-Microsoft.GamingApp.'
    # -> 'Microsoft.GamingApp'. The 12-character Store id in front is dropped.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Message)

    if (-not $Message -or $Message -notmatch ':\s*(?<name>[^:]+?)\s*\.?\s*$') { return '' }
    $name = $Matches['name'].Trim().TrimEnd('.')
    $name = $name -replace '^[0-9A-Z]{12}-', ''
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]*$') { return '' }
    return $name
}

function Get-StoreStuckApp {
    # From Windows Update events (Id 20 = failed, Id 19 = installed), the apps whose
    # update failed with 0x80073D02 and has not installed since. Oldest failure first.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()] [object[]] $Events = @())

    $byName = @{}
    foreach ($e in $Events) {
        $name = ConvertTo-StoreAppName -Message ([string]$e.Message)
        if (-not $name) { continue }
        $key = $name.ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) {
            $byName[$key] = [pscustomobject]@{ Name = $name; Failures = 0; FirstFail = $null; LastFail = $null; LastInstalled = $null }
        }
        $app = $byName[$key]
        $when = [datetime]$e.TimeCreated
        if ([int]$e.Id -eq 20 -and [string]$e.Message -match '0x80073D02') {
            $app.Failures++
            if ($null -eq $app.FirstFail -or $when -lt $app.FirstFail) { $app.FirstFail = $when }
            if ($null -eq $app.LastFail -or $when -gt $app.LastFail) { $app.LastFail = $when }
        }
        elseif ([int]$e.Id -eq 19) {
            if ($null -eq $app.LastInstalled -or $when -gt $app.LastInstalled) { $app.LastInstalled = $when }
        }
    }
    $stuck = @($byName.Values | Where-Object { $_.Failures -gt 0 -and ($null -eq $_.LastInstalled -or $_.LastInstalled -lt $_.LastFail) })
    return , @($stuck | Sort-Object FirstFail)
}

function Test-StoreSystemPackage {
    # Windows' own parts (system-signed, frameworks, can't-remove) are never touched.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [object] $Package)

    if ([string]$Package.SignatureKind -eq 'System') { return $true }
    if ($Package.PSObject.Properties['IsFramework'] -and [bool]$Package.IsFramework) { return $true }
    if ($Package.PSObject.Properties['NonRemovable'] -and [bool]$Package.NonRemovable) { return $true }
    return $false
}

function Get-StoreProtectedProcessId {
    # This script's own process and every parent above it (for example Windows
    # Terminal), so the script never closes the window it runs in.
    [CmdletBinding()]
    [OutputType([int[]])]
    param([int] $SelfId, [AllowEmptyCollection()] [object[]] $Processes = @())

    $parentOf = @{}
    foreach ($p in $Processes) { $parentOf[[int]$p.ProcessId] = [int]$p.ParentProcessId }
    $ids = New-Object System.Collections.ArrayList
    $id = $SelfId
    while ($id -gt 0 -and -not $ids.Contains($id) -and $ids.Count -lt 64) {
        [void]$ids.Add($id)
        if (-not $parentOf.ContainsKey($id)) { break }
        $id = $parentOf[$id]
    }
    return , [int[]]$ids.ToArray()
}

function Select-StoreAppProcess {
    # The processes started from an app's install folder, minus the protected ones.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyString()] [string] $InstallLocation,
        [AllowEmptyCollection()] [object[]] $Processes = @(),
        [AllowEmptyCollection()] [int[]] $ProtectedIds = @()
    )

    if (-not $InstallLocation) { return , @() }
    $folder = $InstallLocation.TrimEnd('\') + '\'
    $hits = @($Processes | Where-Object {
            $_.ExecutablePath -and ([string]$_.ExecutablePath).StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) -and
            ($ProtectedIds -notcontains [int]$_.ProcessId)
        })
    return , $hits
}

function Get-StoreCloseAction {
    # What to do with an open app. Ask: someone is at the keyboard.
    # WarnThenForce: Background Mode with -Go YES, and the user can be warned.
    # Skip: Background Mode without a way to warn the user (never close unwarned).
    [CmdletBinding()]
    [OutputType([string])]
    param([bool] $Background, [string] $Go, [bool] $CanWarn)

    if (-not $Background) { return 'Ask' }
    if ($Go -cne 'YES') { return 'Skip' }
    if ($CanWarn) { return 'WarnThenForce' }
    return 'Skip'
}

function Get-StoreWarningText {
    # The pop-up the signed-in user sees before a force close. Plain ASCII.
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]] $AppNames, [int] $Seconds)

    $list = ($AppNames | Sort-Object -Unique) -join ', '
    return ('Auto-Fixer: {0} will be closed in {1} seconds to finish a Microsoft Store update. ' +
        'Save your work now. Anything not saved in these apps will be lost.') -f $list, $Seconds
}

function Get-StoreMsgPath {
    # msg.exe shows a pop-up in each signed-in session. A 32-bit RMM agent sees it
    # through Sysnative. Windows Home has no msg.exe: then this returns nothing.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($dir in @('Sysnative', 'System32')) {
        $path = Join-Path $env:SystemRoot ('{0}\msg.exe' -f $dir)
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Wait-StoreSecond {
    # Waits with the themed bar. Stops early when -Until returns true (checked every
    # -Every seconds). Returns true if -Until came true.
    [CmdletBinding()]
    [OutputType([bool])]
    param([int] $Seconds, [string] $Text, [scriptblock] $Until, [int] $Every = 1)

    for ($s = 0; $s -lt $Seconds; $s++) {
        Write-HerdProgress -Text $Text -Percent (100.0 * $s / [math]::Max(1, $Seconds))
        if ($Until -and ($s % [math]::Max(1, $Every)) -eq 0 -and (& $Until)) { Clear-HerdProgress; return $true }
        Start-Sleep -Seconds 1
    }
    Clear-HerdProgress
    if ($Until) { return [bool](& $Until) }
    return $false
}

function Get-StoreUpdateEvent {
    # Windows Update install events (19 installed, 20 failed) from the System log.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([datetime] $Since)

    try {
        $filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 20; StartTime = $Since }
        return , @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return , @() }
        throw
    }
}

function Get-StoreAppLine {
    # One line per app for the screen and log. App names only, no user or PC names.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()] [object[]] $Apps = @())

    return , @($Apps | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Status })
}

function Close-StoreAppInteractive {
    # Someone is at the keyboard: gentle close first, then a force close only after
    # a red warning and a second Y/N. Returns true if the app is closed.
    [CmdletBinding()]
    [OutputType([bool])]
    param([object] $App)

    $ids = @($App.Processes | ForEach-Object { [int]$_.ProcessId })
    $alive = { @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0 }
    if (-not (Confirm-HerdChange -What ('Close {0} gently, like pressing its X. It may ask you to save.' -f $App.Name))) { return $false }
    foreach ($id in $ids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p) { [void]$p.CloseMainWindow() }
    }
    if (Wait-StoreSecond -Seconds 15 -Text ('Closing ' + $App.Name) -Until { -not (& $alive) }) { return $true }
    Write-HerdFailure ('{0} is still open. FORCE CLOSE WARNING: anything not saved in {0} will be LOST.' -f $App.Name)
    if (-not (Confirm-HerdChange -What ('FORCE close {0}. Unsaved work in it is lost.' -f $App.Name))) { return $false }
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    [void](Wait-StoreSecond -Seconds 5 -Text ('Closing ' + $App.Name) -Until { -not (& $alive) })
    return -not (& $alive)
}

# Dot-sourced (tests): load the functions only, run nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

# --------------------------------------------------------- this script's steps ---
$isSystem = $false
try { $isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { $isSystem = $false }

$Steps = @(
    @{ Name = 'Find Store apps whose update was blocked'; Changes = $null; Run = {
            $events = Get-StoreUpdateEvent -Since ([datetime]::Now.AddDays(-$Days))
            $script:StoreApps = @(Get-StoreStuckApp -Events $events)
            foreach ($a in $script:StoreApps) {
                $a | Add-Member -NotePropertyName Package -NotePropertyValue $null
                $a | Add-Member -NotePropertyName Version -NotePropertyValue $null
                $a | Add-Member -NotePropertyName Processes -NotePropertyValue @()
                $a | Add-Member -NotePropertyName Closed -NotePropertyValue $false
                $a | Add-Member -NotePropertyName Status -NotePropertyValue 'still waiting'
            }
            if ($script:StoreApps.Count -eq 0) { return ('none in the last {0} days: nothing to retry' -f $Days) }
            '{0} app(s) still waiting: {1}' -f $script:StoreApps.Count, (($script:StoreApps | ForEach-Object Name) -join ', ')
        }
    }
    @{ Name = 'Match them to installed apps and find open ones'; Changes = $null; Run = {
            if ($script:StoreApps.Count -eq 0) { return 'nothing to match' }
            $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop)
            $protected = Get-StoreProtectedProcessId -SelfId $PID -Processes $procs
            foreach ($a in $script:StoreApps) {
                $pkg = @(Get-AppxPackage -AllUsers -Name $a.Name -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Version } -Descending)[0]
                if (-not $pkg) { $a.Status = 'skipped: not installed now'; continue }
                if (Test-StoreSystemPackage -Package $pkg) { $a.Status = 'skipped: part of Windows itself'; continue }
                $a.Package = $pkg
                $a.Version = [version]$pkg.Version
                $all = @(Select-StoreAppProcess -InstallLocation $pkg.InstallLocation -Processes $procs)
                $a.Processes = @(Select-StoreAppProcess -InstallLocation $pkg.InstallLocation -Processes $procs -ProtectedIds $protected)
                if ($all.Count -gt $a.Processes.Count) {
                    $a.Status = 'skipped: this script runs inside it'
                    Write-HerdWarning ('{0} is the window this script runs in, so it is not closed. Update it later from the Store.' -f $a.Name)
                }
            }
            $open = @($script:StoreApps | Where-Object { $_.Processes.Count -gt 0 })
            if ($open.Count -gt 0) { Write-HerdWarning ('Open now: {0}. The next step closes them (asks first).' -f (($open | ForEach-Object Name) -join ', ')) }
            '{0} open, {1} closed' -f $open.Count, (@($script:StoreApps | Where-Object { $_.Package }).Count - $open.Count)
        }
    }
    @{ Name = 'Close the open apps'; Changes = 'closes the Store apps listed above. A force close loses unsaved work in them; a warning comes first.'; Run = {
            $open = @($script:StoreApps | Where-Object { $_.Processes.Count -gt 0 })
            if ($open.Count -eq 0) { return 'none open' }
            $msg = Get-StoreMsgPath
            $action = Get-StoreCloseAction -Background $script:HerdBackground -Go $script:HerdGo -CanWarn ([bool]$msg)
            if ($action -eq 'Skip') {
                foreach ($a in $open) { $a.Status = 'skipped: open, and the user could not be warned' }
                Write-HerdWarning 'Could not warn the signed-in user (no msg.exe on this Windows edition), so no app was closed.'
                return 'skipped: no way to warn the user'
            }
            if ($action -eq 'WarnThenForce') {
                $names = @($open | ForEach-Object Name)
                $text = Get-StoreWarningText -AppNames $names -Seconds $WarnSeconds
                Write-HerdWarning ('FORCE CLOSE in {0} s: {1}. The user was warned by a pop-up. Unsaved work in them will be lost.' -f $WarnSeconds, ($names -join ', '))
                & $msg '*' ('/TIME:{0}' -f $WarnSeconds) $text
                if ($LASTEXITCODE -ne 0) {
                    foreach ($a in $open) { $a.Status = 'skipped: open, and the warning pop-up failed' }
                    throw ('msg.exe exit {0}: the warning could not be shown, so nothing was closed' -f $LASTEXITCODE)
                }
                [void](Wait-StoreSecond -Seconds $WarnSeconds -Text 'User saves work')
                foreach ($a in $open) {
                    foreach ($p in $a.Processes) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue }
                }
                [void](Wait-StoreSecond -Seconds 3 -Text 'Closing apps')
                foreach ($a in $open) {
                    $left = @($a.Processes | Where-Object { Get-Process -Id ([int]$_.ProcessId) -ErrorAction SilentlyContinue })
                    $a.Closed = ($left.Count -eq 0)
                    if (-not $a.Closed) { $a.Status = 'failed: still open after force close' }
                }
            }
            else {
                foreach ($a in $open) {
                    $a.Closed = Close-StoreAppInteractive -App $a
                    if (-not $a.Closed) { $a.Status = 'skipped: left open' }
                }
            }
            '{0} of {1} closed' -f @($open | Where-Object Closed).Count, $open.Count
        }
    }
    @{ Name = 'Ask Microsoft Store to install app updates'; Changes = 'starts a Store app update check. INTERNET: downloads from Microsoft Store servers.'; Run = {
            if (@($script:StoreApps | Where-Object { $_.Package }).Count -eq 0) { return 'nothing to retry' }
            $script:StoreStartUtc = [datetime]::UtcNow
            try {
                $cim = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop
                $r = $cim | Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop
                if ($r.ReturnValue -ne 0) { throw ('UpdateScanMethod returned {0}' -f $r.ReturnValue) }
                $script:StoreScanStarted = $true
                return 'Store update check started (device management bridge)'
            }
            catch {
                $why = @($_.Exception.Message -split "`r?`n")[0]
                if ($script:HerdBackground) {
                    $who = $(if ($isSystem) { 'as SYSTEM' } else { 'not as SYSTEM (run it from the RMM tool as SYSTEM)' })
                    throw ('the Store update check failed {0}: {1}' -f $who, $why)
                }
                Add-HerdLog ('Device management bridge refused ({0}); opening the Store page instead.' -f $why)
                Start-Process 'ms-windows-store://downloadsandupdates'
                $script:StoreScanStarted = $true
                Write-HerdWarning 'Microsoft Store is open on Downloads. Press "Get updates" there, then come back here.'
                return 'Store Downloads page opened: press Get updates'
            }
        }
    }
)

$CheckSteps = @(
    @{ Name = 'Check which apps updated'; Changes = $null; Run = {
            $todo = @($script:StoreApps | Where-Object { $_.Package -and $_.Status -eq 'still waiting' })
            if ($todo.Count -eq 0) { return 'nothing to check' }
            if (-not $script:StoreScanStarted) { return 'not checked: the update check did not run' }
            $check = {
                $installed = @(Get-StoreUpdateEvent -Since $script:StoreStartUtc.ToLocalTime() | Where-Object Id -eq 19)
                foreach ($a in @($todo | Where-Object Status -eq 'still waiting')) {
                    $now = @(Get-AppxPackage -AllUsers -Name $a.Name -ErrorAction SilentlyContinue | ForEach-Object { [version]$_.Version } | Sort-Object -Descending)[0]
                    $seen = @($installed | Where-Object { (ConvertTo-StoreAppName -Message $_.Message) -eq $a.Name })
                    if (($now -and $now -gt $a.Version) -or $seen.Count -gt 0) { $a.Status = 'updated' }
                }
                @($todo | Where-Object Status -eq 'still waiting').Count -eq 0
            }
            [void](Wait-StoreSecond -Seconds $WaitSeconds -Text 'Waiting for updates' -Until $check -Every 15)
            foreach ($line in (Get-StoreAppLine -Apps $todo)) { Add-HerdLog $line; Write-HerdLine ('  ' + $line) 'White' }
            '{0} of {1} updated' -f @($todo | Where-Object Status -eq 'updated').Count, $todo.Count
        }
    }
)
if (-not $script:HerdBackground) {
    # Reopening starts the app in the signed-in person's session: never in Background Mode.
    $CheckSteps += @{ Name = 'Reopen the apps that were closed'; Changes = 'opens again the apps this script closed.'; Run = {
            $closed = @($script:StoreApps | Where-Object Closed)
            if ($closed.Count -eq 0) { return 'none were closed' }
            foreach ($a in $closed) {
                $appId = @((Get-AppxPackageManifest -Package $a.Package.PackageFullName).Package.Applications.Application)[0].Id
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\{0}!{1}' -f $a.Package.PackageFamilyName, $appId)
            }
            '{0} reopened' -f $closed.Count
        }
    }
}

Write-HerdHeader -Title $script:HerdTitle -Technician:$Technician -Lines @(
    'Store app updates that failed because the app was open (0x80073D02).'
    'Read-only checks run first. Anything that changes this PC asks you first.'
    'Made by the Herd of Helpers for raven575.'
)
if ($script:HerdBackground) {
    Write-HerdWarning 'Background Mode: nothing will be asked. Change steps run only with -Go YES.'
    if ($script:HerdGo -ceq 'YES') { Write-HerdWarning ('Open Store apps get a pop-up warning, then are FORCE-CLOSED after {0} s. Unsaved work in them is lost.' -f $WarnSeconds) }
}
Add-HerdLog ('Started {0}; admin: {1}; SYSTEM: {2}; background: {3}' -f $script:HerdTitle, (Test-HerdAdmin), $isSystem, $script:HerdBackground)
if (-not (Test-HerdAdmin)) { Write-HerdWarning 'Not running as administrator: some steps may be skipped or fail.' }

$results = @(Invoke-HerdSteps -Steps $Steps) + @(Invoke-HerdSteps -Steps $CheckSteps)
$failed = @($results | Where-Object Status -eq 'Failed')
$logPath = Save-HerdLog -Name $script:HerdTitle
Write-Host ''
$lines = @(Get-HerdResultLines -Results $results -LogPath $logPath)
if ($script:StoreApps.Count -gt 0) { $lines = @(Get-StoreAppLine -Apps $script:StoreApps) + $lines }
Write-HerdHeader -Title 'Result' -Technician:$Technician -Lines $lines
if ($failed.Count -gt 0) { Write-HerdFailure ('{0} of {1} step(s) failed. See the lines above.' -f $failed.Count, $results.Count) }
else { Write-HerdLine (' ALL {0} STEP(S) FINISHED ' -f $results.Count) 'Black' 'Green' }
exit ([int]($failed.Count -gt 0))
