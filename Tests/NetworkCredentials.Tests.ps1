# Clearing saved network-drive passwords. No real cmdkey, net or klist runs here: a fake
# tool runner records each command, and keys come from a queue. A queue that runs dry
# fails the test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    function New-FakeTool([System.Collections.ArrayList] $Calls, [int] $DeleteExit = 0) {
        return {
            param($Name, $ArgumentList)
            $null = $Calls.Add(('{0} {1}' -f $Name, ($ArgumentList -join ' ')))
            $code = 0
            if ($Name -eq 'cmdkey.exe') { $code = $DeleteExit }
            [pscustomobject]@{ ExitCode = $code; Lines = @() }
        }.GetNewClosure()
    }

    $script:CmdKeyOutput = @(
        ''
        'Currently stored credentials:'
        ''
        '    Target: Domain:target=fs01.contoso.local'
        '    Type: Domain Password'
        '    User: CONTOSO\alice'
        '    Local machine persistence'
        ''
        '    Target: Domain:target=TERMSRV/rdp01'
        '    Type: Domain Password'
        '    User: CONTOSO\alice'
        ''
        '    Target: LegacyGeneric:target=MicrosoftAccount:user=alice@example.com'
        '    Type: Generic'
        '    User: alice@example.com'
        ''
        '    Ziel: Domain:target=nas02'
        '    Typ: Domaenenkennwort'
        '    Benutzer: nas02\admin'
    )
    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Entry = [pscustomobject]@{ Target = 'Domain:target=fs01.contoso.local'; Server = 'fs01.contoso.local'; User = 'CONTOSO\alice' }
}

Describe 'ConvertFrom-AfCmdKeyList' {
    It 'keeps only network-server passwords, in English and other languages' {
        $entries = @(InModuleScope AutoFixer -Parameters @{ Lines = $script:CmdKeyOutput } { param($Lines) ConvertFrom-AfCmdKeyList -Lines $Lines })
        $entries.Count | Should -Be 2
        $entries[0].Target | Should -Be 'Domain:target=fs01.contoso.local'
        $entries[0].Server | Should -Be 'fs01.contoso.local'
        $entries[0].User | Should -Be 'CONTOSO\alice'
        $entries[1].Server | Should -Be 'nas02'
        $entries[1].User | Should -Be 'nas02\admin'
    }

    It 'returns nothing for an empty vault' {
        @(InModuleScope AutoFixer { ConvertFrom-AfCmdKeyList -Lines @('Currently stored credentials:', '', '* NONE *') }).Count | Should -Be 0
    }
}

Describe 'Test-AfSameServer' {
    It 'matches a short and a full DNS name, but an IP address only to itself' {
        InModuleScope AutoFixer {
            Test-AfSameServer 'fs01' 'fs01.contoso.local' | Should -BeTrue
            Test-AfSameServer 'FS01.contoso.local' 'fs01' | Should -BeTrue
            Test-AfSameServer '192.168.1.10' '192.168.1.10' | Should -BeTrue
            Test-AfSameServer '192.168.1.10' '192.168.1.20' | Should -BeFalse
            Test-AfSameServer '192.168.1.10' '192' | Should -BeFalse
            Test-AfSameServer 'fe80::1' 'fe80::2' | Should -BeFalse
            Test-AfSameServer 'fs01' 'fs02' | Should -BeFalse
        }
    }
}

Describe 'Clear-AfNetworkCredential' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
    }

    It 'changes nothing on N' {
        $out = InModuleScope AutoFixer -Parameters @{ E = $script:Entry; S = $script:Settings; R = $script:Runs; K = (New-KeyReader 'n'); T = (New-FakeTool $script:Calls) } {
            param($E, $S, $R, $K, $T)
            Clear-AfNetworkCredential -Entries @($E) -Settings $S -OutputRoot $R -ReadKey $K -RunTool $T -GetConnections { @() } 6>$null
        }
        @($out).Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
        Test-Path $script:Runs | Should -BeFalse
    }

    It 'removes the password on Y, drops only free connections without a letter, and redacts the log' {
        $connections = @(
            [pscustomobject]@{ Server = 'fs01'; Share = 'IPC$'; Letter = $null; Open = 0 }
            [pscustomobject]@{ Server = 'fs01.contoso.local'; Share = 'Data'; Letter = 'S:'; Open = 0 }
            [pscustomobject]@{ Server = 'fs01'; Share = 'Busy'; Letter = $null; Open = 2 }
            [pscustomobject]@{ Server = 'other'; Share = 'x'; Letter = $null; Open = 0 }
        )
        $out = InModuleScope AutoFixer -Parameters @{ E = $script:Entry; S = $script:Settings; R = $script:Runs; K = (New-KeyReader 'y'); T = (New-FakeTool $script:Calls); C = $connections } {
            param($E, $S, $R, $K, $T, $C)
            $redactor = New-AfRedactor -Names 'TESTPC-01' -Serials @()
            Add-AfRedactionName -Redactor $redactor -Names @($E.Server, $E.User)
            Clear-AfNetworkCredential -Entries @($E) -Settings $S -OutputRoot $R -ReadKey $K -RunTool $T -GetConnections { $C }.GetNewClosure() -Redactor $redactor 6>$null
        }
        @($out)[0].Tag | Should -Be 'OK'
        $script:Calls | Should -Be @('cmdkey.exe /delete:Domain:target=fs01.contoso.local', 'net.exe use \\fs01\IPC$ /delete /y')
        $log = Get-ChildItem $script:Runs -Recurse -Filter 'network.log' | Get-Content -Raw
        $log | Should -Match 'OK'
        $log | Should -Not -Match 'fs01'
        $log | Should -Not -Match 'contoso'
        $log | Should -Match 'still connected as drive S:'
        $log | Should -Match '2 open file'
    }

    It 'reports a failed delete with its exit code' {
        $out = InModuleScope AutoFixer -Parameters @{ E = $script:Entry; S = $script:Settings; R = $script:Runs; K = (New-KeyReader 'y'); T = (New-FakeTool $script:Calls -DeleteExit 1168) } {
            param($E, $S, $R, $K, $T)
            Clear-AfNetworkCredential -Entries @($E) -Settings $S -OutputRoot $R -ReadKey $K -RunTool $T -GetConnections { @() } 6>$null
        }
        @($out)[0].Tag | Should -Be 'FAILED'
        @($out)[0].Detail | Should -Match '1168'
    }

    It 'offers klist purge only on a domain PC, and runs it only on Y' {
        InModuleScope AutoFixer -Parameters @{ E = $script:Entry; S = $script:Settings; R = $script:Runs; K = (New-KeyReader 'y', 'y'); T = (New-FakeTool $script:Calls) } {
            param($E, $S, $R, $K, $T)
            $null = Clear-AfNetworkCredential -Entries @($E) -Settings $S -OutputRoot $R -ReadKey $K -RunTool $T -GetConnections { @() } -OnDomain $true 6>$null
        }
        $script:Calls | Should -Contain 'klist.exe purge'
        $script:Calls.Clear()
        InModuleScope AutoFixer -Parameters @{ E = $script:Entry; S = $script:Settings; R = $script:Runs; K = (New-KeyReader 'y', 'n'); T = (New-FakeTool $script:Calls) } {
            param($E, $S, $R, $K, $T)
            $null = Clear-AfNetworkCredential -Entries @($E) -Settings $S -OutputRoot $R -ReadKey $K -RunTool $T -GetConnections { @() } -OnDomain $true 6>$null
        }
        $script:Calls | Should -Not -Contain 'klist.exe purge'
    }
}

Describe 'Invoke-AfCredentialMenu' {
    BeforeAll {
        $script:Runs = Join-Path $TestDrive 'Runs'
        $script:Two = @(
            $script:Entry
            [pscustomobject]@{ Target = 'Domain:target=nas02'; Server = 'nas02'; User = '' }
        )
    }

    It 'clears the entry picked by its number, or all of them' {
        $picked = [System.Collections.ArrayList]::new()
        $clear = { param($Chosen) $null = $picked.Add((@($Chosen | ForEach-Object Server) -join ',')) }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; E = $script:Two; Clear = $clear; K = (New-KeyReader '2', 'x', 'a', 'x', 'b') } {
            param($S, $R, $E, $Clear, $K)
            Invoke-AfCredentialMenu -Settings $S -OutputRoot $R -ReadKey $K -GetEntries { $E }.GetNewClosure() -GetConnections { @() } -Clear $Clear 6>$null
        }
        $picked | Should -Be @('nas02', 'fs01.contoso.local,nas02')
    }

    It 'goes back with a note once the last password is cleared' {
        $lists = [System.Collections.Queue]::new()
        $lists.Enqueue(@($script:Entry))
        $lists.Enqueue(@())
        $get = { $lists.Dequeue() }.GetNewClosure()
        $out = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $get; K = (New-KeyReader '1', 'x') } {
            param($S, $R, $G, $K)
            Invoke-AfCredentialMenu -Settings $S -OutputRoot $R -ReadKey $K -GetEntries $G -GetConnections { @() } -Clear { } 6>$null
        }
        $out | Should -Be 'No saved network-drive passwords left.'
    }

    It 'shows that note on Network and domain' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; K = (New-KeyReader 'c', 'b') } {
            param($S, $R, $K)
            $screen = Invoke-AfNetworkMenu -Settings $S -OutputRoot $R -ReadKey $K -Credentials { 'No saved network-drive passwords left.' } 6>&1
            (@($screen) | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'No saved network-drive passwords left'
        }
    }

    It 'says so when there is nothing saved, and goes back on Esc' {
        $called = [System.Collections.ArrayList]::new()
        $clear = { $null = $called.Add('clear') }.GetNewClosure()
        $screen = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; Clear = $clear; K = (New-KeyReader 'Escape') } {
            param($S, $R, $Clear, $K)
            Invoke-AfCredentialMenu -Settings $S -OutputRoot $R -ReadKey $K -GetEntries { @() } -GetConnections { @() } -Clear $Clear 6>&1
        }
        (@($screen) | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'No saved network-drive passwords'
        $called.Count | Should -Be 0
    }

    It 'shows server names redacted unless Show sensitive is on' {
        $hidden = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; E = $script:Two; K = (New-KeyReader 'b') } {
            param($S, $R, $E, $K)
            Invoke-AfCredentialMenu -Settings $S -OutputRoot $R -ReadKey $K -GetEntries { $E }.GetNewClosure() -GetConnections { @() } -Clear { } -Redactor (New-AfRedactor -Names @() -Serials @()) 6>&1
        }
        (@($hidden) | ForEach-Object { [string]$_ }) -join "`n" | Should -Not -Match 'fs01|nas02'
        $shown = $script:Settings.PSObject.Copy()
        $shown.ShowSensitive = $true
        $open = InModuleScope AutoFixer -Parameters @{ S = $shown; R = $script:Runs; E = $script:Two; K = (New-KeyReader 'b') } {
            param($S, $R, $E, $K)
            Invoke-AfCredentialMenu -Settings $S -OutputRoot $R -ReadKey $K -GetEntries { $E }.GetNewClosure() -GetConnections { @() } -Clear { } -Redactor (New-AfRedactor -Names @() -Serials @()) 6>&1
        }
        (@($open) | ForEach-Object { [string]$_ }) -join "`n" | Should -Match 'nas02'
    }
}
