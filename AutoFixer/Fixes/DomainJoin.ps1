# Join a PC to a domain, repair a broken domain trust, or leave a domain
# (roadmap 6a, raven575 2026-10-28). Rebuilt from the starter win11-domain-join.ps1
# to the project rules:
#   - read-only checks first; a join is offered only when they pass
#   - credential, local administrator and restart warnings, each with a Y/N
#   - passwords go into Windows' own prompt (Get-Credential), never stored or logged
#   - never restarts on its own, and no scheduled task or background job
#   - local network only (DNS and the domain controller), never the internet
#   - domain, controller, PC and account names are redacted on screen and in the log
# Add-Computer, Remove-Computer and Test-ComputerSecureChannel are only in Windows
# PowerShell 5.1, which AutoFix.bat starts.

# Windows Home editions cannot join a domain (OperatingSystemSKU values).
$script:AfHomeSkus = @(98, 99, 100, 101)
$script:AfDomainPorts = [ordered]@{ 88 = 'Kerberos sign-in'; 389 = 'LDAP directory'; 445 = 'File sharing (SMB)' }
# Sign-in fails when the clock is more than 5 minutes off the domain controller.
$script:AfClockLimitSeconds = 300

function Get-AfDomainStatus {
    # This PC's domain or workgroup and whether its edition can join. Read-only.
    [CmdletBinding()]
    param()

    $status = [pscustomobject]@{ OnDomain = $false; Domain = ''; Workgroup = ''; ComputerName = [Environment]::MachineName; Edition = ''; CanJoin = $false }
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { return $status }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $status.OnDomain = [bool]$cs.PartOfDomain
        if ($status.OnDomain) { $status.Domain = [string]$cs.Domain } else { $status.Workgroup = [string]$cs.Workgroup }
        $status.Edition = [string]$os.Caption
        $status.CanJoin = -not ($script:AfHomeSkus -contains [int]$os.OperatingSystemSKU -or $status.Edition -match '(?i)\bHome\b')
    }
    catch { Write-Verbose ('Domain status: {0}' -f $_.Exception.Message) }
    return $status
}

function Test-AfDomainName {
    # A DNS domain name such as contoso.local: two or more labels.
    param([string] $Name)
    return ($Name -match '^(?=.{3,253}$)(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))+$')
}

function Test-AfComputerName {
    # 1 to 15 letters, digits or hyphens, not only digits.
    param([string] $Name)
    return ($Name -match '^(?![0-9]+$)(?!-)[A-Za-z0-9-]{1,15}(?<!-)$')
}

function Resolve-AfDomainController {
    # Domain controllers from the domain's DNS SRV records. Read-only.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Domain)
    return @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.{0}' -f $Domain) -Type SRV -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -eq 'SRV' } | Sort-Object Priority, Weight | ForEach-Object { [string]$_.NameTarget })
}

function Test-AfTcpPort {
    # Opens and closes one TCP connection, waiting at most two seconds.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [int] $Port)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Server, $Port)
        return ($task.Wait(2000) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-AfClockOffset {
    # Seconds this PC's clock is ahead (+) or behind (-) of a server, from w32tm output; $null if unreadable.
    param([string[]] $Lines = @())
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '([+-]\d+(?:[.,]\d+)?)s\s*$')
        if ($m.Success) { return [double]::Parse($m.Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture) }
    }
    return $null
}

function Test-AfDomainReach {
    <#
    .SYNOPSIS
        The read-only checks before a join or when a domain PC has sign-in trouble:
        DNS finds a domain controller, the DC locator answers, the controller's
        ports answer, and the clock is close enough. Returns Checks (Name, Tag,
        Detail), Controller, ClockOffset (seconds, or null) and Passed (no FAIL).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Domain,
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList },
        [scriptblock] $Resolve = { param($Domain) Resolve-AfDomainController -Domain $Domain },
        [scriptblock] $TestPort = { param($Server, $Port) Test-AfTcpPort -Server $Server -Port $Port }
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $add = { param($Name, $Tag, $Detail) $checks.Add([pscustomobject]@{ Name = $Name; Tag = $Tag; Detail = $Detail }) }
    $controller = $null
    $offset = $null

    try {
        $found = @(& $Resolve $Domain | Where-Object { $_ })
        if ($found.Count) { $controller = $found[0]; & $add 'DNS' 'OK' ('Found {0} domain controller(s), first {1}.' -f $found.Count, $controller) }
        else { & $add 'DNS' 'FAIL' 'DNS has no domain controller record for this domain. Check that this PC uses the domain''s DNS server.' }
    }
    catch { & $add 'DNS' 'FAIL' ('DNS could not find the domain: {0} Check that this PC uses the domain''s DNS server.' -f $_.Exception.Message) }

    $r = & $RunTool -Name 'nltest.exe' -ArgumentList @(('/dsgetdc:{0}' -f $Domain))
    if ($r.ExitCode -eq 0) {
        $dc = [regex]::Match((@($r.Lines) -join "`n"), '(?im)^\s*DC:\s*\\\\(\S+)')
        if ($dc.Success -and -not $controller) { $controller = $dc.Groups[1].Value }
        & $add 'Locator' 'OK' 'Windows found a domain controller.'
    }
    else { & $add 'Locator' 'WARN' ('Windows could not locate a domain controller (nltest exit code {0}).' -f $r.ExitCode) }

    if ($controller) {
        foreach ($port in $script:AfDomainPorts.Keys) {
            if (& $TestPort $controller $port) { & $add ('Port {0}' -f $port) 'OK' ('{0} answers.' -f $script:AfDomainPorts[$port]) }
            else { & $add ('Port {0}' -f $port) 'FAIL' ('{0} does not answer. A firewall or network rule may block it.' -f $script:AfDomainPorts[$port]) }
        }
        $r = & $RunTool -Name 'w32tm.exe' -ArgumentList @('/stripchart', ('/computer:{0}' -f $controller), '/samples:1', '/dataonly')
        $offset = Get-AfClockOffset -Lines $r.Lines
        if ($null -eq $offset) { & $add 'Clock' 'WARN' 'Could not compare the clock with the domain controller.' }
        elseif ([math]::Abs($offset) -gt $script:AfClockLimitSeconds) { & $add 'Clock' 'FAIL' ('This PC''s clock is {0:N0} minutes off. Sign-in fails past 5 minutes; fix the time first.' -f ([math]::Abs($offset) / 60)) }
        elseif ([math]::Abs($offset) -gt 60) { & $add 'Clock' 'WARN' ('This PC''s clock is {0:N0} seconds off.' -f [math]::Abs($offset)) }
        else { & $add 'Clock' 'OK' 'The clock matches the domain controller.' }
    }
    else { & $add 'Controller' 'FAIL' 'No domain controller to test.' }

    return [pscustomobject]@{ Checks = $checks.ToArray(); Controller = $controller; ClockOffset = $offset; Passed = -not @($checks | Where-Object Tag -EQ 'FAIL').Count }
}

function Invoke-AfComputerCommand {
    # Runs a Windows PowerShell 5.1 domain cmdlet, with a plain message on PowerShell 7.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, [hashtable] $Parameters = @{})

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw ('{0} is only in Windows PowerShell 5.1. Start Auto-Fixer with AutoFix.bat.' -f $Name)
    }
    return (& $Name @Parameters -ErrorAction Stop)
}

function New-AfToolLog {
    # A redacted log in a new run folder. Write lines with Write-AfToolLog.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot, [Parameter(Mandatory)] [string] $FileName, [Parameter(Mandatory)] $Redactor, [string] $Task)

    $null = New-Item -ItemType Directory -Path $OutputRoot -Force
    $folder = New-Item -ItemType Directory -Path (Join-Path $OutputRoot (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    $log = [pscustomobject]@{ Path = (Join-Path $folder.FullName $FileName); Redactor = $Redactor }
    Write-AfToolLog $log ('Auto-Fixer {0} log' -f $script:AfVersion)
    Write-AfToolLog $log ('Run start : {0} UTC' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
    if ($Task) { Write-AfToolLog $log ('Task      : {0}' -f $Task) }
    return $log
}

function Write-AfToolLog {
    param([Parameter(Mandatory)] $Log, [string] $Text)
    Add-Content -LiteralPath $Log.Path -Value (Protect-AfText -Redactor $Log.Redactor -Text $Text) -Encoding UTF8
}

function Write-AfCheckList {
    param([object[]] $Checks, [scriptblock] $Show, $Log)
    $colors = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    foreach ($c in $Checks) {
        Write-Host ('  {0,-6}{1,-10}{2}' -f $c.Tag, $c.Name, (& $Show $c.Detail)) -ForegroundColor $colors[$c.Tag]
        if ($Log) { Write-AfToolLog $Log ('{0,-6}{1,-10}{2}' -f $c.Tag, $c.Name, $c.Detail) }
    }
}

function Read-AfRestartChoice {
    # The join and leave take effect after a restart; the user decides when.
    param([scriptblock] $ReadKey, [scriptblock] $Restart, $Log)
    Write-Host ''
    Write-Host '  Windows needs a restart to finish this. Save your work in other programs first.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Restart now?' -ReadKey $ReadKey) -eq $true) { Write-AfToolLog $Log 'Restart   : started by the user'; & $Restart }
    else { Write-Host '  Restart later. The change finishes at the next restart.' -ForegroundColor Yellow }
}

function Invoke-AfDomainCheck {
    <#
    .SYNOPSIS
        Read-only, in both modes: shows the domain or workgroup and the edition, runs
        the reach checks for this PC's domain (or a domain the user types), and the
        trust check when this PC is on a domain and Auto-Fixer runs as administrator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [scriptblock] $GetStatus = { Get-AfDomainStatus },
        [scriptblock] $Reach = { param($Domain) Test-AfDomainReach -Domain $Domain },
        [scriptblock] $Computer = { param($Name, $Parameters) Invoke-AfComputerCommand -Name $Name -Parameters $Parameters },
        $Redactor = (New-AfRedactor)
    )

    $status = & $GetStatus
    Add-AfRedactionName -Redactor $Redactor -Names @($status.Domain, $status.Workgroup, $status.ComputerName)
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }

    Write-Host ''
    Write-Host '  Domain check (read-only)' -ForegroundColor Cyan
    if ($status.OnDomain) { Write-Host ('  This PC is on the domain {0}.' -f (& $show $status.Domain)) }
    else { Write-Host ('  This PC is in the workgroup {0}, not on a domain.' -f (& $show $status.Workgroup)) }
    $canJoin = 'yes'
    if (-not $status.CanJoin) { $canJoin = 'no (Home editions cannot join a domain)' }
    Write-Host ('  Windows edition: {0}. Can join a domain: {1}.' -f $status.Edition, $canJoin)

    $domain = $status.Domain
    if (-not $status.OnDomain) {
        $domain = ([string](& $ReadText 'Domain to test, such as contoso.local (Enter = skip)')).Trim()
        if (-not $domain) { return }
        if (-not (Test-AfDomainName $domain)) { Write-Host '  That is not a domain name such as contoso.local. Nothing was tested.' -ForegroundColor Yellow; return }
    }
    Add-AfRedactionName -Redactor $Redactor -Names @($domain)
    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'domain.log' -Redactor $Redactor -Task 'domain check (read-only)'
    Write-Host ''
    $result = & $Reach $domain
    Add-AfRedactionName -Redactor $Redactor -Names @($result.Controller)
    $checks = @($result.Checks)
    if ($status.OnDomain) {
        if (-not $IsAdmin) { $checks += [pscustomobject]@{ Name = 'Trust'; Tag = 'WARN'; Detail = 'The trust check needs administrator rights. Start Auto-Fixer with AutoFix.bat.' } }
        else {
            try {
                if (& $Computer 'Test-ComputerSecureChannel' @{}) { $checks += [pscustomobject]@{ Name = 'Trust'; Tag = 'OK'; Detail = 'This PC''s trust with the domain is healthy.' } }
                else { $checks += [pscustomobject]@{ Name = 'Trust'; Tag = 'FAIL'; Detail = 'The trust with the domain is broken. Technician mode can repair it.' } }
            }
            catch { $checks += [pscustomobject]@{ Name = 'Trust'; Tag = 'WARN'; Detail = ('Could not test the trust: {0}' -f $_.Exception.Message) } }
        }
    }
    Write-AfCheckList -Checks $checks -Show $show -Log $log
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
}

function Invoke-AfDomainJoin {
    <#
    .SYNOPSIS
        Technician mode: joins this PC to a domain with Add-Computer after the reach
        checks pass and the user says Y to the credential and local administrator
        warnings. Optionally renames the PC and picks an OU. Never restarts on its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [scriptblock] $GetStatus = { Get-AfDomainStatus },
        [scriptblock] $Reach = { param($Domain) Test-AfDomainReach -Domain $Domain },
        [scriptblock] $GetCredential = { param($Message) Get-Credential -Message $Message },
        [scriptblock] $Computer = { param($Name, $Parameters) Invoke-AfComputerCommand -Name $Name -Parameters $Parameters },
        [scriptblock] $Restart = { Invoke-AfRestart -Reason 'Auto-Fixer joined this PC to a domain.' },
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Join this PC to a domain' -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat and say Yes to the Windows prompt.' -ForegroundColor Yellow; return }
    $status = & $GetStatus
    Add-AfRedactionName -Redactor $Redactor -Names @($status.Domain, $status.Workgroup, $status.ComputerName)
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }
    if ($status.OnDomain) { Write-Host ('  This PC is already on the domain {0}. Leave it first.' -f (& $show $status.Domain)) -ForegroundColor Yellow; return }
    if (-not $status.CanJoin) { Write-Host ('  {0} cannot join a domain. It needs Pro, Enterprise or Education.' -f $status.Edition) -ForegroundColor Yellow; return }

    $domain = ([string](& $ReadText 'Domain to join, such as contoso.local (Enter = cancel)')).Trim()
    if (-not $domain) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
    if (-not (Test-AfDomainName $domain)) { Write-Host '  That is not a domain name such as contoso.local. Nothing was changed.' -ForegroundColor Yellow; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($domain)
    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'domain.log' -Redactor $Redactor -Task 'join a domain'
    Write-AfToolLog $log ('Before    : workgroup {0}, PC name {1}' -f $status.Workgroup, $status.ComputerName)

    Write-Host ''
    Write-Host '  Checking that this PC can reach the domain (read-only)...' -ForegroundColor White
    $result = & $Reach $domain
    Add-AfRedactionName -Redactor $Redactor -Names @($result.Controller)
    Write-AfCheckList -Checks $result.Checks -Show $show -Log $log
    # A clock that is off on purpose (some test and lab servers) may be skipped, but
    # only when it is the one FAIL; Kerberos may still refuse the join.
    $fails = @($result.Checks | Where-Object Tag -EQ 'FAIL')
    $clockSkipped = $false
    if ($fails.Count -eq 1 -and $fails[0].Name -eq 'Clock') {
        $minutes = 'more than 5'
        if ($null -ne $result.ClockOffset) { $minutes = '{0:N0}' -f ([math]::Abs($result.ClockOffset) / 60) }
        Write-Host ''
        Write-Host ('  This PC''s clock is {0} minutes off the domain controller. Windows sign-in' -f $minutes) -ForegroundColor Yellow
        Write-Host '  (Kerberos) allows 5 minutes, so the join itself may still fail.' -ForegroundColor Yellow
        if ((Read-AfYesNo -Prompt 'Continue anyway?' -ReadKey $ReadKey) -ne $true) {
            Write-Host '  Nothing was changed.' -ForegroundColor Yellow
            Write-AfToolLog $log 'Outcome   : not started, the clock check failed'
            return
        }
        Write-AfToolLog $log ('Clock     : check skipped by user ({0} minutes off)' -f $minutes)
        $clockSkipped = $true
    }
    elseif ($fails.Count) {
        Write-Host '  Fix the FAIL lines first. Nothing was changed.' -ForegroundColor Yellow
        Write-AfToolLog $log 'Outcome   : not started, a check failed'
        return
    }

    $newName = ([string](& $ReadText ('New PC name, 15 characters at most (Enter = keep {0})' -f (& $show $status.ComputerName)))).Trim()
    if ($newName -and -not (Test-AfComputerName $newName)) { Write-Host '  A PC name has 1 to 15 letters, digits or hyphens. Nothing was changed.' -ForegroundColor Yellow; return }
    $ou = ([string](& $ReadText 'OU, such as OU=Laptops,DC=contoso,DC=local (Enter = the domain''s default)')).Trim()
    if ($ou -and $ou -notmatch '(?i)^(OU|CN)=.+DC=') { Write-Host '  That is not an OU path such as OU=Laptops,DC=contoso,DC=local. Nothing was changed.' -ForegroundColor Yellow; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($newName)

    Write-Host ''
    Write-Host '  You need a domain account that is allowed to add computers to the domain.' -ForegroundColor Yellow
    Write-Host '  If you do not have one, stop now.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Continue?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
    Write-Host ''
    Write-Host '  Make sure you know the password of a local administrator account on this PC.' -ForegroundColor Yellow
    Write-Host '  If the domain join goes wrong, it is the only way back in. After the restart,' -ForegroundColor Yellow
    Write-Host '  people sign in with domain accounts, which get new profiles; files in the old' -ForegroundColor Yellow
    Write-Host '  local profiles stay where they are.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Join the domain now?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }

    $credential = & $GetCredential 'Domain account that can add computers (for example CONTOSO\admin)'
    if (-not $credential) { Write-Host '  No account given. Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled at the sign-in prompt'; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($credential.UserName)

    $parameters = @{ DomainName = $domain; Credential = $credential }
    if ($newName) { $parameters.NewName = $newName }
    if ($ou) { $parameters.OUPath = $ou }
    try {
        $null = & $Computer 'Add-Computer' $parameters
        Write-Host ('  OK      Joined {0}.' -f (& $show $domain)) -ForegroundColor Green
        Write-AfToolLog $log ('Outcome   : joined; new PC name {0}; OU {1}' -f @{ $true = $newName; $false = '(unchanged)' }[[bool]$newName], @{ $true = $ou; $false = '(default)' }[[bool]$ou])
    }
    catch {
        Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red
        Write-Host '  Nothing else was changed.' -ForegroundColor Yellow
        if ($clockSkipped) { Write-Host '  The clock difference may be why. Set this PC''s time to match the domain and try again.' -ForegroundColor Yellow }
        Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message)
        if ($clockSkipped) { Write-AfToolLog $log 'Note      : the clock check was skipped; the clock difference may be why' }
        return
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
    Read-AfRestartChoice -ReadKey $ReadKey -Restart $Restart -Log $log
}

function Invoke-AfDomainTrustRepair {
    <#
    .SYNOPSIS
        Technician mode: tests the trust and, when it is broken and the user says Y,
        repairs it with Test-ComputerSecureChannel -Repair. No restart needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [scriptblock] $GetStatus = { Get-AfDomainStatus },
        [scriptblock] $GetCredential = { param($Message) Get-Credential -Message $Message },
        [scriptblock] $Computer = { param($Name, $Parameters) Invoke-AfComputerCommand -Name $Name -Parameters $Parameters },
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Repair the domain trust' -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat and say Yes to the Windows prompt.' -ForegroundColor Yellow; return }
    $status = & $GetStatus
    if (-not $status.OnDomain) { Write-Host '  This PC is not on a domain, so there is no trust to repair.' -ForegroundColor Yellow; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($status.Domain, $status.ComputerName)
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }

    try { $healthy = [bool](& $Computer 'Test-ComputerSecureChannel' @{}) }
    catch { Write-Host ('  Could not test the trust: {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red; return }
    if ($healthy) { Write-Host '  OK      The trust with the domain is healthy. Nothing to repair.' -ForegroundColor Green; return }

    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'domain.log' -Redactor $Redactor -Task 'repair the domain trust'
    Write-AfToolLog $log 'Before    : trust broken'
    Write-Host '  The trust with the domain is broken: domain accounts cannot sign in on this PC.' -ForegroundColor Red
    Write-Host '  The repair resets this PC''s password with the domain. It needs a domain account' -ForegroundColor Yellow
    Write-Host '  that is allowed to reset computer accounts. If you do not have one, stop now.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Repair the trust?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
    $credential = & $GetCredential 'Domain account that can reset computer accounts (for example CONTOSO\admin)'
    if (-not $credential) { Write-Host '  No account given. Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled at the sign-in prompt'; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($credential.UserName)

    try {
        $repaired = [bool](& $Computer 'Test-ComputerSecureChannel' @{ Repair = $true; Credential = $credential })
        if ($repaired -and [bool](& $Computer 'Test-ComputerSecureChannel' @{})) {
            Write-Host '  OK      The trust is repaired. Domain accounts can sign in again.' -ForegroundColor Green
            Write-AfToolLog $log 'Outcome   : repaired, re-test passed'
        }
        else {
            Write-Host '  FAILED  The trust is still broken. The PC may need to leave and rejoin the domain.' -ForegroundColor Red
            Write-AfToolLog $log 'Outcome   : FAILED, re-test still broken'
        }
    }
    catch {
        Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red
        Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message)
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
}

function Invoke-AfDomainLeave {
    <#
    .SYNOPSIS
        Technician mode: takes this PC off its domain into WORKGROUP with
        Remove-Computer, after the local administrator and credential warnings.
        Never restarts on its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [scriptblock] $GetStatus = { Get-AfDomainStatus },
        [scriptblock] $GetCredential = { param($Message) Get-Credential -Message $Message },
        [scriptblock] $Computer = { param($Name, $Parameters) Invoke-AfComputerCommand -Name $Name -Parameters $Parameters },
        [scriptblock] $Restart = { Invoke-AfRestart -Reason 'Auto-Fixer took this PC off its domain.' },
        $Redactor = (New-AfRedactor)
    )

    Write-Host ''
    Write-Host '  Leave the domain' -ForegroundColor Cyan
    if (-not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat and say Yes to the Windows prompt.' -ForegroundColor Yellow; return }
    $status = & $GetStatus
    if (-not $status.OnDomain) { Write-Host '  This PC is not on a domain.' -ForegroundColor Yellow; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($status.Domain, $status.ComputerName)
    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screen -Text $Text }

    Write-Host ('  This takes the PC off {0} and puts it in the workgroup WORKGROUP.' -f (& $show $status.Domain))
    Write-Host ''
    Write-Host '  After the restart, domain accounts can no longer sign in here. Make sure you' -ForegroundColor Yellow
    Write-Host '  know the password of a local administrator account on this PC, or you may be' -ForegroundColor Yellow
    Write-Host '  locked out. Joining again later needs a domain account that can add computers.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Leave the domain?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }

    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'domain.log' -Redactor $Redactor -Task 'leave the domain'
    Write-AfToolLog $log ('Before    : domain {0}, PC name {1}' -f $status.Domain, $status.ComputerName)
    $credential = & $GetCredential 'Domain account that can remove this computer (for example CONTOSO\admin)'
    if (-not $credential) { Write-Host '  No account given. Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled at the sign-in prompt'; return }
    Add-AfRedactionName -Redactor $Redactor -Names @($credential.UserName)

    try {
        # -Force skips the cmdlet's own question; the user already answered Y above.
        $null = & $Computer 'Remove-Computer' @{ UnjoinDomainCredential = $credential; WorkgroupName = 'WORKGROUP'; Force = $true }
        Write-Host '  OK      This PC is leaving the domain.' -ForegroundColor Green
        Write-AfToolLog $log 'Outcome   : left the domain, now WORKGROUP after restart'
    }
    catch {
        Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red
        Write-Host '  Nothing else was changed.' -ForegroundColor Yellow
        Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message)
        return
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
    Read-AfRestartChoice -ReadKey $ReadKey -Restart $Restart -Log $log
}
