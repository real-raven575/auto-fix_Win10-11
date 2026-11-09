# Sign-in source check (raven575 2026-11-03): read-only, Technician mode, Network and
# domain menu key S. Answers "how does this PC sign people in?":
#   - the PC name and how it is joined (dsregcmd /status): on-prem AD, Entra ID
#     (Microsoft 365), hybrid (both), a work account only, or not joined
#   - what kind of account runs Auto-Fixer (domain, cloud or local)
#   - the domain controller that signed that account in (LOGONSERVER) and its IP
#   - the domain controller this PC uses now (nltest /dsgetdc:) and its IP
# Network: this network's DNS and domain controller only, and only on a domain PC.
# Names and IPs are redacted on screen (unless Show sensitive data is on) and always
# in the log.

# nltest exit codes seen when no domain controller answers, in plain words.
$script:AfNltestMeaning = @{
    0    = 'OK'
    1311 = 'no domain controller is available to sign in'
    1355 = 'the domain does not exist or no domain controller could be reached'
    1722 = 'the domain controller did not answer (RPC server unavailable)'
}

function ConvertFrom-AfDsregStatus {
    <#
    .SYNOPSIS
        Reads dsregcmd /status output into the fields this check uses. Missing
        fields are empty; YES/NO fields are upper case.
    #>
    [CmdletBinding()]
    param([string[]] $Lines = @())

    $result = [ordered]@{ AzureAdJoined = ''; DomainJoined = ''; EnterpriseJoined = ''; WorkplaceJoined = ''; DomainName = ''; TenantName = '' }
    foreach ($line in $Lines) {
        $m = [regex]::Match([string]$line, '^\s*([A-Za-z]+)\s*:\s*(.*?)\s*$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value
        foreach ($key in @($result.Keys)) {
            # The first value wins: the device section comes before the user section.
            if ($key -eq $name -and -not $result[$key]) {
                $value = $m.Groups[2].Value
                if ($key -like '*Joined') { $value = $value.ToUpperInvariant() }
                $result[$key] = $value
            }
        }
    }
    return [pscustomobject]$result
}

function Get-AfJoinType {
    <#
    .SYNOPSIS
        The join type from dsregcmd fields: Hybrid, OnPremAD, Entra, Workplace or
        Local, with a plain-words line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Status)

    $aad = $Status.AzureAdJoined -eq 'YES'
    $dom = $Status.DomainJoined -eq 'YES'
    if ($aad -and $dom) { return [pscustomobject]@{ Kind = 'Hybrid'; Text = 'Hybrid: on the on-prem domain and joined to Entra ID (Microsoft 365)' } }
    if ($dom) { return [pscustomobject]@{ Kind = 'OnPremAD'; Text = 'On-prem Active Directory only' } }
    if ($aad) { return [pscustomobject]@{ Kind = 'Entra'; Text = 'Entra ID (Microsoft 365) only: sign-in goes to Microsoft''s cloud' } }
    if ($Status.WorkplaceJoined -eq 'YES') { return [pscustomobject]@{ Kind = 'Workplace'; Text = 'Not joined: a work or school account is added, but sign-in uses this PC''s own accounts' } }
    return [pscustomobject]@{ Kind = 'Local'; Text = 'Not joined: sign-in uses this PC''s own (local) accounts' }
}

function ConvertFrom-AfNltestDc {
    <#
    .SYNOPSIS
        Reads nltest /dsgetdc: output: the domain controller's name and address
        (without the leading \\) and the domain name. Status is the error number
        from a "Status = 1355" line, or 0.
    #>
    [CmdletBinding()]
    param([string[]] $Lines = @())

    $result = [ordered]@{ Controller = ''; Address = ''; Domain = ''; Status = 0 }
    foreach ($line in $Lines) {
        $text = [string]$line
        if (-not $result.Controller -and $text -match '^\s*DC:\s*\\*(\S+)') { $result.Controller = $Matches[1] }
        elseif (-not $result.Address -and $text -match '^\s*Address:\s*\\*(\S+)') { $result.Address = $Matches[1] }
        elseif (-not $result.Domain -and $text -match '^\s*Dom Name:\s*(\S+)') { $result.Domain = $Matches[1] }
        elseif ($text -match '(?i)Status\s*=\s*(\d+)') { $result.Status = [int]$Matches[1] }
    }
    return [pscustomobject]$result
}

function Get-AfNltestMeaning {
    # Plain words for an nltest exit code or status number.
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Code)
    if ($script:AfNltestMeaning.ContainsKey($Code)) { return $script:AfNltestMeaning[$Code] }
    return 'see the nltest output in the log'
}

function Get-AfAccountKind {
    <#
    .SYNOPSIS
        What kind of account runs Auto-Fixer, from USERDOMAIN: Cloud (AzureAD),
        Local (the PC's own name) or Domain (anything else).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $UserDomain, [string] $ComputerName)
    if ($UserDomain -eq 'AzureAD') { return 'Cloud' }
    if (-not $UserDomain -or $UserDomain -eq $ComputerName) { return 'Local' }
    return 'Domain'
}

function Get-AfSignInFact {
    <#
    .SYNOPSIS
        Gathers the facts for the sign-in source check. Read-only. nltest and the DNS
        lookups run only when they can find something: nltest on a domain PC, the
        logon DC lookup when another computer signed the account in.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Environment = @{ ComputerName = $env:COMPUTERNAME; UserDomain = $env:USERDOMAIN; UserName = $env:USERNAME; LogonServer = $env:LOGONSERVER },
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList },
        [scriptblock] $Resolve = { param($Name) @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress }) }
    )

    $computer = [string]$Environment.ComputerName
    $facts = [ordered]@{
        ComputerName = $computer; UserDomain = [string]$Environment.UserDomain; UserName = [string]$Environment.UserName
        AccountKind = Get-AfAccountKind -UserDomain $Environment.UserDomain -ComputerName $computer
        Dsreg = ConvertFrom-AfDsregStatus; DsregExitCode = $null; DsregError = ''
        JoinType = $null
        LogonServer = ([string]$Environment.LogonServer).TrimStart('\'); LogonServerIp = @(); LogonServerError = ''
        Nltest = $null; NltestExitCode = $null; NltestLines = @(); NltestError = ''; NltestIp = @()
    }

    try {
        $r = & $RunTool -Name 'dsregcmd.exe' -ArgumentList @('/status')
        $facts.DsregExitCode = $r.ExitCode
        if ($r.ExitCode -eq 0) { $facts.Dsreg = ConvertFrom-AfDsregStatus -Lines $r.Lines }
        else { $facts.DsregError = ('dsregcmd /status ended with exit code {0}.' -f $r.ExitCode) }
    }
    catch { $facts.DsregError = ('dsregcmd /status could not run: {0}' -f $_.Exception.Message) }
    $facts.JoinType = Get-AfJoinType -Status $facts.Dsreg

    if ($facts.LogonServer -and $facts.LogonServer -ne $computer) {
        try { $facts.LogonServerIp = @(& $Resolve $facts.LogonServer) }
        catch { $facts.LogonServerError = 'DNS did not find its address.' }
    }

    if ($facts.Dsreg.DomainJoined -eq 'YES') {
        try {
            $r = & $RunTool -Name 'nltest.exe' -ArgumentList @('/dsgetdc:')
            $facts.NltestExitCode = $r.ExitCode
            $facts.NltestLines = @($r.Lines)
            $facts.Nltest = ConvertFrom-AfNltestDc -Lines $r.Lines
            $code = $r.ExitCode
            if ($facts.Nltest.Status) { $code = $facts.Nltest.Status }
            if ($r.ExitCode -ne 0 -or -not $facts.Nltest.Controller) { $facts.NltestError = ('nltest exit code {0}: {1}.' -f $code, (Get-AfNltestMeaning $code)) }
        }
        catch { $facts.NltestError = ('nltest could not run: {0}' -f $_.Exception.Message) }
        if ($facts.Nltest -and $facts.Nltest.Controller -and -not $facts.Nltest.Address) {
            try { $facts.NltestIp = @(& $Resolve $facts.Nltest.Controller) } catch { Write-Verbose 'DNS did not find the current DC.' }
        }
    }
    return [pscustomobject]$facts
}

function Get-AfSignInSummary {
    # One plain line: where the account running Auto-Fixer signs in.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Facts)

    switch ($Facts.AccountKind) {
        'Cloud' { return 'This account signs in with Microsoft''s cloud (Entra ID / Microsoft 365). No domain controller is used.' }
        'Local' { return 'This is a local account on this PC. No domain controller or cloud sign-in is used.' }
    }
    if ($Facts.LogonServer -and $Facts.LogonServer -ne $Facts.ComputerName) {
        $ip = ''
        if (@($Facts.LogonServerIp).Count) { $ip = ' ({0})' -f (@($Facts.LogonServerIp) -join ', ') }
        return ('This domain account was signed in by the domain controller {0}{1}.' -f $Facts.LogonServer, $ip)
    }
    return 'This is a domain account, but Windows did not record which domain controller signed it in (it may have used saved sign-in details).'
}

function Invoke-AfSignInSourceCheck {
    <#
    .SYNOPSIS
        Read-only, Technician mode: shows the PC name, its join type, the account
        type, the logon domain controller and the current domain controller, each
        with its IP, and writes a redacted log (kind signin).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ReadKey', Justification = 'Same signature as the other Network and domain tools.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $GetFacts = { Get-AfSignInFact },
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Sign-in source (read-only)' -ForegroundColor Cyan
    Write-Host '  Reads dsregcmd /status. On a domain PC it also asks this network''s DNS and domain controller (nltest). Never the internet.' -ForegroundColor DarkGray
    $facts = & $GetFacts

    $names = @($facts.ComputerName, $facts.UserName, $facts.Dsreg.DomainName, $facts.Dsreg.TenantName, $facts.LogonServer)
    if ($facts.AccountKind -ne 'Cloud') { $names += $facts.UserDomain }
    if ($facts.Nltest) { $names += @($facts.Nltest.Controller, $facts.Nltest.Domain) }
    Add-AfRedactionName -Redactor $Redactor -Names $names
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'signin' -Redactor $Redactor -Task 'sign-in source check (read-only)'

    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($Name, $Text, $Color = 'Gray') $rows.Add([pscustomobject]@{ Name = $Name; Text = $Text; Color = $Color }) }
    & $add 'PC' $facts.ComputerName
    if ($facts.DsregError) { & $add 'Join type' ('Unknown. {0}' -f $facts.DsregError) 'Yellow' }
    else { & $add 'Join type' $facts.JoinType.Text 'Green' }
    if ($facts.Dsreg.DomainName) { & $add 'Domain' $facts.Dsreg.DomainName }
    if ($facts.Dsreg.TenantName) { & $add 'Tenant' $facts.Dsreg.TenantName }
    $kind = @{ Cloud = 'cloud account (AzureAD)'; Local = 'local account'; Domain = 'domain account' }[$facts.AccountKind]
    & $add 'Account' ('{0}\{1}, a {2} (the account running Auto-Fixer)' -f $facts.UserDomain, $facts.UserName, $kind)

    if (-not $facts.LogonServer -or $facts.LogonServer -eq $facts.ComputerName) { & $add 'Logon DC' 'None: this PC signed the account in itself (local or cloud sign-in).' }
    elseif ($facts.LogonServerError) { & $add 'Logon DC' ('{0}. {1}' -f $facts.LogonServer, $facts.LogonServerError) 'Yellow' }
    else { & $add 'Logon DC' ('{0} ({1})' -f $facts.LogonServer, (@($facts.LogonServerIp) -join ', ')) }

    if ($facts.Dsreg.DomainJoined -ne 'YES') { & $add 'Current DC' 'None: this PC is not on an on-prem domain.' }
    elseif ($facts.NltestError) { & $add 'Current DC' ('Not found. {0}' -f $facts.NltestError) 'Yellow' }
    else {
        $ip = $facts.Nltest.Address
        if (-not $ip) { $ip = @($facts.NltestIp) -join ', ' }
        & $add 'Current DC' ('{0} ({1}), domain {2}' -f $facts.Nltest.Controller, $ip, $facts.Nltest.Domain)
    }

    foreach ($row in $rows) {
        Write-Host ('  {0,-11}{1}' -f $row.Name, (Protect-AfText -Redactor $screen -Text $row.Text)) -ForegroundColor $row.Color
        Write-AfToolLog $log ('{0,-11}{1}' -f $row.Name, $row.Text)
    }
    $summary = Get-AfSignInSummary -Facts $facts
    Write-Host ''
    Write-Host ('  {0}' -f (Protect-AfText -Redactor $screen -Text $summary)) -ForegroundColor Cyan
    Write-AfToolLog $log ('Summary    {0}' -f $summary)
    if ($facts.NltestLines.Count) {
        Write-AfToolLog $log ('nltest /dsgetdc: exit code {0}' -f $facts.NltestExitCode)
        foreach ($line in $facts.NltestLines) { Write-AfToolLog $log ('  {0}' -f $line) }
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
}
