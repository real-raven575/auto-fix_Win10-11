# Network tools. Nothing touches the real network here: the status, the programs and
# the cmdlets are fakes that record each call, and keys come from a queue. A queue
# that runs dry fails the test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    function New-TextReader([string[]] $Answers = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($a in $Answers) { $queue.Enqueue($a) }
        return { param($Prompt) $null = $Prompt; $queue.Dequeue() }.GetNewClosure()
    }

    # Records 'name arg arg' for each program run and answers with ExitCode 0.
    function New-FakeTool([System.Collections.ArrayList] $Calls, [int] $ExitCode = 0) {
        return {
            param($Name, $ArgumentList)
            $null = $Calls.Add((@($Name) + @($ArgumentList)) -join ' ')
            [pscustomobject]@{ ExitCode = $ExitCode; Lines = @('Reply from 192.168.50.1: bytes=32 time=1ms TTL=64') }
        }.GetNewClosure()
    }

    $script:Status = {
        @([pscustomobject]@{ Alias = 'Ethernet'; Description = 'Test NIC'; Status = 'Up'; IPv4 = '192.168.50.20'; Gateway = '192.168.50.1'; Dns = @('192.168.50.2'); Dhcp = $false })
    }
    $script:Technician = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Standard = $script:Technician.PSObject.Copy()
    $script:Standard.Mode = 'Standard'

    function Invoke-Tool([string] $Key, $Settings, [string[]] $Keys = @(), [string[]] $Text = @(), [bool] $Admin = $true, $Calls) {
        $runs = Join-Path $TestDrive ([guid]::NewGuid())
        $screen = InModuleScope AutoFixer -Parameters @{ Key = $Key; S = $Settings; R = $runs; K = (New-KeyReader $Keys); T = (New-TextReader $Text); A = $Admin; St = $script:Status; Run = (New-FakeTool $Calls); C = $Calls } {
            param($Key, $S, $R, $K, $T, $A, $St, $Run, $C)
            $stream = { param($Name, $ArgumentList, $Show) $null = $Show; & $Run $Name $ArgumentList | Add-Member -NotePropertyName Stopped -NotePropertyValue $false -PassThru }.GetNewClosure()
            $restart = { param($Alias) $null = $C.Add("Restart-NetAdapter $Alias") }.GetNewClosure()
            Invoke-AfNetTool -Key $Key -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -IsAdmin $A -Remote $false -GetStatus $St -RunTool $Run `
                -Stream $stream `
                -Lookup { param($Target) $null = $Target; @('www.example.com  A  93.184.215.14') } -TestPort { param($Target, $Port) $null = $Target; $Port -eq 443 } `
                -GetConnections { @([pscustomobject]@{ State = 'Listen'; Local = '0.0.0.0:135'; Remote = '0.0.0.0:0'; Program = 'svchost' }, [pscustomobject]@{ State = 'Established'; Local = '192.168.50.20:50000'; Remote = '93.184.215.14:443'; Program = 'browser' }) } `
                -RestartAdapter $restart 6>&1
        }
        $log = @(Get-ChildItem $runs -Recurse -Filter 'nettools.log' -ErrorAction SilentlyContinue | Get-Content -Raw) -join ''
        return [pscustomobject]@{ Screen = ((@($screen) | ForEach-Object { [string]$_ }) -join "`n"); Log = $log }
    }
}

Describe 'Network tool targets' {
    It 'accepts IP addresses and host names, and refuses the rest' {
        InModuleScope AutoFixer {
            Test-AfNetTarget '192.168.1.1' | Should -BeNullOrEmpty
            Test-AfNetTarget 'www.example.com' | Should -BeNullOrEmpty
            Test-AfNetTarget 'fe80::1' | Should -BeNullOrEmpty
            Test-AfNetTarget 'PRINTER01' | Should -BeNullOrEmpty
            Test-AfNetTarget 'not a name' | Should -Match 'not an IP address'
            Test-AfNetTarget 'bad_name.com' | Should -Match 'not an IP address'
        }
    }
}

Describe 'Invoke-AfNetTool' {
    BeforeEach { $script:Calls = [System.Collections.ArrayList]::new() }

    It 'pings the gateway after saying where, and hides the addresses on screen and in the log' {
        $r = Invoke-Tool -Key 'P' -Settings $script:Standard -Keys @('1') -Calls $script:Calls
        $script:Calls | Should -Be @('ping.exe -n 4 192.168.50.1')
        $r.Screen | Should -Match 'Sending 4 pings to'
        $r.Screen | Should -Match 'It answered'
        $r.Screen | Should -Not -Match '192\.168\.50'
        $r.Log | Should -Match 'Outcome'
        $r.Log | Should -Not -Match '192\.168\.50'
    }

    It 'traces a typed name after a typo, and keeps the name out of the log' {
        $r = Invoke-Tool -Key 'T' -Settings $script:Standard -Keys @('t') -Text @('bad name', 'www.example.com') -Calls $script:Calls
        $script:Calls | Should -Be @('tracert.exe -d -h 30 -w 1000 www.example.com')
        $r.Screen | Should -Match 'Tracing the route to'
        $r.Log | Should -Not -Match 'example'
    }

    It 'sends nothing on Esc at "Where to?" or Enter at the typed name' {
        foreach ($case in @(@{ Keys = @('Escape'); Text = @() }, @{ Keys = @('t'); Text = @('') })) {
            $r = Invoke-Tool -Key 'P' -Settings $script:Standard -Keys $case.Keys -Text $case.Text -Calls $script:Calls
            $r.Screen | Should -Match 'Nothing was sent'
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'looks up a name and tests a port' {
        (Invoke-Tool -Key 'L' -Settings $script:Standard -Keys @('t') -Text @('www.example.com') -Calls $script:Calls).Screen | Should -Match 'The name was found'
        (Invoke-Tool -Key 'O' -Settings $script:Standard -Keys @('2') -Text @('x', '443') -Calls $script:Calls).Screen | Should -Match 'The port is open'
        (Invoke-Tool -Key 'O' -Settings $script:Standard -Keys @('2') -Text @('22') -Calls $script:Calls).Screen | Should -Match 'did not answer'
        $script:Calls.Count | Should -Be 0
    }

    It 'counts listening programs and open connections, read-only' {
        $r = Invoke-Tool -Key 'N' -Settings $script:Standard -Calls $script:Calls
        $r.Screen | Should -Match '1 programs are listening, 1 connections are open'
        $r.Screen | Should -Match 'browser'
        $r.Log | Should -Not -Match '93\.184'
    }

    It 'flushes DNS and renews the address only on Y' {
        Invoke-Tool -Key 'F' -Settings $script:Standard -Keys @('n') -Calls $script:Calls | Out-Null
        Invoke-Tool -Key 'R' -Settings $script:Standard -Keys @('n') -Calls $script:Calls | Out-Null
        $script:Calls.Count | Should -Be 0
        Invoke-Tool -Key 'F' -Settings $script:Standard -Keys @('y') -Calls $script:Calls | Out-Null
        Invoke-Tool -Key 'R' -Settings $script:Standard -Keys @('y') -Calls $script:Calls | Out-Null
        $script:Calls | Should -Be @('ipconfig.exe /flushdns', 'ipconfig.exe /release', 'ipconfig.exe /renew')
    }

    It 'needs administrator rights for release/renew, and Technician mode for adapter restart and reset' {
        (Invoke-Tool -Key 'R' -Settings $script:Standard -Admin $false -Calls $script:Calls).Screen | Should -Match 'administrator rights'
        (Invoke-Tool -Key 'A' -Settings $script:Standard -Calls $script:Calls).Screen | Should -Match 'Technician mode only'
        (Invoke-Tool -Key 'W' -Settings $script:Standard -Calls $script:Calls).Screen | Should -Match 'Technician mode only'
        $script:Calls.Count | Should -Be 0
    }

    It 'restarts the picked adapter after Y' {
        Invoke-Tool -Key 'A' -Settings $script:Technician -Keys @('1', 'n') -Calls $script:Calls | Out-Null
        $script:Calls.Count | Should -Be 0
        Invoke-Tool -Key 'A' -Settings $script:Technician -Keys @('1', 'y') -Calls $script:Calls | Out-Null
        $script:Calls | Should -Be @('Restart-NetAdapter Ethernet')
    }

    It 'shows a static IP to write down before the Winsock reset, and resets only on Y' {
        $r = Invoke-Tool -Key 'W' -Settings $script:Technician -Keys @('n') -Calls $script:Calls
        $r.Screen | Should -Match 'has a static IP'
        $script:Calls.Count | Should -Be 0
        $r = Invoke-Tool -Key 'W' -Settings $script:Technician -Keys @('y') -Calls $script:Calls
        $script:Calls | Should -Be @('netsh.exe winsock reset', 'netsh.exe int ip reset')
        $r.Screen | Should -Match 'Restart the PC to finish'
        $r.Log | Should -Match 'Static IP'
        $r.Log | Should -Not -Match '192\.168\.50'
    }
}

Describe 'Invoke-AfNetToolsMenu' {
    BeforeAll {
        $script:Picked = [System.Collections.ArrayList]::new()
        $picked = $script:Picked
        $script:FakeTool = { param($Key, $S) $null = $S; $null = $picked.Add($Key) }.GetNewClosure()
    }
    BeforeEach { $script:Picked.Clear() }

    It 'hides adapter restart and the reset in Standard mode' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Standard; R = $TestDrive; Tl = $script:FakeTool; K = (New-KeyReader 'a', 'w', 'f', 'n', 'b') } {
            param($S, $R, $Tl, $K)
            Invoke-AfNetToolsMenu -Settings $S -OutputRoot $R -ReadKey $K -Tool $Tl 6>$null
        }
        $script:Picked | Should -Be @('F')
    }

    It 'runs the same tool again on Y at "Run it again?"' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Technician; R = $TestDrive; Tl = $script:FakeTool; K = (New-KeyReader 'p', 'y', 'n', 'w', 'n', 'Escape') } {
            param($S, $R, $Tl, $K)
            Invoke-AfNetToolsMenu -Settings $S -OutputRoot $R -ReadKey $K -Tool $Tl 6>$null
        }
        $script:Picked | Should -Be @('P', 'P', 'W')
    }

    It 'opens from Network and domain with W in both modes' {
        $opened = [System.Collections.ArrayList]::new()
        $tools = { param($S) $null = $opened.Add($S.Mode) }.GetNewClosure()
        foreach ($s in @($script:Standard, $script:Technician)) {
            InModuleScope AutoFixer -Parameters @{ S = $s; R = $TestDrive; N = $tools; K = (New-KeyReader 'w', 'b') } {
                param($S, $R, $N, $K)
                Invoke-AfNetworkMenu -Settings $S -OutputRoot $R -ReadKey $K -NetTools $N 6>$null
            }
        }
        $opened | Should -Be @('Standard', 'Technician')
    }
}
