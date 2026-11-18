# Local administrator account: create one, or reset a local account's password, so
# nobody is locked out before a PC leaves Azure AD or a domain. Technician mode only.
# Passwords go from a hidden prompt straight to Windows; they are never shown, saved
# or logged. The Windows cmdlets are injected so the tests touch no real accounts.

# Administrators by its well-known SID, so it works on Windows in any language.
$script:AfAdminsSid = 'S-1-5-32-544'

function Test-AfLocalUserName {
    # Windows' rules for a local account name: 1 to 20 characters, none of these.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Name)
    return ($Name -match '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$' -and $Name.Trim() -eq $Name -and $Name -notmatch '^\.+$')
}

function Get-AfLocalAccount {
    <#
    .SYNOPSIS
        Local user accounts with Name, Enabled, Admin (in Administrators) and BuiltIn
        (the built-in Administrator, SID ending -500).
    #>
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name 'Get-LocalUser' -ErrorAction SilentlyContinue)) {
        throw 'The local account cmdlets are only in Windows PowerShell 5.1. Start Auto-Fixer with AutoFix.bat.'
    }
    $admins = @(Get-LocalGroupMember -SID $script:AfAdminsSid -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.SID })
    foreach ($u in @(Get-LocalUser)) {
        [pscustomobject]@{
            Name    = $u.Name
            Enabled = [bool]$u.Enabled
            Admin   = ($admins -contains [string]$u.SID)
            BuiltIn = ([string]$u.SID -match '-500$')
        }
    }
}

function Invoke-AfLocalAccountCommand {
    # Runs one local account cmdlet, with a plain message on PowerShell 7.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, [hashtable] $Parameters = @{})

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw ('{0} is only in Windows PowerShell 5.1. Start Auto-Fixer with AutoFix.bat.' -f $Name)
    }
    return (& $Name @Parameters -ErrorAction Stop)
}

function Test-AfKeyboard {
    <#
    .SYNOPSIS
        True when someone can type at this console. False for a script run by an RMM
        tool, a scheduled task or any run with redirected input: there a password
        would have to come from a file or a pipe, so the local admin tools stop.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
    catch { return $false }
}

function Confirm-AfLocalAdminRestorePoint {
    <#
    .SYNOPSIS
        Offers a restore point before an account change. When Windows cannot make
        one, it shows a warning and goes on: the tech decides at the Y/N that
        follows (raven575 2026-11-18 16:19 UTC: warn, never stop the tech).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ReadKey,
        [Parameter(Mandatory)] [scriptblock] $RestorePoint,
        [Parameter(Mandatory)] $Log
    )
    Write-Host ''
    if ((Read-AfYesNo -Prompt 'Create a restore point first?' -ReadKey $ReadKey) -ne $true) {
        Write-AfToolLog $Log 'Restore point: not asked for'
        return
    }
    Write-Host '  Creating a restore point...' -ForegroundColor DarkGray
    $point = $null
    try { $point = & $RestorePoint }
    catch { $point = [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
    if ($point.Ok) {
        Write-Host '  Restore point created.' -ForegroundColor Green
        Write-AfToolLog $Log 'Restore point: created'
        return
    }
    Write-Host ('  WARNING  No restore point: {0}' -f $point.Reason) -ForegroundColor Yellow
    Write-Host '  You can still go on. The next question asks before anything changes.' -ForegroundColor Yellow
    Write-AfToolLog $Log ('Restore point: WARNING, not created. {0}' -f $point.Reason)
}

function Read-AfNewPassword {
    <#
    .SYNOPSIS
        Asks for a password twice in hidden prompts, up to 3 tries. Returns it as a
        SecureString, or $null when the user gives up. The two copies are compared
        in memory only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ReadSecret,
        [int] $Tries = 3
    )
    for ($i = 1; $i -le $Tries; $i++) {
        $first = & $ReadSecret 'New password (hidden; Enter = cancel)'
        if (-not $first -or $first.Length -eq 0) { return $null }
        $second = & $ReadSecret 'Type it again'
        $same = $second -and ([Net.NetworkCredential]::new('', $first).Password -ceq [Net.NetworkCredential]::new('', $second).Password)
        if ($same) { return $first }
        Write-Host '  The two passwords are not the same.' -ForegroundColor Yellow
        if ($i -lt $Tries) { Write-Host ('  Try again ({0} left).' -f ($Tries - $i)) -ForegroundColor Yellow }
    }
    Write-Host ('  {0} tries used.' -f $Tries) -ForegroundColor Yellow
    return $null
}

function Format-AfAccountNote {
    # " (admin, built-in)" and the like, for one account line.
    param([Parameter(Mandatory)] $Account)
    $notes = @()
    if ($Account.Admin) { $notes += 'admin' } else { $notes += 'not admin' }
    if ($Account.BuiltIn) { $notes += 'built-in' }
    if (-not $Account.Enabled) { $notes += 'turned off' }
    return (' ({0})' -f ($notes -join ', '))
}

function Read-AfAccountPick {
    <#
    .SYNOPSIS
        Numbered list of accounts: a number picks one, S shows the real names on this
        screen only (raven575 2026-10-30), Esc cancels. Returns the account or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Accounts,
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] $Redactor,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [bool] $ShowReal = $false
    )
    $list = @($Accounts | Select-Object -First 9)
    $real = $ShowReal
    $unknown = 0
    while ($true) {
        Write-Host ''
        Write-Host ('  {0}' -f $Prompt) -ForegroundColor White
        for ($i = 0; $i -lt $list.Count; $i++) {
            $name = $list[$i].Name
            if (-not $real) { $name = Protect-AfText -Redactor $Redactor -Text $name }
            Write-Host ('  {0}  {1}{2}' -f ($i + 1), $name, (Format-AfAccountNote $list[$i]))
        }
        if ($Accounts.Count -gt 9) { Write-Host '  (first 9 shown)' -ForegroundColor DarkGray }
        if (-not $real) { Write-Host '  S  Show real names on this screen' }
        Write-Host '  Esc = cancel' -ForegroundColor DarkGray
        $key = [string](& $ReadKey)
        $number = 0
        if ([int]::TryParse($key, [ref]$number) -and $number -ge 1 -and $number -le $list.Count) { return $list[$number - 1] }
        if ($key -ieq 'S' -and -not $real) { $real = $true; continue }
        if ($key -eq 'Escape' -or $key -eq [string][char]27 -or $key -ieq 'B') { return $null }
        $unknown++
        if ($unknown -ge 2) { return $null }
        Write-Host '  Command unknown. Press a number, S or Esc.' -ForegroundColor Yellow
    }
}

function Invoke-AfLocalAdminTool {
    <#
    .SYNOPSIS
        Technician mode: lists the local accounts, then creates a new local admin
        or changes a local account's password, each after a restore point offer and
        a Y/N. -Action Create or Change skips the C/R/M choice (main menu items).
        Stops with no keyboard, since a password is only ever typed into a hidden
        prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [scriptblock] $ReadSecret = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) -AsSecureString },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [scriptblock] $GetAccounts = { Get-AfLocalAccount },
        [scriptblock] $Account = { param($Name, $Parameters) Invoke-AfLocalAccountCommand -Name $Name -Parameters $Parameters },
        $Redactor = (New-AfRedactor),
        [ValidateSet('Menu', 'Create', 'Change')] [string] $Action = 'Menu',
        [bool] $HasKeyboard = (Test-AfKeyboard),
        [scriptblock] $RestorePoint = { New-AfRestorePoint -Description 'Auto-Fixer: before a local admin account change' }
    )

    $title = @{ Menu = 'Local admin account'; Create = 'Create local admin and set password'; Change = 'Change local admin password' }[$Action]
    Write-Host ''
    Write-Host ('  {0}' -f $title) -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat.' -ForegroundColor Yellow; return }
    if (-not $HasKeyboard) {
        Write-Host '  No keyboard here (a script run by a remote tool, SYSTEM task or redirected input).' -ForegroundColor Yellow
        Write-Host '  A password is only ever typed into a hidden prompt, so nothing was changed.' -ForegroundColor Yellow
        Write-Host '  Open a console in the remote tool''s Background Mode session and start AutoFix.bat there.' -ForegroundColor Yellow
        return
    }
    $accounts = @(& $GetAccounts)
    Add-AfRedactionName -Redactor $Redactor -Names @($accounts | ForEach-Object Name)
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }

    Write-Host '  Local accounts on this PC:'
    if (-not $accounts.Count) { Write-Host '    (none found)' -ForegroundColor Yellow }
    foreach ($a in $accounts) { Write-Host ('    {0}{1}' -f (& $show $a.Name), (Format-AfAccountNote $a)) }
    if ($Action -eq 'Create') { $key = 'C' }
    elseif ($Action -eq 'Change') { $key = 'R' }
    else {
        Write-Host ''
        Write-Host '  C  Create a local admin and set its password'
        Write-Host '  R  Change a local account''s password'
        Write-Host '  M  Make a local account an admin'
        Write-Host '  Esc = back' -ForegroundColor DarkGray
        $key = ([string](& $ReadKey)).ToUpperInvariant()
        if ($key -notin 'C', 'R', 'M') { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
    }
    Write-Host ''
    $what = @{
        C = 'This step creates a new local account, adds it to Administrators and sets the password you type.'
        R = 'This step sets a new password on the local account you pick, and offers to turn it on if it is off.'
        M = 'This step adds the local account you pick to Administrators.'
    }[$key]
    Write-Host ('  {0}' -f $what) -ForegroundColor White
    Write-Host '  Nothing changes until you press Y.' -ForegroundColor White

    $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'localadmin' -Redactor $Redactor -Task 'local admin account'
    if ($key -eq 'C') {
        $check = {
            param($Text)
            if (-not (Test-AfLocalUserName $Text)) { 'A name has 1 to 20 characters and none of \ / [ ] : ; | = , + * ? < > " @.' }
            elseif (@($accounts | Where-Object { $_.Name -ieq $Text }).Count) { 'That account already exists. Use R to reset its password.' }
        }
        $name = Read-AfCheckedText -ReadText $ReadText -Prompt 'Name for the new local admin (Enter = cancel)' -Check $check
        if (-not $name) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
        Add-AfRedactionName -Redactor $Redactor -Names @($name)
        Write-Host '  Choose a password you will remember. It is not saved anywhere by Auto-Fixer.' -ForegroundColor White
        $password = Read-AfNewPassword -ReadSecret $ReadSecret
        if (-not $password) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled at the password'; return }
        Confirm-AfLocalAdminRestorePoint -ReadKey $ReadKey -RestorePoint $RestorePoint -Log $log
        if ((Read-AfYesNo -Prompt ('Create the local admin {0}?' -f (& $show $name)) -ReadKey $ReadKey) -ne $true) {
            Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return
        }
        try {
            $null = & $Account 'New-LocalUser' @{ Name = $name; Password = $password; Description = 'Local admin made with Auto-Fixer' }
            $null = & $Account 'Add-LocalGroupMember' @{ SID = $script:AfAdminsSid; Member = $name }
            Write-Host ('  OK      Created the local admin {0}. Sign in with .\{0} and that password.' -f (& $show $name)) -ForegroundColor Green
            Write-AfToolLog $log ('Outcome   : created local admin {0}' -f $name)
        }
        catch {
            Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red
            Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message)
        }
        return
    }

    if ($key -eq 'M') {
        $others = @($accounts | Where-Object { -not $_.Admin })
        if (-not $others.Count) { Write-Host '  Every local account is already an admin. Nothing was changed.' -ForegroundColor Green; Write-AfToolLog $log 'Outcome   : nothing to add'; return }
        $target = Read-AfAccountPick -Accounts $others -Prompt 'Pick the account to make an admin:' -Redactor $Redactor -ReadKey $ReadKey -ShowReal ([bool]$Settings.ShowSensitive)
        if (-not $target) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
        Confirm-AfLocalAdminRestorePoint -ReadKey $ReadKey -RestorePoint $RestorePoint -Log $log
        if ((Read-AfYesNo -Prompt ('Add {0} to Administrators?' -f (& $show $target.Name)) -ReadKey $ReadKey) -ne $true) {
            Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return
        }
        try {
            $null = & $Account 'Add-LocalGroupMember' @{ SID = $script:AfAdminsSid; Member = $target.Name }
            Write-Host ('  OK      {0} is now an admin.' -f (& $show $target.Name)) -ForegroundColor Green
            Write-AfToolLog $log ('Outcome   : added {0} to Administrators' -f $target.Name)
            if (-not $target.Enabled -and (Read-AfYesNo -Prompt 'This account is turned off. Turn it on?' -ReadKey $ReadKey) -eq $true) {
                $null = & $Account 'Enable-LocalUser' @{ Name = $target.Name }
                Write-Host '  OK      Turned on.' -ForegroundColor Green
                Write-AfToolLog $log 'Enabled   : yes'
            }
        }
        catch {
            Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red
            Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message)
        }
        return
    }

    # From the main menu item, only accounts in Administrators: it is the local admin password.
    $pickFrom = $accounts
    $pickPrompt = 'Pick the account to change:'
    if ($Action -eq 'Change') {
        $pickFrom = @($accounts | Where-Object { $_.Admin })
        $pickPrompt = 'Pick the local admin to change:'
        if (-not $pickFrom.Count) {
            Write-Host '  There is no local admin account. Use "Create local admin and set password". Nothing was changed.' -ForegroundColor Yellow
            Write-AfToolLog $log 'Outcome   : no local admin to change'
            return
        }
    }
    $target = Read-AfAccountPick -Accounts $pickFrom -Prompt $pickPrompt -Redactor $Redactor -ReadKey $ReadKey -ShowReal ([bool]$Settings.ShowSensitive)
    if (-not $target) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
    $password = Read-AfNewPassword -ReadSecret $ReadSecret
    if (-not $password) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled at the password'; return }
    Confirm-AfLocalAdminRestorePoint -ReadKey $ReadKey -RestorePoint $RestorePoint -Log $log
    if ((Read-AfYesNo -Prompt ('Set the new password for {0}?' -f (& $show $target.Name)) -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return
    }
    try {
        $null = & $Account 'Set-LocalUser' @{ Name = $target.Name; Password = $password }
        Write-Host ('  OK      New password set for {0}.' -f (& $show $target.Name)) -ForegroundColor Green
        Write-AfToolLog $log ('Outcome   : password changed for {0}' -f $target.Name)
        if (-not $target.Enabled -and (Read-AfYesNo -Prompt 'This account is turned off. Turn it on?' -ReadKey $ReadKey) -eq $true) {
            $null = & $Account 'Enable-LocalUser' @{ Name = $target.Name }
            Write-Host '  OK      Turned on.' -ForegroundColor Green
            Write-AfToolLog $log 'Enabled   : yes'
        }
    }
    catch {
        Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red
        Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message)
    }
}

function Invoke-AfLocalAdminMenu {
    # Local admin account, opened from the main menu in Technician mode (key L), so a
    # tech in a remote tool's Background Mode session gets to it in two keys.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default Create and Change script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        # Each is called with the settings.
        [scriptblock] $Create = { param($S) Invoke-AfLocalAdminTool -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey -Action Create },
        [scriptblock] $Change = { param($S) Invoke-AfLocalAdminTool -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey -Action Change }
    )

    $info = @('Passwords are typed into hidden prompts only. They are never shown, saved or logged.')
    $items = @(
        @{ Key = 'C'; Label = '&Create local admin and set password'; Tags = '[ADMIN] [CHG]' }
        @{ Key = 'W'; Label = 'Change local admin pass&word'; Tags = '[ADMIN] [CHG]'; Divider = $true }
        @{ Key = 'B'; Label = '&Back' }
        @{ Key = 'Q'; Label = '&Quit' }
    )
    $itemInfo = @{
        C = @('Creates a new local account, adds it to Administrators and sets its password, so nobody is locked out.', '', 'Changes system: YES', 'Restore point offer, then Y/N.')
        W = @('Sets a new password on a local admin account you pick, and offers to turn it on if it is off.', '', 'Changes system: YES', 'Restore point offer, then Y/N.')
        B = @('Back to the main menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    while ($true) {
        $choice = Select-AfMenuItem -Title 'Local admin account' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        try { if ($choice -eq 'C') { & $Create $Settings } else { & $Change $Settings } }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        Write-Host ''
        Write-Host '  Press any key to return to Local admin account.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
