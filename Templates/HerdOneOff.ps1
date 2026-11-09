<#
.SYNOPSIS
    HERD themed one-off script template. Copy this file, rename it, and fill in
    the steps in $Steps at the bottom. Everything above that line is the shared look.
.DESCRIPTION
    Every one-off script the Herd writes, even a quick one, looks and behaves like
    Auto-Fixer (raven575, 2026-11-09):
      - the Auto-Fixer colours: a cyan frame (Standard) or orange (-Technician);
      - the progress bar: done cells Black on Green, the rest White on DarkGray;
      - highlighted warnings (Black on Yellow) and failures (White on DarkRed);
      - one result line per step: [done   ] [skipped] [failed ], like a scan;
      - safe by default: read-only steps run first, a step that changes the PC
        says what it will do and asks Y/N first, -WhatIf asks nothing and changes
        nothing;
      - a plain-text log on this PC only, in %ProgramData%\AutoFixer\OneOff.
    One file, nothing to install, Windows PowerShell 5.1 or PowerShell 7. The file
    stays pure ASCII (glyphs are built from code points) so 5.1 reads it correctly.
    It must pass .\Tools\Invoke-Lint.ps1 like the rest of the repo.
.PARAMETER Plain
    No colour: for screen readers, old consoles and copy-paste.
.PARAMETER Technician
    The orange Technician frame instead of the Standard cyan one.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\HerdOneOff.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Plain,
    [switch] $Technician
)

# ---------------------------------------------------------------- shared look ---
$script:HerdTitle = 'Herd one-off'          # Shown in the frame. Change per script.
$script:HerdPlain = [bool]$Plain -or [bool]$env:NO_COLOR
$script:HerdLog = New-Object System.Collections.Generic.List[string]
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

function Add-HerdLog {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $script:HerdLog.Add(('{0:yyyy-MM-dd HH:mm:ss}Z {1}' -f [datetime]::UtcNow, $Text))
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
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [hashtable[]] $Steps)

    $ordered = @($Steps | Where-Object { -not $_.Changes }) + @($Steps | Where-Object { $_.Changes })
    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $step = $ordered[$i]
        Write-HerdProgress -Text $step.Name -Percent (100.0 * $i / $ordered.Count)
        $started = [datetime]::UtcNow
        $status = 'Done'; $summary = ''
        if ($step.Changes) {
            Clear-HerdProgress
            if (-not $PSCmdlet.ShouldProcess($step.Name, $step.Changes)) { $status = 'Skipped'; $summary = 'not run (-WhatIf)' }
            elseif (-not (Confirm-HerdChange -What $step.Changes)) { $status = 'Skipped'; $summary = 'you said no' }
        }
        if ($status -eq 'Done') {
            try { $summary = [string](& $step.Run) }
            catch { $status = 'Failed'; $summary = @($_.Exception.Message -split "`r?`n")[0] }
        }
        $seconds = ([datetime]::UtcNow - $started).TotalSeconds
        Clear-HerdProgress
        $line = Get-HerdStatusLine -Status $status -Step $step.Name -Summary $summary -Seconds $seconds
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

# Dot-sourced (tests): load the functions only, run nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

# --------------------------------------------------------- this script's steps ---
# Replace these example steps. Read-only steps have Changes = $null.
$Steps = @(
    @{ Name = 'Read Windows version'; Changes = $null; Run = {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            '{0} build {1}' -f $os.Caption, $os.BuildNumber
        }
    }
    @{ Name = 'Check free space on C:'; Changes = $null; Run = {
            $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $gb = [math]::Round($d.FreeSpace / 1GB, 1)
            if ($gb -lt 10) { Write-HerdWarning "Only $gb GB free on C:" }
            '{0} GB free' -f $gb
        }
    }
)

Write-HerdHeader -Title $script:HerdTitle -Technician:$Technician -Lines @(
    'Read-only checks run first. Anything that changes this PC asks you first.'
    'Made by the Herd of Helpers for raven575.'
)
Add-HerdLog ('Started {0}; admin: {1}' -f $script:HerdTitle, (Test-HerdAdmin))
if (-not (Test-HerdAdmin)) { Write-HerdWarning 'Not running as administrator: some steps may be skipped or fail.' }

$results = Invoke-HerdSteps -Steps $Steps
$failed = @($results | Where-Object Status -eq 'Failed')
$logPath = Save-HerdLog -Name $script:HerdTitle
Write-Host ''
if ($failed.Count -gt 0) { Write-HerdFailure ('{0} of {1} step(s) failed. See the lines above.' -f $failed.Count, $results.Count) }
else { Write-HerdLine (' ALL {0} STEP(S) FINISHED ' -f $results.Count) 'Black' 'Green' }
if ($logPath) { Write-HerdLine ('  Log: {0}' -f $logPath) 'DarkGray' }
exit ([int]($failed.Count -gt 0))
