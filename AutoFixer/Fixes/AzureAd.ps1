# Leave Azure AD (Entra ID). Technician mode only. Microsoft documents dsregcmd /leave
# for hybrid joined PCs (domain + Azure AD); a PC joined only to Azure AD is unjoined in
# Settings > Accounts > Access work or school, so Auto-Fixer opens that page instead of
# scripting it, and checks dsregcmd /status again afterwards.

function Get-AfDeviceJoinState {
    <#
    .SYNOPSIS
        Read-only: AzureAd and Domain (both [bool]) from dsregcmd /status, or $null
        when Windows cannot tell.
    #>
    [CmdletBinding()]
    param([scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList })
    try { $r = & $RunTool -Name 'dsregcmd.exe' -ArgumentList @('/status') }
    catch { return $null }
    if ($r.ExitCode -ne 0) { return $null }
    $text = @($r.Lines) -join "`n"
    $aad = [regex]::Match($text, '(?im)^\s*AzureAdJoined\s*:\s*(YES|NO)\b')
    if (-not $aad.Success) { return $null }
    $domain = [regex]::Match($text, '(?im)^\s*DomainJoined\s*:\s*(YES|NO)\b')
    return [pscustomobject]@{ AzureAd = ($aad.Groups[1].Value -eq 'YES'); Domain = ($domain.Success -and $domain.Groups[1].Value -eq 'YES') }
}

function Invoke-AfAzureAdLeave {
    <#
    .SYNOPSIS
        Technician mode: takes this PC off Azure AD after warnings. Hybrid PCs use
        dsregcmd /debug /leave; Azure AD only PCs need a working local admin first,
        then the Settings page. Always checks the result again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [scriptblock] $GetJoinState = { Get-AfDeviceJoinState },
        [scriptblock] $GetAccounts = { Get-AfLocalAccount },
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList },
        [scriptblock] $OpenSettings = { Start-Process 'ms-settings:workplace' },
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Leave Azure AD (Entra ID)' -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat.' -ForegroundColor Yellow; return }
    $state = & $GetJoinState
    if ($null -eq $state) { Write-Host '  Windows could not say whether this PC is on Azure AD. Nothing was changed.' -ForegroundColor Yellow; return }
    if (-not $state.AzureAd) { Write-Host '  This PC is not joined to Azure AD. Nothing to do.' -ForegroundColor Green; return }
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }

    $ready = @()
    if (-not $state.Domain) {
        # After the unjoin only local accounts can sign in, so one must work first.
        $accounts = @(& $GetAccounts)
        Add-AfRedactionName -Redactor $Redactor -Names @($accounts | ForEach-Object Name)
        $ready = @($accounts | Where-Object { $_.Admin -and $_.Enabled -and -not $_.BuiltIn })
        if (-not $ready.Count) {
            Write-Host '  There is no local admin account to sign in with after this.' -ForegroundColor Yellow
            Write-Host '  Make one first: (U)ser: local admin in this menu. Nothing was changed.' -ForegroundColor Yellow
            return
        }
    }

    Write-Host ''
    Write-Host '  WARNING: on a company PC this can cut off work email, OneDrive and company' -ForegroundColor Red
    Write-Host '  apps. The company''s device management (Intune) may wipe work data or join' -ForegroundColor Red
    Write-Host '  the PC again. Azure AD accounts cannot sign in after this; only local' -ForegroundColor Red
    Write-Host '  accounts can. Ask IT first on a work PC.' -ForegroundColor Red
    if ((Read-AfYesNo -Prompt 'Leave Azure AD. Are you sure?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }

    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'azuread.log' -Redactor $Redactor -Task 'leave Azure AD'
    if ($state.Domain) {
        Write-AfToolLog $log 'Join type : hybrid (domain + Azure AD)'
        $r = & $RunTool -Name 'dsregcmd.exe' -ArgumentList @('/debug', '/leave')
        Write-AfToolLog $log ('dsregcmd  : /debug /leave, exit code {0}' -f $r.ExitCode)
        Write-Host '  The domain may register this PC again on its own; ask IT to turn off' -ForegroundColor Yellow
        Write-Host '  automatic registration if it should stay off Azure AD.' -ForegroundColor Yellow
    }
    else {
        Write-AfToolLog $log 'Join type : Azure AD only'
        $check = { param($Text) if (-not @($ready | Where-Object { $_.Name -ieq $Text }).Count) { 'That is not an enabled local admin on this PC.' } }
        $name = Read-AfCheckedText -ReadText $ReadText -Prompt 'Local admin you will sign in with afterwards (Enter = cancel)' -Check $check
        if (-not $name) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
        Write-Host ('  Sign in with .\{0} after the restart.' -f (Protect-AfText -Redactor $screen -Text $name)) -ForegroundColor White
        Write-Host ''
        Write-Host '  Windows does this part itself. In the Settings page that opens now:' -ForegroundColor White
        Write-Host '    1. Click the work or school account, then Disconnect.' -ForegroundColor White
        Write-Host '    2. Confirm, and give the local admin name and password when asked.' -ForegroundColor White
        Write-Host '    3. Come back here before you restart.' -ForegroundColor White
        try { & $OpenSettings } catch { Write-Host '  Open it yourself: Settings > Accounts > Access work or school.' -ForegroundColor Yellow }
        Write-AfToolLog $log 'Settings  : Access work or school opened'
        Write-Host '  Press any key when you are done in Settings.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }

    $after = & $GetJoinState
    if ($after -and -not $after.AzureAd) {
        Write-Host '  OK      The Azure AD join is removed. Restart to finish.' -ForegroundColor Green
        Write-AfToolLog $log 'Outcome   : left Azure AD'
    }
    else {
        Write-Host '  Still joined to Azure AD. Nothing else was changed.' -ForegroundColor Yellow
        Write-AfToolLog $log 'Outcome   : still joined'
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
}
