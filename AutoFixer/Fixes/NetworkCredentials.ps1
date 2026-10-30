# Quick clear of saved network-drive passwords (roadmap 5a, raven575 2026-10-28).
#   - lists first; nothing changes until the user picks an entry and answers Y
#   - only network-server entries (Domain:target=...) are offered; web, Microsoft
#     account, Office and Remote Desktop entries are never listed for clearing
#   - never reads or shows a password (cmdkey cannot show one anyway)
#   - a connection with open files is never dropped
#   - names are redacted on screen (unless Show sensitive is on) and always in the log

function Invoke-AfTool {
    # Runs a Windows program by its full path and returns its exit code and output lines.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $ArgumentList = @()
    )

    $exe = Get-AfSystemToolPath $Name
    $lines = @(& $exe @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

function ConvertFrom-AfCmdKeyList {
    <#
    .SYNOPSIS
        Reads the output of cmdkey /list and returns the network-server entries:
        Target (as cmdkey needs it to delete), Server and User. The labels are
        translated on non-English Windows, so entries are found by the target text.
    #>
    [CmdletBinding()]
    param([string[]] $Lines = @())

    $entries = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in $Lines) {
        $target = [regex]::Match($line, '(?i)\b(Domain|LegacyGeneric|WindowsLive|Generic):target=(\S.*?)\s*$')
        if ($target.Success) {
            $current = $null
            $server = $target.Groups[2].Value
            # Domain passwords are what Windows uses for shares; TERMSRV/ is Remote Desktop.
            if ($target.Groups[1].Value -ieq 'Domain' -and $server -notmatch '(?i)^TERMSRV/') {
                $current = [pscustomobject]@{ Target = ('Domain:target={0}' -f $server); Server = $server; User = '' }
                $entries.Add($current)
            }
            continue
        }
        # 'User:' in English; other languages use their own word before the colon.
        $user = [regex]::Match($line, '^\s*[^:\s]+:\s*(\S.*?)\s*$')
        if ($current -and -not $current.User -and $user.Success -and $line -match '(?i)^\s*(User|Benutzer|Utilisateur|Usuario|Utente|Gebruiker)\s*:') {
            $current.User = $user.Groups[1].Value
        }
    }
    return $entries.ToArray()
}

function Get-AfShareConnection {
    <#
    .SYNOPSIS
        Open connections to file shares for this user: Server, Share, Letter (if
        mapped) and Open (files open on it). Read-only. Empty where the SMB
        cmdlets are missing.
    #>
    [CmdletBinding()]
    param()

    $mapped = @{}
    try {
        foreach ($m in @(Get-SmbMapping -ErrorAction Stop)) { $mapped[([string]$m.RemotePath).ToLowerInvariant()] = [string]$m.LocalPath }
    }
    catch { Write-Verbose ('Get-SmbMapping: {0}' -f $_.Exception.Message) }
    try {
        return @(Get-SmbConnection -ErrorAction Stop | ForEach-Object {
                $path = ('\\{0}\{1}' -f $_.ServerName, $_.ShareName)
                [pscustomobject]@{ Server = [string]$_.ServerName; Share = [string]$_.ShareName; Letter = $mapped[$path.ToLowerInvariant()]; Open = [int]$_.NumOpens }
            })
    }
    catch {
        Write-Verbose ('Get-SmbConnection: {0}' -f $_.Exception.Message)
        return @()
    }
}

function Test-AfSameServer {
    # 'fs01' and 'fs01.contoso.local' are the same server for this purpose. An IP
    # address only matches itself: 192.168.1.10 is not 192.168.1.20.
    param([string] $A, [string] $B)
    if (-not $A -or -not $B) { return $false }
    $ip = $null
    if ([Net.IPAddress]::TryParse($A, [ref]$ip) -or [Net.IPAddress]::TryParse($B, [ref]$ip)) { return $A -ieq $B }
    return (($A -split '\.')[0]) -ieq (($B -split '\.')[0])
}

function Clear-AfNetworkCredential {
    <#
    .SYNOPSIS
        Removes the chosen saved passwords after a Y, drops the matching connections
        that have no drive letter and no open files, and writes a redacted log.
        Returns one result per entry: Server, Tag (OK, FAILED) and Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Entries,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        $Redactor = (New-AfRedactor),
        # Gets Name and ArgumentList by name; returns ExitCode and Lines.
        [scriptblock] $RunTool = { param($Name, $ArgumentList) Invoke-AfTool -Name $Name -ArgumentList $ArgumentList },
        [scriptblock] $GetConnections = { Get-AfShareConnection },
        [bool] $OnDomain = $false
    )

    $screenRedactor = $Redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screenRedactor -Text $Text }

    Write-Host ''
    Write-Host '  These saved passwords will be removed:' -ForegroundColor White
    foreach ($e in $Entries) { Write-Host ('    {0}' -f (& $show $e.Server)) }
    Write-Host ''
    Write-Host '  Next time a drive on these servers opens, Windows asks for the username' -ForegroundColor Yellow
    Write-Host '  and password. If you do not know them, stop now. Windows cannot undo this.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Remove them?' -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return @()
    }

    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -FileName 'network.log' -Redactor $Redactor -Task 'clear saved network-drive passwords'
    $log = { param([string] $Text) Write-AfToolLog $toolLog $Text }

    $results = foreach ($e in $Entries) {
        $r = & $RunTool -Name 'cmdkey.exe' -ArgumentList @(('/delete:{0}' -f $e.Target))
        $tag = 'OK'
        $detail = 'Saved password removed.'
        if ($r.ExitCode -ne 0) {
            $tag = 'FAILED'
            $detail = 'cmdkey exit code {0}: {1}' -f $r.ExitCode, ((@($r.Lines) | Where-Object { $_ }) -join ' ')
        }
        & $log ('{0,-7}{1}  {2}' -f $tag, $e.Server, $detail)
        [pscustomobject]@{ Server = $e.Server; Tag = $tag; Detail = $detail }
    }

    # Windows keeps using the old login while a connection is open.
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(& $GetConnections)) {
        if (-not (@($results | Where-Object { $_.Tag -eq 'OK' -and (Test-AfSameServer $_.Server $c.Server) }).Count)) { continue }
        $path = '\\{0}\{1}' -f $c.Server, $c.Share
        if ($c.Letter) { $kept.Add(('{0} is still connected as drive {1}' -f $path, $c.Letter)); continue }
        if ($c.Open -gt 0) { $kept.Add(('{0} has {1} open file(s), so it stays connected' -f $path, $c.Open)); continue }
        $r = & $RunTool -Name 'net.exe' -ArgumentList @('use', $path, '/delete', '/y')
        & $log ('{0,-7}{1}  disconnect, net use exit code {2}' -f @{ $true = 'OK'; $false = 'FAILED' }[$r.ExitCode -eq 0], $path, $r.ExitCode)
    }

    if ($OnDomain -and @($results | Where-Object Tag -EQ 'OK').Count) {
        Write-Host ''
        Write-Host '  This PC is on a domain. Windows may also hold sign-in tickets for these servers.' -ForegroundColor White
        if ((Read-AfYesNo -Prompt 'Clear your Kerberos tickets too (klist purge)?' -ReadKey $ReadKey) -eq $true) {
            $r = & $RunTool -Name 'klist.exe' -ArgumentList @('purge')
            & $log ('{0,-7}klist purge, exit code {1}' -f @{ $true = 'OK'; $false = 'FAILED' }[$r.ExitCode -eq 0], $r.ExitCode)
        }
    }

    Write-Host ''
    Write-Host '  Summary' -ForegroundColor White
    foreach ($r in $results) {
        $color = 'Green'
        if ($r.Tag -ne 'OK') { $color = 'Red' }
        Write-Host ('  {0,-8}{1}  {2}' -f $r.Tag, (& $show $r.Server), (& $show $r.Detail)) -ForegroundColor $color
    }
    foreach ($k in $kept) {
        Write-Host ('  {0}.' -f (& $show $k)) -ForegroundColor Yellow
        & $log ('Kept      : {0}' -f $k)
    }
    # An elevated Auto-Fixer sees only its own connections and tickets, not the ones Explorer uses.
    if (@($results | Where-Object Tag -EQ 'OK').Count) { Write-Host '  Sign out and back in, or restart, so every program stops using the old login.' -ForegroundColor Yellow }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return $results
}

function Invoke-AfCredentialMenu {
    # The saved network passwords screen, opened from Network and domain.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default Clear script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $GetEntries = { ConvertFrom-AfCmdKeyList -Lines (Invoke-AfTool -Name 'cmdkey.exe' -ArgumentList '/list').Lines },
        [scriptblock] $GetConnections = { Get-AfShareConnection },
        # Called with the chosen entries.
        [scriptblock] $Clear = { param([object[]] $Chosen) $null = Clear-AfNetworkCredential -Entries $Chosen -Settings $Settings -OutputRoot $OutputRoot -ReadKey $ReadKey -Redactor $Redactor -OnDomain (Get-AfDomainStatus).OnDomain },
        $Redactor = (New-AfRedactor)
    )

    $screenRedactor = $Redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $info = @('Saved passwords for network drives and shares, for the Windows account running Auto-Fixer. Pick one, or all. Nothing changes until you answer Y.')
    $notice = $null
    $cleared = $false
    while ($true) {
        $entries = @(& $GetEntries)
        # After the last one is removed an empty list only offers Back, so go back with a note.
        if ($cleared -and -not $entries.Count) { return 'No saved network-drive passwords left.' }
        $connections = @(& $GetConnections)
        Add-AfRedactionName -Redactor $Redactor -Names (@($entries | ForEach-Object { $_.Server; $_.User }) + @($connections | ForEach-Object { $_.Server }))
        $items = New-Object System.Collections.Generic.List[object]
        $itemInfo = @{}
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            $letters = @($connections | Where-Object { $_.Letter -and (Test-AfSameServer $_.Server $e.Server) } | ForEach-Object { $_.Letter } | Select-Object -Unique)
            $label = Protect-AfText -Redactor $screenRedactor -Text $e.Server
            if ($letters.Count) { $label += '  (drive {0})' -f ($letters -join ' ') }
            # The menu box ends at column 51.
            if ($label.Length -gt 38) { $label = $label.Substring(0, 35) + '...' }
            $key = 'E{0}' -f $i
            $items.Add(@{ Key = $key; Label = $label })
            $user = '(not shown)'
            if ($e.User) { $user = Protect-AfText -Redactor $screenRedactor -Text $e.User }
            $itemInfo[$key] = @('Saved password for this server.', '', ('Account: {0}' -f $user), '', 'Changes system: YES', 'Asks Y/N first.')
        }
        if ($entries.Count -gt 1) {
            $items.Add(@{ Key = 'A'; Label = '&All of them'; Divider = $true })
            $itemInfo['A'] = @('Removes every saved network-server password listed here.', '', 'Changes system: YES', 'Asks Y/N first.')
        }
        $items.Add(@{ Key = 'B'; Label = '&Back' })
        $items.Add(@{ Key = 'Q'; Label = '&Quit' })
        $itemInfo['B'] = @('Back to Network and domain.')
        $itemInfo['Q'] = @('Closes Auto-Fixer. Asks first.')
        if (-not $entries.Count -and -not $notice) { $notice = 'No saved network-drive passwords were found.' }

        $choice = Select-AfMenuItem -Title 'Saved network passwords' -Items $items.ToArray() -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        $chosen = $entries
        if ($choice -ne 'A') { $chosen = @($entries[[int]$choice.Substring(1)]) }
        try { & $Clear $chosen }
        catch { Write-Host ('  Clearing stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        $cleared = $true
        Write-Host ''
        Write-Host '  Press any key to return.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
