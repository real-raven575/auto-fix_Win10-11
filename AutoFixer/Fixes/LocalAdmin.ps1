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
        Technician mode: lists the local administrators, then creates a new local
        admin or resets a local account's password, each after a Y/N.
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
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Local admin account' -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat.' -ForegroundColor Yellow; return }
    $accounts = @(& $GetAccounts)
    Add-AfRedactionName -Redactor $Redactor -Names @($accounts | ForEach-Object Name)
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }

    Write-Host '  Local accounts on this PC:'
    if (-not $accounts.Count) { Write-Host '    (none found)' -ForegroundColor Yellow }
    foreach ($a in $accounts) { Write-Host ('    {0}{1}' -f (& $show $a.Name), (Format-AfAccountNote $a)) }
    Write-Host ''
    Write-Host '  C  Create a new local admin'
    Write-Host '  R  Reset a local account''s password'
    Write-Host '  M  Make a local account an admin'
    Write-Host '  Esc = back' -ForegroundColor DarkGray
    $key = ([string](& $ReadKey)).ToUpperInvariant()
    if ($key -notin 'C', 'R', 'M') { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }

    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'localadmin.log' -Redactor $Redactor -Task 'local admin account'
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

    $target = Read-AfAccountPick -Accounts $accounts -Prompt 'Pick the account to reset:' -Redactor $Redactor -ReadKey $ReadKey -ShowReal ([bool]$Settings.ShowSensitive)
    if (-not $target) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
    $password = Read-AfNewPassword -ReadSecret $ReadSecret
    if (-not $password) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled at the password'; return }
    if ((Read-AfYesNo -Prompt ('Set the new password for {0}?' -f (& $show $target.Name)) -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return
    }
    try {
        $null = & $Account 'Set-LocalUser' @{ Name = $target.Name; Password = $password }
        Write-Host ('  OK      New password set for {0}.' -f (& $show $target.Name)) -ForegroundColor Green
        Write-AfToolLog $log ('Outcome   : password reset for {0}' -f $target.Name)
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
