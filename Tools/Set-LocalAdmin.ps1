<#
.SYNOPSIS
    Creates a local admin account and sets its password, or changes a local admin's
    password, from a remote tool (RMM) with no keyboard, or at a console.
.DESCRIPTION
    Auto-Fixer Technician tool (raven575, 2026-11-18). HERD themed, like every Herd
    one-off script.
      1. Read-only: checks Windows PowerShell 5.1, administrator rights, the account
         name and the password source.
      2. Change: offers a restore point. If Windows cannot make one, a WARNING is
         shown and logged and the tool goes on (raven575: warn, never stop the tech).
      3. Change: -Action Create makes a new local account and adds it to
         Administrators. -Action Change sets a new password on an account that is
         already in Administrators, and turns it on if it is off.

    THE PASSWORD
      - With no keyboard (an RMM script, SYSTEM, a scheduled task) it comes ONLY
        from the environment variable AF_ADMIN_PASSWORD, which the RMM fills from
        its secure (masked) script variable. There is no -Password parameter, so
        it can never be typed on a command line.
      - At a console with no AF_ADMIN_PASSWORD, it is typed twice into hidden prompts.
      - It is read once into a SecureString and the variable is cleared from this
        process at once. It is never shown, logged, saved or put in the RESULT.

    Background Mode (no keyboard, or -Background) never asks: change steps run only
    with -Go YES. The log stays on this PC in %ProgramData%\AutoFixer\OneOff, with
    computer, user and account names masked.
.PARAMETER Action
    Create (new local admin) or Change (new password for an existing local admin).
.PARAMETER Name
    The local account name. Default: the environment variable AF_ADMIN_NAME. A name
    is not a secret, but it is masked in the log and RESULT anyway.
.PARAMETER Plain
    No colour: for screen readers, old consoles and copy-paste.
.PARAMETER Background
    Background Mode: never asks. Also on by itself when there is no keyboard.
.PARAMETER Go
    In Background Mode, change steps run only when this is exactly YES.
.NOTES
    HOW TO USE
      Needs:    Windows 10 or 11, Windows PowerShell 5.1 (powershell.exe, not pwsh),
                administrator or SYSTEM. No internet.
      RMM:      make a secure script variable, pass it to the script as the
                environment variable AF_ADMIN_PASSWORD, and AF_ADMIN_NAME (or -Name).
                Check that your RMM masks it in its output. Run as SYSTEM.
      Changes:  Create adds one local account to Administrators; undo it in Computer
                Management > Local Users and Groups (delete the account). Change sets
                a new password; the old one is not kept anywhere.
      Exit:     0 done, 1 missing or bad name or password, 2 not administrator or
                not Windows PowerShell 5.1, 3 Windows refused the change (its message
                is in the log), 4 Background Mode without -Go YES (nothing changed).
      Terms:    RMM = the remote management tool that runs scripts on customer PCs.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Tools\Set-LocalAdmin.ps1 -Action Create -Background -Go YES
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Tools\Set-LocalAdmin.ps1 -Action Change -Name helpdesk
#>
[CmdletBinding()]
param(
    [ValidateSet('Create', 'Change')] [string] $Action = 'Create',
    [string] $Name = $env:AF_ADMIN_NAME,
    [switch] $Plain,
    [switch] $Background,
    [string] $Go = ''
)

# Account names this run touches, masked as ACCOUNT-1 and on.
$script:SlaNames = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- shared look ---
$script:HerdTitle = 'Set local admin'
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
    # Masks this PC's computer, user and domain names, and the local account names
    # this script touches (ACCOUNT-1, ...), so a log or RESULT can be shared.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text)

    $masks = [ordered]@{ COMPUTERNAME = '<PC>'; USERDOMAIN = '<DOMAIN>'; USERNAME = '<USER>' }
    foreach ($name in $masks.Keys) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $value.Length -ge 2) { $Text = $Text -ireplace [regex]::Escape($value), $masks[$name] }
    }
    for ($i = 0; $i -lt $script:SlaNames.Count; $i++) {
        # Whole words only, so a short name such as IT does not eat parts of other words.
        $Text = $Text -ireplace ('(?<![\w-]){0}(?![\w-])' -f [regex]::Escape($script:SlaNames[$i])), ('<ACCOUNT-{0}>' -f ($i + 1))
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

# --------------------------------------------------------- local admin parts ---
# Administrators by its well-known SID, so it works on Windows in any language.
$script:SlaAdminsSid = 'S-1-5-32-544'
$script:SlaPasswordVariable = 'AF_ADMIN_PASSWORD'

# The Windows parts, swapped for fakes in the tests.
$script:SlaGetAccounts = {
    $admins = @(Get-LocalGroupMember -SID $script:SlaAdminsSid -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.SID })
    foreach ($u in @(Get-LocalUser -ErrorAction Stop)) {
        [pscustomobject]@{ Name = $u.Name; Enabled = [bool]$u.Enabled; Admin = ($admins -contains [string]$u.SID) }
    }
}
$script:SlaAccount = { param($Command, $Parameters) $null = & $Command @Parameters -ErrorAction Stop }
$script:SlaRestorePoint = {
    # Checkpoint-Computer only warns when Windows skips a point (24-hour limit), so
    # compare the newest point before and after.
    $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber | Select-Object -Last 1)
    Checkpoint-Computer -Description 'Auto-Fixer: before a local admin account change' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
    $after = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber | Select-Object -Last 1)
    if (-not $after.Count) { throw 'Windows made no restore point. System Protection may be off for drive C:.' }
    if ($before.Count -and $before[0].SequenceNumber -eq $after[0].SequenceNumber) { throw 'Windows skipped it: a restore point was already made in the last 24 hours.' }
}
$script:SlaReadSecret = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) -AsSecureString }
$script:SlaHasLocalAccounts = { [bool](Get-Command -Name 'New-LocalUser' -ErrorAction SilentlyContinue) }

function Test-SlaName {
    # Windows' rules for a local account name: 1 to 20 characters, none of these.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()] [string] $Name)

    return ($Name -match '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$' -and $Name.Trim() -eq $Name -and $Name -notmatch '^\.+$')
}

function Read-SlaPasswordVariable {
    <#
    .SYNOPSIS
        Reads AF_ADMIN_PASSWORD from this process once, as a SecureString, and clears
        the variable at once. Returns $null when it is not set.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([string] $Variable = $script:SlaPasswordVariable)

    $plain = [Environment]::GetEnvironmentVariable($Variable, 'Process')
    [Environment]::SetEnvironmentVariable($Variable, $null, 'Process')
    if ([string]::IsNullOrEmpty($plain)) { return $null }
    $secure = New-Object System.Security.SecureString
    foreach ($ch in $plain.ToCharArray()) { $secure.AppendChar($ch) }
    $plain = $null
    $secure.MakeReadOnly()
    return $secure
}

function Read-SlaHiddenPassword {
    # Twice into hidden prompts, up to 3 tries. $null when they never match.
    [CmdletBinding()]
    [OutputType([securestring])]
    param([int] $Tries = 3)

    for ($i = 1; $i -le $Tries; $i++) {
        $first = & $script:SlaReadSecret 'New password (hidden)'
        if (-not $first -or $first.Length -eq 0) { return $null }
        $second = & $script:SlaReadSecret 'Type it again'
        $same = $second -and ([Net.NetworkCredential]::new('', $first).Password -ceq [Net.NetworkCredential]::new('', $second).Password)
        if ($same) { return $first }
        Write-HerdWarning 'The two passwords are not the same.'
    }
    return $null
}

function Get-SlaExitCode {
    # One exit code for the run. Input and rights problems were found before the steps.
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyCollection()] [object[]] $Results = @())

    $main = @($Results | Where-Object { $_.Name -in 'Create the local admin', 'Set the new password' })
    if (@($main | Where-Object Status -eq 'Failed').Count) { return 3 }
    if (@($main | Where-Object Status -eq 'Skipped').Count) { return 4 }
    return 0
}

function Invoke-SetLocalAdmin {
    <#
    .SYNOPSIS
        The whole run. Returns the exit code: 0 done, 1 bad input, 2 rights or shell,
        3 Windows refused, 4 needs -Go YES (or the tech said no).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Create', 'Change')] [string] $Action,
        [AllowEmptyString()] [string] $Name,
        [bool] $IsAdmin = (Test-HerdAdmin)
    )

    $what = @{ Create = 'Create local admin and set password'; Change = 'Change local admin password' }[$Action]
    Write-HerdHeader -Title $script:HerdTitle -Technician -Lines @(
        $what
        'The password is never shown, logged or saved.'
        'Each change asks first, or needs -Go YES in Background Mode.'
    )
    if ($script:HerdBackground) { Write-HerdWarning 'Background Mode: nothing will be asked. Change steps run only with -Go YES.' }
    Add-HerdLog ('Started {0}: {1}; admin: {2}; background: {3}' -f $script:HerdTitle, $Action, $IsAdmin, $script:HerdBackground)

    $stop = {
        param([int] $Code, [string] $Text)
        Write-HerdFailure ('Exit {0}: {1}' -f $Code, $Text)
        $null = Save-HerdLog -Name $script:HerdTitle
        return $Code
    }
    if (-not (& $script:SlaHasLocalAccounts)) { return (& $stop 2 'the local account commands are only in Windows PowerShell 5.1. Run it with powershell.exe.') }
    if (-not $IsAdmin) { return (& $stop 2 'this needs administrator rights or SYSTEM.') }
    if (-not (Test-SlaName $Name)) { return (& $stop 1 'no good account name. Give -Name or AF_ADMIN_NAME: 1 to 20 characters, none of \ / [ ] : ; | = , + * ? < > " @.') }
    $script:SlaNames.Add($Name)

    $accounts = @(& $script:SlaGetAccounts)
    $found = @($accounts | Where-Object { $_.Name -ieq $Name })
    if ($Action -eq 'Create' -and $found.Count) { return (& $stop 1 ('{0} already exists. Use -Action Change to set its password.' -f $Name)) }
    if ($Action -eq 'Change' -and -not $found.Count) { return (& $stop 1 ('{0} does not exist. Use -Action Create.' -f $Name)) }
    if ($Action -eq 'Change' -and -not $found[0].Admin) { return (& $stop 1 ('{0} is not in Administrators, so this tool does not change it.' -f $Name)) }

    # The password: the RMM's secure variable first, else hidden prompts at a console.
    $password = Read-SlaPasswordVariable
    $source = 'secure variable {0}' -f $script:SlaPasswordVariable
    if (-not $password -and -not $script:HerdBackground) { $password = Read-SlaHiddenPassword; $source = 'hidden prompt' }
    if (-not $password) {
        $why = 'no password. Set the RMM secure variable as the environment variable {0}.' -f $script:SlaPasswordVariable
        if (-not $script:HerdBackground) { $why = 'no matching password was typed.' }
        return (& $stop 1 $why)
    }
    Add-HerdLog ('Password  : given by {0} (not logged)' -f $source)

    $target = $Name
    $wasOff = ($found.Count -and -not $found[0].Enabled)
    $steps = @(
        @{ Name = 'Make a restore point'; Changes = 'asks Windows for a restore point before the account change'; Run = {
                try { & $script:SlaRestorePoint; 'created' }
                catch {
                    Write-HerdWarning ('No restore point: {0} Going on anyway.' -f @($_.Exception.Message -split "`r?`n")[0])
                    'not created (warning shown, going on)'
                }
            }
        }
    )
    if ($Action -eq 'Create') {
        $steps += @{ Name = 'Create the local admin'; Changes = ('creates the local account {0}, adds it to Administrators and sets the password' -f $target); Run = {
                & $script:SlaAccount 'New-LocalUser' @{ Name = $target; Password = $password; Description = 'Local admin made with Auto-Fixer'; PasswordNeverExpires = $true }
                & $script:SlaAccount 'Add-LocalGroupMember' @{ SID = $script:SlaAdminsSid; Member = $target }
                'created local admin {0}' -f $target
            }
        }
    }
    else {
        $steps += @{ Name = 'Set the new password'; Changes = ('sets a new password on the local admin {0}{1}' -f $target, $(if ($wasOff) { ' and turns the account on' } else { '' })); Run = {
                & $script:SlaAccount 'Set-LocalUser' @{ Name = $target; Password = $password }
                if ($wasOff) { & $script:SlaAccount 'Enable-LocalUser' @{ Name = $target }; 'changed password for {0} and turned it on' -f $target }
                else { 'changed password for {0}' -f $target }
            }
        }
    }
    try { $results = Invoke-HerdSteps -Steps $steps -WhatIf:$false }
    finally { $password.Dispose() }

    $code = Get-SlaExitCode -Results $results
    Add-HerdLog ('Exit code : {0}' -f $code)
    $logPath = Save-HerdLog -Name $script:HerdTitle
    Write-Host ''
    Write-HerdHeader -Title 'Result' -Technician -Lines (Get-HerdResultLines -Results $results -LogPath $logPath)
    $meaning = @{ 0 = 'done'; 3 = 'Windows refused the change (see the line above)'; 4 = 'nothing changed: Background Mode needs -Go YES, or you said no' }[$code]
    if ($code -eq 0) { Write-HerdLine ' DONE (exit 0) ' 'Black' 'Green' }
    else { Write-HerdFailure ('Exit {0}: {1}' -f $code, $meaning) }
    return $code
}

# Dot-sourced (tests): load the functions only, run nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

exit (Invoke-SetLocalAdmin -Action $Action -Name $Name)
