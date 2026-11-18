# Windows tweaks (main menu, Technician mode; raven575 2026-11-12): small per-user
# settings, each with an undo.
#
# Classic right-click menu: Windows 11 shows a short right-click menu with "Show more
# options" at the bottom. An EMPTY default value under this per-user CLSID key makes
# File Explorer show the full Windows 10 style menu again. Removing the key undoes it.
#   - Windows 11 only (build 22000 or later); Windows 10 already has the full menu
#   - per user (HKCU): no admin rights needed, other accounts on the PC are not changed
#   - shows the change first and asks Y/N; File Explorer restarts only after its own Y/N
#   - read back after the change, so the screen and log say what really happened

$script:AfClassicMenuKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
$script:AfClassicMenuText = 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
$script:AfWindows11Build = 22000

function Get-AfWindowsBuild {
    # The Windows build number (19045 = Windows 10 22H2, 22000 and up = Windows 11); 0 if unknown.
    [CmdletBinding()]
    [OutputType([int])]
    param()

    try {
        $build = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction Stop).CurrentBuildNumber
        return [int]$build
    }
    catch { return 0 }
}

function Test-AfClassicMenuKey {
    # $true when the classic menu key is there with an empty default value. Read-only.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Root = $script:AfClassicMenuKey)

    $path = Join-Path $Root 'InprocServer32'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    # GetValue gives $null when no default value is set; Explorer needs it set and empty.
    return ((Get-Item -LiteralPath $path -ErrorAction Stop).GetValue('', $null) -eq '')
}

function Set-AfClassicMenuKey {
    # On: adds the key with an empty default value. Off: removes the whole CLSID key,
    # which only exists for this tweak. Errors are thrown to the caller.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [bool] $On,
        [string] $Root = $script:AfClassicMenuKey
    )

    $path = Join-Path $Root 'InprocServer32'
    if ($On) {
        if ($PSCmdlet.ShouldProcess($path, 'Add with an empty default value')) {
            if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -Path $path -Force -ErrorAction Stop }
            Set-ItemProperty -LiteralPath $path -Name '(default)' -Value '' -ErrorAction Stop
        }
    }
    elseif ((Test-Path -LiteralPath $Root) -and $PSCmdlet.ShouldProcess($Root, 'Remove')) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
    }
}

function Get-AfClassicMenuState {
    # NotWin11 (Windows 10 or build unknown), On (classic menu) or Off (Windows 11 menu). Read-only.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [scriptblock] $GetBuild = { Get-AfWindowsBuild },
        [scriptblock] $TestKey = { Test-AfClassicMenuKey }
    )

    if ([int](& $GetBuild) -lt $script:AfWindows11Build) { return 'NotWin11' }
    if (& $TestKey) { return 'On' }
    return 'Off'
}

function Test-AfShellUserMatch {
    <#
    .SYNOPSIS
        $true when File Explorer in this session runs as the same Windows account as
        Auto-Fixer, $false when it does not (an administrator signed in over a standard
        user, so HKCU would be the wrong person's), $null when it can't tell. Read-only;
        compares account SIDs and never shows or logs a name.
    #>
    [CmdletBinding()]
    param()

    try {
        $mine = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $session = (Get-Process -Id $PID).SessionId
        $shell = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop | Where-Object { $_.SessionId -eq $session })
        if (-not $shell.Count) { return $null }
        $owner = Invoke-CimMethod -InputObject $shell[0] -MethodName GetOwnerSid -ErrorAction Stop
        if (-not $owner.Sid) { return $null }
        return ($owner.Sid -eq $mine)
    }
    catch { return $null }
}

function Restart-AfExplorer {
    <#
    .SYNOPSIS
        Restarts File Explorer in this session only, so a new right-click menu shows.
        Windows normally starts it again by itself; if not, it is started here. Open
        File Explorer windows close. Returns $true when Explorer is running again.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([int] $WaitSeconds = 5)

    if (-not $PSCmdlet.ShouldProcess('File Explorer', 'Restart')) { return $false }
    $session = (Get-Process -Id $PID).SessionId
    $mine = { @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) }
    & $mine | Stop-Process -Force -ErrorAction Stop
    for ($i = 0; $i -lt ($WaitSeconds * 4); $i++) {
        Start-Sleep -Milliseconds 250
        if ((& $mine).Count) { return $true }
    }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction Stop
    Start-Sleep -Seconds 2
    return [bool](& $mine).Count
}

function Invoke-AfClassicMenuTweak {
    <#
    .SYNOPSIS
        Switches the right-click menu between the Windows 11 and the classic (Windows 10
        style) menu, whichever it is not now. Shows the change, asks Y/N, checks the
        result and logs it. Returns Tag (OK, FAILED, CANCELLED, SKIPPED) and Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $GetBuild = { Get-AfWindowsBuild },
        [scriptblock] $TestKey = { Test-AfClassicMenuKey },
        # Called with $true (classic menu on) or $false (undo).
        [scriptblock] $SetKey = { param([bool] $On) Set-AfClassicMenuKey -On $On },
        [scriptblock] $SameUser = { Test-AfShellUserMatch },
        [scriptblock] $RestartExplorer = { Restart-AfExplorer },
        $Redactor = (New-AfRedactor)
    )

    $build = [int](& $GetBuild)
    Write-Host ''
    if ($build -lt $script:AfWindows11Build) {
        if ($build -gt 0) {
            Write-Host ('  This PC runs Windows 10 (build {0}). Windows 10 already shows the full' -f $build) -ForegroundColor Yellow
            Write-Host '  right-click menu, so there is nothing to change. Nothing was changed.' -ForegroundColor Yellow
            return [pscustomobject]@{ Tag = 'SKIPPED'; Detail = ('Windows 10 (build {0}): already the classic menu.' -f $build) }
        }
        Write-Host '  Could not read the Windows version, so nothing was changed.' -ForegroundColor Yellow
        return [pscustomobject]@{ Tag = 'SKIPPED'; Detail = 'Windows version unknown.' }
    }

    $same = & $SameUser
    if ($same -eq $false) {
        Write-Host '  Auto-Fixer is running as a different Windows account from the one signed in' -ForegroundColor Yellow
        Write-Host '  (an administrator account was used to start it). This setting belongs to each' -ForegroundColor Yellow
        Write-Host '  account, so it would change the wrong one. Nothing was changed.' -ForegroundColor Yellow
        Write-Host '  Start AutoFix.bat while signed in as the person who wants the change.' -ForegroundColor Yellow
        return [pscustomobject]@{ Tag = 'SKIPPED'; Detail = 'Running as a different account from the signed-in user.' }
    }

    $wasOn = [bool](& $TestKey)
    $turnOn = -not $wasOn
    $now = @{ $true = 'classic (Windows 10 style, full menu)'; $false = 'Windows 11 (short menu with "Show more options")' }
    Write-Host ('  Right-click menu now: {0}' -f $now[$wasOn]) -ForegroundColor White
    Write-Host ('  After this:           {0}' -f $now[$turnOn]) -ForegroundColor White
    Write-Host ''
    if ($turnOn) { Write-Host '  This adds one registry key, with an empty default value, for your account only:' }
    else { Write-Host '  This removes the registry key Auto-Fixer (or another tool) added, for your account only:' }
    Write-Host ('    {0}' -f $script:AfClassicMenuText) -ForegroundColor DarkGray
    Write-Host '  No admin rights needed. Other accounts on this PC are not changed.'
    Write-Host '  To switch back, run this again.'
    if ($same -ne $true) { Write-Host '  Could not check which account File Explorer runs as; the change is for the account running Auto-Fixer.' -ForegroundColor Yellow }
    Write-Host ''
    $prompt = @{ $true = 'Switch to the classic right-click menu?'; $false = 'Switch back to the Windows 11 right-click menu?' }[$turnOn]
    if ((Read-AfYesNo -Prompt $prompt -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return [pscustomobject]@{ Tag = 'CANCELLED'; Detail = 'Nothing was changed.' }
    }

    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'tweaks' -Redactor $Redactor -Task 'classic right-click menu'
    $log = { param([string] $Text) Write-AfToolLog $toolLog $Text }
    & $log ('Mode      : {0}' -f $Settings.Mode)
    & $log ('Windows   : build {0}' -f $build)
    & $log ('Before    : {0}' -f @{ $true = 'classic menu'; $false = 'Windows 11 menu' }[$wasOn])
    & $log ('Change    : {0} {1}' -f @{ $true = 'add'; $false = 'remove' }[$turnOn], $script:AfClassicMenuText)

    $tag = 'OK'
    try {
        & $SetKey $turnOn
        $isOn = [bool](& $TestKey)
        if ($isOn -ne $turnOn) {
            $tag = 'FAILED'
            $detail = 'The change did not stick: the key reads back as before.'
        }
        else { $detail = @{ $true = 'Classic right-click menu is on.'; $false = 'Windows 11 right-click menu is back.' }[$turnOn] }
    }
    catch {
        $tag = 'FAILED'
        $detail = 'Registry change failed: {0}' -f $_.Exception.Message
    }
    & $log ('{0,-7}{1}' -f $tag, $detail)

    $color = @{ $true = 'Green'; $false = 'Red' }[$tag -eq 'OK']
    Write-Host ''
    Write-Host ('  {0,-8}{1}' -f $tag, $detail) -ForegroundColor $color
    if ($tag -eq 'OK') {
        Write-Host ''
        Write-Host '  File Explorer must restart to show it. Open File Explorer windows will close;' -ForegroundColor Yellow
        Write-Host '  nothing else changes.' -ForegroundColor Yellow
        if ((Read-AfYesNo -Prompt 'Restart File Explorer now?' -ReadKey $ReadKey) -eq $true) {
            try {
                if (& $RestartExplorer) {
                    Write-Host '  File Explorer restarted. Right-click the desktop to check.' -ForegroundColor Green
                    & $log 'OK     File Explorer restarted.'
                }
                else {
                    Write-Host '  File Explorer did not come back by itself. Press Ctrl+Shift+Esc, then File > Run new task > explorer.' -ForegroundColor Red
                    & $log 'FAILED File Explorer did not start again.'
                }
            }
            catch {
                Write-Host ('  Restart failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
                & $log ('FAILED File Explorer restart: {0}' -f $_.Exception.Message)
            }
        }
        else {
            Write-Host '  It shows after you sign out and back in, or restart the PC.' -ForegroundColor Yellow
            & $log 'Skipped: File Explorer restart (user said No).'
        }
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return [pscustomobject]@{ Tag = $tag; Detail = $detail }
}

function Invoke-AfTweaksMenu {
    # Windows tweaks, opened from the main menu in Technician mode.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default ClassicMenu script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $GetState = { Get-AfClassicMenuState },
        # Called with the settings.
        [scriptblock] $ClassicMenu = { param($S) $null = Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey }
    )

    $info = @('Small Windows settings for the account running Auto-Fixer. Each one shows the change first, asks Y/N, and can be undone the same way.')
    while ($true) {
        $state = [string](& $GetState)
        $label = @{ On = 'Classic right-&click menu: On'; Off = 'Classic right-&click menu: Off'; NotWin11 = 'Classic right-&click menu (Windows 11 only)' }[$state]
        $items = @(
            @{ Key = 'C'; Label = $label; Tags = '[CHG]'; Divider = $true }
            @{ Key = 'B'; Label = '&Back' }
            @{ Key = 'Q'; Label = '&Quit' }
        )
        $itemInfo = @{
            C = @('Windows 11: show the full Windows 10 style right-click menu, without "Show more options". Run it again to undo.', '', 'Changes system: YES (your account only)', 'Admin: not needed', 'Asks Y/N first.')
            B = @('Back to the main menu.')
            Q = @('Closes Auto-Fixer. Asks first.')
        }
        $choice = Select-AfMenuItem -Title 'Windows tweaks' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        try { & $ClassicMenu $Settings }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        Write-Host ''
        Write-Host '  Press any key to return to Windows tweaks.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
