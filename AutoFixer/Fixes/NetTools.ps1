# Network tools (raven575 2026-10-30, plan network-tools-plan-2026-10-30.md), both modes:
#   - read-only: status, ping, trace route, open connections, DNS lookup, port test
#   - changes, each after a Y/N: flush DNS, release/renew; Technician: adapter
#     restart and the Winsock/TCP-IP reset
#   - a target is only ever the gateway, a DNS server or one the user typed, and the
#     screen says where it is going before anything is sent
#   - addresses and names are redacted on screen (unless Show sensitive is on) and
#     always in nettools.log

function Get-AfNetStatus {
    <#
    .SYNOPSIS
        Read-only: one row per connected adapter with Alias, Description, Status,
        IPv4, Gateway, Dns (array) and Dhcp ([bool]). Empty where the NetTCPIP
        cmdlets are missing.
    #>
    [CmdletBinding()]
    param()
    if (-not (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue)) { return @() }
    @(Get-NetIPConfiguration -Detailed -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Alias       = $_.InterfaceAlias
                Description = $_.InterfaceDescription
                Status      = [string]$_.NetAdapter.Status
                IPv4        = @($_.IPv4Address | ForEach-Object IPAddress) -join ', '
                Gateway     = @($_.IPv4DefaultGateway | ForEach-Object NextHop) -join ', '
                Dns         = @($_.DNSServer | Where-Object AddressFamily -EQ 2 | ForEach-Object ServerAddresses)
                Dhcp        = ([string]$_.NetIPv4Interface.Dhcp -eq 'Enabled')
            }
        })
}

function Get-AfNetConnection {
    # Read-only: TCP connections with the program that owns each (like netstat -ano).
    [CmdletBinding()]
    param()
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return @() }
    $names = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $names[[int]$_.Id] = $_.ProcessName }
    @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.State -in 'Listen', 'Established' } | ForEach-Object {
            [pscustomobject]@{
                State   = [string]$_.State
                Local   = '{0}:{1}' -f $_.LocalAddress, $_.LocalPort
                Remote  = '{0}:{1}' -f $_.RemoteAddress, $_.RemotePort
                Program = @{ $true = $names[[int]$_.OwningProcess]; $false = ('PID {0}' -f $_.OwningProcess) }[$names.ContainsKey([int]$_.OwningProcess)]
            }
        })
}

function Test-AfNetTarget {
    # Returns why a typed target is wrong, or nothing when it is an IP address or a host name.
    param([string] $Text)
    if ($Text -match '^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$') { return }
    if ($Text -match ':' -and $Text -match '^[0-9A-Fa-f:]+$') { return }
    if ($Text.Length -le 253 -and $Text -match '^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$') { return }
    return 'That is not an IP address or a name such as www.example.com.'
}

function Read-AfNetTarget {
    <#
    .SYNOPSIS
        Picks where a test goes: 1 = gateway, 2 = first DNS server, T = type one.
        Returns the target or $null. Typed targets are added to the redactor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Status,
        [Parameter(Mandatory)] [scriptblock] $ReadKey,
        [Parameter(Mandatory)] [scriptblock] $ReadText,
        [Parameter(Mandatory)] [scriptblock] $Show,
        [Parameter(Mandatory)] $Redactor
    )
    $gateway = @($Status | ForEach-Object { ($_.Gateway -split ', ')[0] } | Where-Object { $_ })[0]
    $dns = @($Status | ForEach-Object { $_.Dns } | Where-Object { $_ })[0]
    $choices = @{}
    Write-Host ''
    Write-Host '  Where to?' -ForegroundColor White
    if ($gateway) { $choices['1'] = $gateway; Write-Host ('  1  Your router (gateway) {0}' -f (& $Show $gateway)) }
    if ($dns) { $choices['2'] = $dns; Write-Host ('  2  Your DNS server {0}' -f (& $Show $dns)) }
    Write-Host '  T  Type a name or IP address'
    Write-Host '  Esc = cancel' -ForegroundColor DarkGray
    for ($try = 1; $try -le 2; $try++) {
        $key = [string](& $ReadKey)
        if ($choices.ContainsKey($key)) { return $choices[$key] }
        if ($key -ieq 'T') {
            $text = Read-AfCheckedText -ReadText $ReadText -Prompt 'Name or IP address, such as www.example.com (Enter = cancel)' -Check { param($t) Test-AfNetTarget $t }
            if (-not $text) { return $null }
            Add-AfRedactionName -Redactor $Redactor -Names @($text)
            return $text
        }
        if ($key -eq 'Escape' -or $key -eq [string][char]27 -or $key -ieq 'B') { return $null }
        if ($try -eq 1) { Write-Host '  Command unknown. Press a number, T or Esc.' -ForegroundColor Yellow }
    }
    return $null
}

function Invoke-AfStreamTool {
    <#
    .SYNOPSIS
        Runs a Windows program and prints each line as it comes, so a slow trace
        route shows progress. Esc stops it. Returns ExitCode, Lines and Stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $ArgumentList = @(),
        [scriptblock] $Show = { param($Text) $Text },
        [scriptblock] $PollKey = { if ([Console]::KeyAvailable) { [Console]::ReadKey($true).Key.ToString() } }
    )
    $out = [IO.Path]::GetTempFileName()
    $lines = New-Object System.Collections.Generic.List[string]
    $stopped = $false
    try {
        $p = Start-Process -FilePath (Get-AfSystemToolPath $Name) -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $out
        $seen = 0
        while ($true) {
            $done = $p.HasExited
            $now = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue)
            for (; $seen -lt $now.Count; $seen++) {
                $line = [string]$now[$seen]
                $lines.Add($line)
                if ($line.Trim()) { Write-Host ('  {0}' -f (& $Show $line)) }
            }
            if ($done) { break }
            if ((& $PollKey) -eq 'Escape') { $p.Kill(); $stopped = $true; Write-Host '  Stopped.' -ForegroundColor Yellow; break }
            Start-Sleep -Milliseconds 200
        }
        $code = $null
        if (-not $stopped) { $p.WaitForExit(); $code = $p.ExitCode }
    }
    finally { Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines.ToArray(); Stopped = $stopped }
}

function Test-AfRemoteSession {
    # True in a Remote Desktop session, where dropping the network cuts the user off.
    return ([string]$env:SESSIONNAME -like 'RDP-*')
}

function Invoke-AfNetTool {
    <#
    .SYNOPSIS
        Runs one network tool by its menu key (S, P, T, N, L, O, F, R, A, W) and
        logs it. Every Windows call goes through a script block, so tests touch
        nothing real.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [bool] $IsAdmin = (Test-AfIsAdmin),
        [bool] $Remote = (Test-AfRemoteSession),
        [scriptblock] $GetStatus = { Get-AfNetStatus },
        [scriptblock] $GetConnections = { Get-AfNetConnection },
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList },
        [scriptblock] $Stream = { param($Name, $ArgumentList, $Show) Invoke-AfStreamTool -Name $Name -ArgumentList $ArgumentList -Show $Show },
        [scriptblock] $Lookup = { param($Target) @(Resolve-DnsName -Name $Target -DnsOnly -ErrorAction Stop | ForEach-Object { '{0}  {1}  {2}' -f $_.Name, $_.Type, (@($_.IPAddress, $_.NameHost) | Where-Object { $_ })[0] }) },
        [scriptblock] $TestPort = { param($Target, $Port) Test-AfTcpPort -Server $Target -Port $Port },
        [scriptblock] $RestartAdapter = { param($Alias) Restart-NetAdapter -Name $Alias -Confirm:$false -ErrorAction Stop },
        $Redactor = (New-AfRedactor)
    )

    $screen = $Redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }
    # Plain script blocks, not closures: a closure loses this module's private functions.
    $show = { param($Text) Protect-AfText -Redactor $screen -Text $Text }
    $titles = @{ S = 'Network status'; P = 'Ping'; T = 'Trace route'; N = 'Open connections (netstat)'; L = 'DNS lookup'; O = 'Port test'; F = 'Flush DNS'; R = 'Release and renew IP'; A = 'Restart an adapter'; W = 'Reset Winsock and TCP/IP' }
    Write-Host ''
    Write-Host ('  {0}' -f $titles[$Key]) -ForegroundColor Cyan
    if ($Key -in 'R', 'A', 'W' -and -not $IsAdmin) { Write-Host '  This needs administrator rights. Start Auto-Fixer with AutoFix.bat.' -ForegroundColor Yellow; return }
    if ($Key -in 'A', 'W' -and $Settings.Mode -ne 'Technician') { Write-Host '  This is in Technician mode only.' -ForegroundColor Yellow; return }

    $log = New-AfToolLog -OutputRoot $OutputRoot -FileName 'nettools.log' -Redactor $Redactor -Task $titles[$Key].ToLowerInvariant()
    $status = @(& $GetStatus)
    $echo = {
        param($Lines)
        foreach ($l in @($Lines)) {
            if ([string]$l -match '\S') { Write-Host ('  {0}' -f (& $show ([string]$l))); Write-AfToolLog $log ('  ' + $l) }
        }
    }

    switch ($Key) {
        'S' {
            if (-not $status.Count) { Write-Host '  No connected network adapter was found.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : no adapter'; return }
            foreach ($a in $status) {
                Write-Host ''
                Write-Host ('  {0}  ({1}, {2})' -f (& $show $a.Alias), (& $show $a.Description), $a.Status) -ForegroundColor White
                $lines = @(('IP address  {0}' -f $a.IPv4), ('Gateway     {0}' -f $a.Gateway), ('DNS         {0}' -f (@($a.Dns) -join ', ')), ('DHCP        {0}' -f @{ $true = 'on (automatic)'; $false = 'off (static IP)' }[[bool]$a.Dhcp]))
                foreach ($l in $lines) { Write-Host ('    {0}' -f (& $show $l)); Write-AfToolLog $log ('{0}: {1}' -f $a.Alias, $l) }
            }
            if (-not $Settings.ShowSensitive) { Write-Host ''; Write-Host '  Addresses are hidden. Turn on Show sensitive data in Settings to see them.' -ForegroundColor DarkGray }
        }
        { $_ -in 'P', 'T', 'L', 'O' } {
            $target = Read-AfNetTarget -Status $status -ReadKey $ReadKey -ReadText $ReadText -Show $show -Redactor $Redactor
            if (-not $target) { Write-Host '  Nothing was sent.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
            $port = 0
            if ($Key -eq 'O') {
                $text = Read-AfCheckedText -ReadText $ReadText -Prompt 'Port, such as 443 for web or 3389 for Remote Desktop (Enter = cancel)' -Check { param($t) $n = 0; if (-not ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le 65535)) { 'A port is a number from 1 to 65535.' } }
                if (-not $text) { Write-Host '  Nothing was sent.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
                $port = [int]$text
            }
            $what = @{ P = 'Sending 4 pings to {0}'; T = 'Tracing the route to {0} (up to 30 steps; Esc stops)'; L = 'Asking your DNS server for {0}'; O = 'Trying port {1} on {0}' }[$Key]
            Write-Host ('  {0}. You picked it; nothing else is contacted.' -f ($what -f (& $show $target), $port)) -ForegroundColor White
            Write-AfToolLog $log ('Target    : {0}{1}' -f $target, @{ $true = (' port {0}' -f $port); $false = '' }[$port -gt 0])
            switch ($Key) {
                'P' {
                    $r = & $RunTool 'ping.exe' @('-n', '4', $target)
                    & $echo $r.Lines
                    $ok = $r.ExitCode -eq 0
                }
                'T' {
                    $r = & $Stream 'tracert.exe' @('-d', '-h', '30', '-w', '1000', $target) $show
                    foreach ($l in @($r.Lines)) { if ([string]$l -match '\S') { Write-AfToolLog $log ('  ' + $l) } }
                    $ok = (-not $r.Stopped) -and $r.ExitCode -eq 0
                }
                'L' {
                    try { $ok = $true; & $echo @(& $Lookup $target) }
                    catch { $ok = $false; Write-Host ('  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Yellow }
                }
                'O' { $ok = [bool](& $TestPort $target $port) }
            }
            $result = @{
                P = @('OK      It answered.', 'FAIL    No answer. It may be down, or it blocks pings.')
                T = @('Done.', 'The trace did not finish.')
                L = @('OK      The name was found.', 'FAIL    The name was not found.')
                O = @('OK      The port is open.', 'FAIL    The port did not answer in 2 seconds (closed, filtered or down).')
            }[$Key][[int](-not $ok)]
            Write-Host ('  {0}' -f $result) -ForegroundColor @{ $true = 'Green'; $false = 'Yellow' }[[bool]$ok]
            Write-AfToolLog $log ('Outcome   : {0}' -f $result.Trim())
        }
        'N' {
            $all = @(& $GetConnections)
            $listen = @($all | Where-Object State -EQ 'Listen')
            $open = @($all | Where-Object State -EQ 'Established' | Sort-Object Program)
            Write-Host ('  {0} programs are listening, {1} connections are open.' -f $listen.Count, $open.Count) -ForegroundColor White
            Write-AfToolLog $log ('Counts    : {0} listening, {1} established' -f $listen.Count, $open.Count)
            foreach ($c in @($open | Select-Object -First 20)) {
                $line = '{0,-22} {1,-24} {2}' -f $c.Program, $c.Local, $c.Remote
                Write-Host ('  {0}' -f (& $show $line)); Write-AfToolLog $log ('  ' + $line)
            }
            if ($open.Count -gt 20) { Write-Host ('  ... and {0} more (all are in the log).' -f ($open.Count - 20)) -ForegroundColor DarkGray }
            foreach ($c in @($open | Select-Object -Skip 20) + $listen) { Write-AfToolLog $log ('  {0,-12}{1,-22} {2,-24} {3}' -f $c.State, $c.Program, $c.Local, $c.Remote) }
        }
        'F' {
            Write-Host '  Clears the list of names Windows remembers, so it asks DNS again. Harmless.' -ForegroundColor White
            if ((Read-AfYesNo -Prompt 'Flush the DNS cache?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
            $r = & $RunTool 'ipconfig.exe' @('/flushdns')
            & $echo $r.Lines
            Write-AfToolLog $log ('Outcome   : ipconfig /flushdns, exit code {0}' -f $r.ExitCode)
        }
        'R' {
            Write-Host '  Gives back this PC''s IP address and asks the router for one again.' -ForegroundColor White
            Write-Host '  The network drops for a few seconds. A static IP is not changed.' -ForegroundColor Yellow
            if ($Remote) { Write-Host '  WARNING: this is a Remote Desktop session. It can cut you off from this PC.' -ForegroundColor Red }
            if ((Read-AfYesNo -Prompt 'Release and renew now?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
            $release = & $RunTool 'ipconfig.exe' @('/release')
            Write-AfToolLog $log ('Release   : exit code {0}' -f $release.ExitCode)
            $renew = & $RunTool 'ipconfig.exe' @('/renew')
            Write-AfToolLog $log ('Renew     : exit code {0}' -f $renew.ExitCode)
            & $echo @($renew.Lines | Where-Object { $_ -match '(?i)IPv4|Gateway|error|unable|failed' })
            $ok = $renew.ExitCode -eq 0
            Write-Host ('  {0}' -f @{ $true = 'OK      A new address was asked for.'; $false = 'FAIL    Renew did not finish. Check the cable or Wi-Fi, then try again.' }[$ok]) -ForegroundColor @{ $true = 'Green'; $false = 'Yellow' }[$ok]
        }
        'A' {
            if (-not $status.Count) { Write-Host '  No connected network adapter was found.' -ForegroundColor Yellow; return }
            $list = @($status | Select-Object -First 9)
            Write-Host '  Pick the adapter to restart:' -ForegroundColor White
            for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('  {0}  {1}  ({2})' -f ($i + 1), (& $show $list[$i].Alias), (& $show $list[$i].Description)) }
            Write-Host '  Esc = cancel' -ForegroundColor DarkGray
            $number = 0
            if (-not ([int]::TryParse([string](& $ReadKey), [ref]$number) -and $number -ge 1 -and $number -le $list.Count)) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
            $pick = $list[$number - 1]
            if ($Remote) { Write-Host '  WARNING: this is a Remote Desktop session. It can cut you off from this PC.' -ForegroundColor Red }
            if ((Read-AfYesNo -Prompt ('Restart {0}? The connection drops for a moment.' -f (& $show $pick.Alias)) -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
            try { & $RestartAdapter $pick.Alias; Write-Host '  OK      Restarted. It reconnects in a few seconds.' -ForegroundColor Green; Write-AfToolLog $log ('Outcome   : restarted {0}' -f $pick.Alias) }
            catch { Write-Host ('  FAILED  {0}' -f (& $show $_.Exception.Message)) -ForegroundColor Red; Write-AfToolLog $log ('Outcome   : FAILED, {0}' -f $_.Exception.Message) }
        }
        'W' {
            Write-Host '  WARNING: this resets the Windows network stack (netsh winsock reset and' -ForegroundColor Red
            Write-Host '  netsh int ip reset). It fixes broken networking after malware or bad VPN' -ForegroundColor Red
            Write-Host '  software, but it can clear static IP and VPN settings and needs a restart.' -ForegroundColor Red
            foreach ($a in @($status | Where-Object { -not $_.Dhcp })) {
                Write-Host ''
                Write-Host ('  {0} has a static IP. Write these down first:' -f (& $show $a.Alias)) -ForegroundColor Yellow
                foreach ($l in @(('IP address  {0}' -f $a.IPv4), ('Gateway     {0}' -f $a.Gateway), ('DNS         {0}' -f (@($a.Dns) -join ', ')))) { Write-Host ('    {0}' -f (& $show $l)) }
                if (-not $Settings.ShowSensitive) { Write-Host '    (Hidden: turn on Show sensitive data in Settings to see them.)' -ForegroundColor DarkGray }
                Write-AfToolLog $log ('Static IP : {0} {1} gateway {2}' -f $a.Alias, $a.IPv4, $a.Gateway)
            }
            if ((Read-AfYesNo -Prompt 'Reset Winsock and TCP/IP. Are you sure?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; Write-AfToolLog $log 'Outcome   : cancelled'; return }
            $winsock = & $RunTool 'netsh.exe' @('winsock', 'reset')
            Write-AfToolLog $log ('Winsock   : exit code {0}' -f $winsock.ExitCode)
            $ip = & $RunTool 'netsh.exe' @('int', 'ip', 'reset')
            Write-AfToolLog $log ('TCP/IP    : exit code {0}' -f $ip.ExitCode)
            $ok = $winsock.ExitCode -eq 0 -and $ip.ExitCode -eq 0
            Write-Host ('  {0}' -f @{ $true = 'OK      Reset. Restart the PC to finish.'; $false = 'FAILED  A reset step did not finish; see the log.' }[$ok]) -ForegroundColor @{ $true = 'Green'; $false = 'Red' }[$ok]
        }
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $log.Path)) -ForegroundColor DarkGray
}

function Invoke-AfNetToolsMenu {
    <#
    .SYNOPSIS
        Network tools submenu, both modes; adapter restart and the Winsock reset
        are Technician only. Each tool asks "Run it again?" at the end.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default Tool script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $Tool = { param($Key, $S) Invoke-AfNetTool -Key $Key -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey }
    )
    $itemInfo = @{
        S = @('Adapters, IP address, gateway, DNS servers and DHCP.', '', 'Changes system: NO')
        P = @('Sends 4 pings to your router, your DNS server or a name you type.', '', 'Changes system: NO', 'Says where first.')
        T = @('Shows each step to a target (tracert). Esc stops it.', '', 'Changes system: NO', 'Says where first.')
        N = @('Programs listening and open connections (like netstat -ano).', '', 'Changes system: NO')
        L = @('Asks DNS for a name (like nslookup).', '', 'Changes system: NO', 'Says where first.')
        O = @('Tests one TCP port on a target, such as 443 or 3389.', '', 'Changes system: NO', 'Says where first.')
        F = @('Clears the DNS cache (ipconfig /flushdns). Harmless.', '', 'Changes system: YES', 'Asks Y/N first.')
        R = @('ipconfig /release, then /renew. The network drops for a few seconds.', '', 'Changes system: YES', 'Asks Y/N first.')
        A = @('Restarts one network adapter.', '', 'Changes system: YES', 'Asks Y/N first.')
        W = @('netsh winsock reset and netsh int ip reset. Can clear static IP and VPN settings. Needs a restart.', '', 'Changes system: YES', 'Asks Y/N first.')
        B = @('Back to Network and domain.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $info = @('Built-in Windows network tools. Tests go only where you pick.')
    while ($true) {
        $items = @(
            @{ Key = 'S'; Label = '&Status' }
            @{ Key = 'P'; Label = '&Ping' }
            @{ Key = 'T'; Label = '&Trace route' }
            @{ Key = 'N'; Label = '&Netstat (open connections)' }
            @{ Key = 'L'; Label = 'DNS &lookup' }
            @{ Key = 'O'; Label = 'P&ort test' }
            @{ Key = 'F'; Label = '&Flush DNS'; Tags = '[CHG]' }
            @{ Key = 'R'; Label = '&Release / renew IP'; Tags = '[ADMIN] [CHG]' }
        )
        if ($Settings.Mode -eq 'Technician') {
            $items += @{ Key = 'A'; Label = 'Restart an &adapter'; Tags = '[ADMIN] [CHG]' }
            $items += @{ Key = 'W'; Label = 'Reset &Winsock and TCP/IP'; Tags = '[ADMIN] [CHG]' }
        }
        $items[-1].Divider = $true
        $items += @{ Key = 'B'; Label = '&Back' }
        $items += @{ Key = 'Q'; Label = '&Quit' }

        $choice = Select-AfMenuItem -Title 'Network tools' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        # No dead ends: the same tool again until the user says N.
        do {
            try { & $Tool $choice $Settings }
            catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
            Write-Host ''
        } while ((Read-AfYesNo -Prompt 'Run it again?' -ReadKey $ReadKey) -eq $true)
    }
}
