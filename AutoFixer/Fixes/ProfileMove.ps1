# Move a user profile to another account on the same PC (raven575 2026-10-31, plan
# profile-move-plan-2026-10-30.md). Technician mode only. Uses Windows' own
# Win32_UserProfile.ChangeOwner, so nothing is copied or downloaded:
#   - a profile that is in use, or belongs to the account running Auto-Fixer, is refused
#   - a restore point and a reg export of the profile's ProfileList key come first
#   - an existing profile of the new owner is never deleted
#   - names are redacted on screen (unless Show sensitive is on) and always in profile.log

$script:AfProfileListKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

function Get-AfUserProfile {
    <#
    .SYNOPSIS
        Read-only: the user profiles on this PC with Sid, Name (DOMAIN\user, or the
        folder name when Windows cannot resolve it), Path, Loaded and LastUse.
    #>
    [CmdletBinding()]
    param()
    @(Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special = FALSE' -ErrorAction Stop | ForEach-Object {
            $name = Split-Path -Leaf $_.LocalPath
            try { $name = ([Security.Principal.SecurityIdentifier]$_.SID).Translate([Security.Principal.NTAccount]).Value } catch { $null = $_ }
            [pscustomobject]@{ Sid = $_.SID; Name = $name; Path = $_.LocalPath; Loaded = [bool]$_.Loaded; LastUse = $_.LastUseTime }
        })
}

function Resolve-AfAccountSid {
    # The SID of an account name such as .\admin or CONTOSO\user, or $null when Windows does not know it.
    param([Parameter(Mandatory)] [string] $Name)
    $account = $Name
    if ($account.StartsWith('.\')) { $account = '{0}\{1}' -f $env:COMPUTERNAME, $account.Substring(2) }
    try { return ([Security.Principal.NTAccount]$account).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { return $null }
}

function Write-AfProfileMoveHint {
    # Shown after Leave domain, Leave Azure AD and Join: the move needs the old account signed out.
    param([string] $From = 'your old account', [string] $To = 'your new account')
    Write-Host ''
    Write-Host ('  To keep {0}''s files and settings for {1}: after the restart, sign in' -f $From, $To) -ForegroundColor White
    Write-Host '  as a different admin and use Network and domain > P Move a user profile.' -ForegroundColor White
}

function Invoke-AfProfileMove {
    <#
    .SYNOPSIS
        Technician mode: hands one user profile to another account with
        Win32_UserProfile.ChangeOwner, after a restore point, a registry backup, a
        red warning and Y/N.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ReadText', Justification = 'Passed to the local admin screen by the default LocalAdmin script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [string] $CurrentSid = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value),
        [scriptblock] $GetProfiles = { Get-AfUserProfile },
        [scriptblock] $GetAccounts = { Get-AfLocalAccount },
        [scriptblock] $ResolveSid = { param($Name) Resolve-AfAccountSid -Name $Name },
        [scriptblock] $LocalAdmin = { Invoke-AfLocalAdminTool -Settings $Settings -OutputRoot $OutputRoot -ReadKey $ReadKey -ReadText $ReadText },
        [scriptblock] $RestorePoint = { New-AfRestorePoint -Description 'Auto-Fixer: before moving a user profile' },
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList },
        [scriptblock] $ChangeOwner = { param($Sid, $NewSid, $Flags) (Invoke-CimMethod -Query ("SELECT * FROM Win32_UserProfile WHERE SID = '{0}'" -f $Sid) -MethodName ChangeOwner -Arguments @{ NewOwnerSID = $NewSid; Flags = [uint32]$Flags } -ErrorAction Stop).ReturnValue },
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Move a user profile' -ForegroundColor Cyan
    if ($Settings.Mode -ne 'Technician') { Write-Host '  This is in Technician mode only.' -ForegroundColor Yellow; return }
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat.' -ForegroundColor Yellow; return }
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }
    Write-Host '  Hands a profile (Desktop, Documents, browser and app settings) to another'
    Write-Host '  account on this PC. Nothing is copied or downloaded.'

    $profiles = @(& $GetProfiles)
    Add-AfRedactionName -Redactor $Redactor -Names @($profiles | ForEach-Object { $_.Name; ($_.Name -split '\\')[-1] })
    if (-not $profiles.Count) { Write-Host '  No user profiles were found.' -ForegroundColor Yellow; return }
    $list = @($profiles | Select-Object -First 9 | ForEach-Object {
            $note = @()
            if ($_.Loaded) { $note += 'in use' }
            if ($_.Sid -eq $CurrentSid) { $note += 'you' }
            if ($_.LastUse) { $note += ('last used {0:yyyy-MM-dd}' -f $_.LastUse) }
            [pscustomobject]@{ Name = $_.Name; Profile = $_; Note = $note -join ', ' }
        })

    # Old profile: picked by number, S shows real names on that screen only.
    $from = $null
    $real = [bool]$Settings.ShowSensitive
    for ($try = 1; $try -le 3 -and -not $from; $try++) {
        Write-Host ''
        Write-Host '  Pick the profile to move:' -ForegroundColor White
        for ($i = 0; $i -lt $list.Count; $i++) {
            $name = $list[$i].Name
            if (-not $real) { $name = Protect-AfText -Redactor $Redactor -Text $name }
            Write-Host ('  {0}  {1}  ({2})' -f ($i + 1), $name, $list[$i].Note)
        }
        if (-not $real) { Write-Host '  S  Show real names on this screen' }
        Write-Host '  Esc = cancel' -ForegroundColor DarkGray
        $key = [string](& $ReadKey)
        $number = 0
        if ($key -ieq 'S' -and -not $real) { $real = $true; $try--; continue }
        if ($key -eq 'Escape' -or $key -eq [string][char]27 -or $key -ieq 'B') { break }
        if (-not ([int]::TryParse($key, [ref]$number) -and $number -ge 1 -and $number -le $list.Count)) { Write-Host '  Command unknown. Press a number, S or Esc.' -ForegroundColor Yellow; continue }
        $p = $list[$number - 1].Profile
        if ($p.Sid -eq $CurrentSid) { Write-Host '  That is the account running Auto-Fixer. Sign in as a different admin first.' -ForegroundColor Yellow; continue }
        if ($p.Loaded) { Write-Host '  That profile is in use. Sign that account out, or restart, then try again.' -ForegroundColor Yellow; continue }
        $from = $p
    }
    if (-not $from) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }

    # New owner: a local account by number, N for a new local admin, or a typed name.
    $to = $null
    $toSid = $null
    while (-not $to) {
        $accounts = @(& $GetAccounts | Where-Object { $_.Enabled })
        Add-AfRedactionName -Redactor $Redactor -Names @($accounts | ForEach-Object Name)
        $local = @($accounts | Select-Object -First 8)
        Write-Host ''
        Write-Host '  Who gets it?' -ForegroundColor White
        for ($i = 0; $i -lt $local.Count; $i++) {
            $name = $local[$i].Name
            if (-not $real) { $name = Protect-AfText -Redactor $Redactor -Text $name }
            Write-Host ('  {0}  {1}{2}' -f ($i + 1), $name, (Format-AfAccountNote $local[$i]))
        }
        Write-Host '  N  Make a new local account first'
        Write-Host '  T  Type an account, such as CONTOSO\user'
        Write-Host '  Esc = cancel' -ForegroundColor DarkGray
        $key = [string](& $ReadKey)
        $number = 0
        if ([int]::TryParse($key, [ref]$number) -and $number -ge 1 -and $number -le $local.Count) { $to = '.\' + $local[$number - 1].Name }
        elseif ($key -ieq 'N') { $null = & $LocalAdmin; continue }
        elseif ($key -ieq 'T') {
            $to = Read-AfCheckedText -ReadText $ReadText -Prompt 'Account, such as CONTOSO\user (Enter = cancel)' -Check { param($t) if (-not (& $ResolveSid $t)) { 'Windows does not know that account.' } }
            if (-not $to) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
            Add-AfRedactionName -Redactor $Redactor -Names @($to, ($to -split '\\')[-1])
        }
        else { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
        $toSid = & $ResolveSid $to
        if (-not $toSid) { Write-Host '  Windows does not know that account. Nothing was changed.' -ForegroundColor Yellow; return }
        if ($toSid -eq $from.Sid) { Write-Host '  That account already owns this profile. Nothing was changed.' -ForegroundColor Yellow; return }
    }
    $fromName = & $show $from.Name
    $toName = & $show $to

    $flags = 0
    $existing = @($profiles | Where-Object Sid -EQ $toSid)
    if ($existing.Count) {
        Write-Host ''
        Write-Host ('  {0} already has a profile ({1}).' -f $toName, (& $show $existing[0].Path)) -ForegroundColor Yellow
        Write-Host '  Replacing sets it aside: it stays on disk, unused, and is never deleted.' -ForegroundColor Yellow
        if ((Read-AfYesNo -Prompt 'Replace it?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
        # 1 = ReplaceNewOwnerProfile only; DeleteReplacedProfile is never set.
        $flags = 1
    }

    Write-Host ''
    Write-Host ('  Moves {0} ({1}) to {2}.' -f $fromName, (& $show $from.Path), $toName) -ForegroundColor White
    Write-Host '  WARNING: Microsoft says some apps may need reinstalling or a new sign-in' -ForegroundColor Red
    Write-Host '  afterwards, and file permissions may need fixing. OneDrive and Outlook ask' -ForegroundColor Red
    Write-Host ('  you to sign in again. {0} will no longer have this profile.' -f $fromName) -ForegroundColor Red
    if ((Read-AfYesNo -Prompt 'Move this profile. Are you sure?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }

    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'profile.log' -Redactor $Redactor -Task 'move a user profile'
    Write-AfToolLog $log ('From      : {0} ({1})' -f $from.Name, $from.Path)
    Write-AfToolLog $log ('To        : {0}{1}' -f $to, @{ $true = ', replacing its profile'; $false = '' }[$flags -eq 1])

    # Backups first: a restore point (when System Protection is on) and the registry key.
    Write-Host '  Making a restore point...' -ForegroundColor DarkGray
    $point = & $RestorePoint
    if ($point.Ok) { Write-AfToolLog $log 'Backup    : restore point made' }
    else {
        Write-Host ('  No restore point: {0}' -f $point.Reason) -ForegroundColor Yellow
        Write-AfToolLog $log ('Backup    : no restore point, {0}' -f $point.Reason)
        if ((Read-AfYesNo -Prompt 'Continue without a restore point?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
    }
    $backup = Join-Path (Split-Path $log.Path) 'profilelist-backup.reg'
    $reg = & $RunTool 'reg.exe' @('export', ('{0}\{1}' -f $script:AfProfileListKey, $from.Sid), $backup, '/y')
    if ($reg.ExitCode -ne 0) {
        Write-Host '  FAILED  The registry backup did not work. Nothing was changed.' -ForegroundColor Red
        Write-AfToolLog $log ('Outcome   : FAILED, reg export exit code {0}' -f $reg.ExitCode)
        return
    }
    Write-AfToolLog $log 'Backup    : profilelist-backup.reg'

    try { $code = & $ChangeOwner $from.Sid $toSid $flags }
    catch { $code = $_.Exception.Message }
    if ("$code" -eq '0') {
        Write-Host ('  OK      {0} now opens this profile at its next sign-in.' -f $toName) -ForegroundColor Green
        Write-Host '  To undo, run Move again the other way.' -ForegroundColor DarkGray
        Write-AfToolLog $log 'Outcome   : moved'
    }
    else {
        Write-Host ('  FAILED  Windows said: {0}. Nothing was changed.' -f (& $show "$code")) -ForegroundColor Red
        Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $code)
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
}
