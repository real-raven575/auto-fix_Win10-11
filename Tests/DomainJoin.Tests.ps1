# Domain check, join, trust repair and leave. Nothing touches a real domain here: the
# checks, the sign-in prompt and the domain cmdlets are fakes that record each call,
# and keys come from a queue. A queue that runs dry fails the test, which proves no
# extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    # Records each domain cmdlet; Test-ComputerSecureChannel answers from -Trust in order.
    function New-FakeComputer([System.Collections.ArrayList] $Calls, [bool[]] $Trust = @($true), [string] $Throw) {
        $answers = [System.Collections.Queue]::new()
        foreach ($t in $Trust) { $answers.Enqueue($t) }
        return {
            param($Name, $Parameters)
            $keys = @($Parameters.Keys | Sort-Object) -join ','
            $null = $Calls.Add(('{0} {1}' -f $Name, $keys).Trim())
            if ($Throw -and $Name -ne 'Test-ComputerSecureChannel') { throw $Throw }
            if ($Name -eq 'Test-ComputerSecureChannel') { return $answers.Dequeue() }
            if ($Name -eq 'Add-Computer') { $script:LastJoin = $Parameters }
        }.GetNewClosure()
    }

    function New-Status([bool] $OnDomain = $false, [bool] $CanJoin = $true) {
        $domain = ''
        $workgroup = 'WORKGROUP'
        if ($OnDomain) { $domain = 'contoso.local'; $workgroup = '' }
        $s = [pscustomobject]@{ OnDomain = $OnDomain; Domain = $domain; Workgroup = $workgroup; ComputerName = 'TESTPC-01'; Edition = 'Windows 11 Pro'; CanJoin = $CanJoin }
        return { $s }.GetNewClosure()
    }

    function New-TextReader([string[]] $Answers = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($a in $Answers) { $queue.Enqueue($a) }
        return { param($Prompt) $null = $Prompt; $queue.Dequeue() }.GetNewClosure()
    }

    $script:Pass = { param($Domain) $null = $Domain; [pscustomobject]@{ Checks = @([pscustomobject]@{ Name = 'DNS'; Tag = 'OK'; Detail = 'Found 1 domain controller(s), first dc01.contoso.local.' }); Controller = 'dc01.contoso.local'; Passed = $true } }
    $script:Fail = { param($Domain) $null = $Domain; [pscustomobject]@{ Checks = @([pscustomobject]@{ Name = 'DNS'; Tag = 'FAIL'; Detail = 'DNS has no domain controller record.' }); Controller = $null; Passed = $false } }
    $script:Cred = { param($Message) $null = $Message; [pscustomobject]@{ UserName = 'CONTOSO\admin' } }
    $script:NoCred = { param($Message) $null = $Message; $null }
    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
}

Describe 'Domain name checks' {
    It 'accepts DNS domain names and PC names, and refuses the rest' {
        InModuleScope AutoFixer {
            Test-AfDomainName 'contoso.local' | Should -BeTrue
            Test-AfDomainName 'ad.example-corp.com' | Should -BeTrue
            Test-AfDomainName 'CONTOSO' | Should -BeFalse
            Test-AfDomainName 'bad_name.local' | Should -BeFalse
            Test-AfDomainName '-x.local' | Should -BeFalse
            Test-AfComputerName 'LAPTOP-042' | Should -BeTrue
            Test-AfComputerName '12345' | Should -BeFalse
            Test-AfComputerName 'NAME-THAT-IS-TOO-LONG' | Should -BeFalse
            Test-AfComputerName 'has space' | Should -BeFalse
        }
    }

    It 'reads the clock offset from w32tm in either decimal style' {
        InModuleScope AutoFixer {
            Get-AfClockOffset -Lines @('Tracking dc01 [10.0.0.5:123].', '18:47:06, +00.0123456s') | Should -BeLessThan 1
            Get-AfClockOffset -Lines @('18:47:06, -400,5000000s') | Should -Be -400.5
            Get-AfClockOffset -Lines @('error: 0x800705B4') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-AfDomainReach' {
    BeforeAll {
        $script:Tool = {
            param($Name, $ArgumentList)
            $null = $ArgumentList
            if ($Name -eq 'nltest.exe') { return [pscustomobject]@{ ExitCode = 0; Lines = @('           DC: \\dc01.contoso.local') } }
            return [pscustomobject]@{ ExitCode = 0; Lines = @($script:ClockLine) }
        }
    }

    It 'passes when DNS, the locator, the ports and the clock all answer' {
        $script:ClockLine = '18:47:06, +00.0100000s'
        $r = InModuleScope AutoFixer -Parameters @{ T = $script:Tool } {
            param($T)
            Test-AfDomainReach -Domain 'contoso.local' -RunTool $T -Resolve { @('dc01.contoso.local') } -TestPort { $true }
        }
        $r.Passed | Should -BeTrue
        $r.Controller | Should -Be 'dc01.contoso.local'
        @($r.Checks | Where-Object Tag -NE 'OK').Count | Should -Be 0
    }

    It 'fails on a clock more than 5 minutes off, or a blocked port' {
        $script:ClockLine = '18:47:06, +400.0000000s'
        $r = InModuleScope AutoFixer -Parameters @{ T = $script:Tool } {
            param($T)
            Test-AfDomainReach -Domain 'contoso.local' -RunTool $T -Resolve { @('dc01.contoso.local') } -TestPort { param($S, $P) $null = $S; $P -ne 445 }
        }
        $r.Passed | Should -BeFalse
        ($r.Checks | Where-Object Name -EQ 'Clock').Tag | Should -Be 'FAIL'
        ($r.Checks | Where-Object Name -EQ 'Port 445').Tag | Should -Be 'FAIL'
    }

    It 'fails when DNS cannot find the domain' {
        $r = InModuleScope AutoFixer -Parameters @{ T = { param($Name, $ArgumentList) $null = $Name, $ArgumentList; [pscustomobject]@{ ExitCode = 1355; Lines = @() } } } {
            param($T)
            Test-AfDomainReach -Domain 'nowhere.local' -RunTool $T -Resolve { throw 'DNS name does not exist' } -TestPort { $true }
        }
        $r.Passed | Should -BeFalse
        ($r.Checks | Where-Object Name -EQ 'DNS').Tag | Should -Be 'FAIL'
        ($r.Checks | Where-Object Name -EQ 'Locator').Detail | Should -Match '1355'
    }
}

Describe 'Invoke-AfDomainJoin' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Restarts = [System.Collections.ArrayList]::new()
        $restarts = $script:Restarts
        $script:RestartCall = { $null = $restarts.Add('restart') }.GetNewClosure()
    }

    It 'does nothing without administrator rights, on a domain PC, or on Home' {
        foreach ($case in @(
                @{ Admin = $false; Status = (New-Status) }
                @{ Admin = $true; Status = (New-Status -OnDomain $true) }
                @{ Admin = $true; Status = (New-Status -CanJoin $false) }
            )) {
            InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; A = $case.Admin; St = $case.Status; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K2 = (New-KeyReader); T2 = (New-TextReader) } {
                param($S, $R, $A, $St, $C, $Rs, $K2, $T2)
                Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K2 -ReadText $T2 -IsAdmin $A -GetStatus $St -Reach { throw 'no check' } -GetCredential { throw 'no prompt' } -Computer $C -Restart $Rs 6>$null
            }
        }
        $script:Calls.Count | Should -Be 0
        $script:Restarts.Count | Should -Be 0
    }

    It 'stops before any question when a check fails' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status); Reach = $script:Fail; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K2 = (New-KeyReader); T2 = (New-TextReader 'contoso.local') } {
            param($S, $R, $St, $Reach, $C, $Rs, $K2, $T2)
            Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K2 -ReadText $T2 -IsAdmin $true -GetStatus $St -Reach $Reach -GetCredential { throw 'no prompt' } -Computer $C -Restart $Rs 6>$null
        }
        $script:Calls.Count | Should -Be 0
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-domain.log' | Get-Content -Raw | Should -Match 'not started'
    }

    It 'refuses a bad domain name, PC name or OU without asking anything else' {
        foreach ($answers in @(@('CONTOSO'), @('contoso.local', 'bad name'), @('contoso.local', '', 'Laptops'))) {
            InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status); Reach = $script:Pass; Text = (New-TextReader $answers); C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K2 = (New-KeyReader) } {
                param($S, $R, $St, $Reach, $Text, $C, $Rs, $K2)
                Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K2 -ReadText $Text -IsAdmin $true -GetStatus $St -Reach $Reach -GetCredential { throw 'no prompt' } -Computer $C -Restart $Rs 6>$null
            }
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'changes nothing on N at the credential or local administrator warning, or a cancelled sign-in' {
        foreach ($case in @(@{ Keys = @('n'); Cred = $script:Cred }, @{ Keys = @('y', 'n'); Cred = $script:Cred }, @{ Keys = @('y', 'y'); Cred = $script:NoCred })) {
            InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status); Reach = $script:Pass; K = (New-KeyReader $case.Keys); G = $case.Cred; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; T2 = (New-TextReader 'contoso.local', '', '') } {
                param($S, $R, $St, $Reach, $K, $G, $C, $Rs, $T2)
                Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T2 -IsAdmin $true -GetStatus $St -Reach $Reach -GetCredential $G -Computer $C -Restart $Rs 6>$null
            }
        }
        $script:Calls.Count | Should -Be 0
        $script:Restarts.Count | Should -Be 0
    }

    It 'joins after Y, Y and the sign-in, with the new name and OU, and restarts only on Y' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status); Reach = $script:Pass; G = $script:Cred; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K2 = (New-KeyReader 'y', 'y', 'n'); T2 = (New-TextReader 'contoso.local', 'LAPTOP-042', 'OU=Laptops,DC=contoso,DC=local') } {
            param($S, $R, $St, $Reach, $G, $C, $Rs, $K2, $T2)
            Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K2 -ReadText $T2 `
                -IsAdmin $true -GetStatus $St -Reach $Reach -GetCredential $G -Computer $C -Restart $Rs 6>$null
        }
        $script:Calls | Should -Be @('Add-Computer Credential,DomainName,NewName,OUPath')
        $script:Restarts.Count | Should -Be 0
        $log = Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-domain.log' | Get-Content -Raw
        $log | Should -Match 'joined'
        $log | Should -Not -Match 'contoso|TESTPC-01|LAPTOP-042|admin'

        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status); Reach = $script:Pass; G = $script:Cred; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K2 = (New-KeyReader 'y', 'y', 'y'); T2 = (New-TextReader 'contoso.local', '', '') } {
            param($S, $R, $St, $Reach, $G, $C, $Rs, $K2, $T2)
            Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K2 -ReadText $T2 `
                -IsAdmin $true -GetStatus $St -Reach $Reach -GetCredential $G -Computer $C -Restart $Rs 6>$null
        }
        $script:Calls[1] | Should -Be 'Add-Computer Credential,DomainName'
        $script:Restarts.Count | Should -Be 1
    }

    It 'reports a failed join and never offers the restart' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status); Reach = $script:Pass; G = $script:Cred; C = (New-FakeComputer $script:Calls -Throw 'Access is denied'); Rs = $script:RestartCall; K2 = (New-KeyReader 'y', 'y'); T2 = (New-TextReader 'contoso.local', '', '') } {
            param($S, $R, $St, $Reach, $G, $C, $Rs, $K2, $T2)
            Invoke-AfDomainJoin -Settings $S -OutputRoot $R -ReadKey $K2 -ReadText $T2 `
                -IsAdmin $true -GetStatus $St -Reach $Reach -GetCredential $G -Computer $C -Restart $Rs 6>$null
        }
        $script:Restarts.Count | Should -Be 0
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-domain.log' | Get-Content -Raw | Should -Match 'FAILED, Access is denied'
    }
}

Describe 'Invoke-AfDomainTrustRepair' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
    }

    It 'asks nothing when the trust is healthy' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status -OnDomain $true); C = (New-FakeComputer $script:Calls -Trust $true); K2 = (New-KeyReader) } {
            param($S, $R, $St, $C, $K2)
            Invoke-AfDomainTrustRepair -Settings $S -OutputRoot $R -ReadKey $K2 -IsAdmin $true -GetStatus $St -GetCredential { throw 'no prompt' } -Computer $C 6>$null
        }
        $script:Calls | Should -Be @('Test-ComputerSecureChannel')
    }

    It 'repairs a broken trust after Y and the sign-in, then tests it again' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status -OnDomain $true); G = $script:Cred; C = (New-FakeComputer $script:Calls -Trust $false, $true, $true); K2 = (New-KeyReader 'y') } {
            param($S, $R, $St, $G, $C, $K2)
            Invoke-AfDomainTrustRepair -Settings $S -OutputRoot $R -ReadKey $K2 -IsAdmin $true -GetStatus $St -GetCredential $G -Computer $C 6>$null
        }
        $script:Calls | Should -Be @('Test-ComputerSecureChannel', 'Test-ComputerSecureChannel Credential,Repair', 'Test-ComputerSecureChannel')
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-domain.log' | Get-Content -Raw | Should -Match 'repaired'
    }

    It 'changes nothing on N' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status -OnDomain $true); C = (New-FakeComputer $script:Calls -Trust $false); K2 = (New-KeyReader 'n') } {
            param($S, $R, $St, $C, $K2)
            Invoke-AfDomainTrustRepair -Settings $S -OutputRoot $R -ReadKey $K2 -IsAdmin $true -GetStatus $St -GetCredential { throw 'no prompt' } -Computer $C 6>$null
        }
        $script:Calls | Should -Be @('Test-ComputerSecureChannel')
    }
}

Describe 'Invoke-AfDomainLeave' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Restarts = [System.Collections.ArrayList]::new()
        $restarts = $script:Restarts
        $script:RestartCall = { $null = $restarts.Add('restart') }.GetNewClosure()
    }

    It 'changes nothing on N, or on a PC that is not on a domain' {
        foreach ($st in @((New-Status -OnDomain $true), (New-Status))) {
            InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = $st; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K = (New-KeyReader 'n') } {
                param($S, $R, $St, $C, $Rs, $K)
                Invoke-AfDomainLeave -Settings $S -OutputRoot $R -ReadKey $K -IsAdmin $true -GetStatus $St -GetCredential { throw 'no prompt' } -Computer $C -Restart $Rs 6>$null
            }
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'leaves into WORKGROUP after Y and the sign-in, and restarts only on Y' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; St = (New-Status -OnDomain $true); G = $script:Cred; C = (New-FakeComputer $script:Calls); Rs = $script:RestartCall; K2 = (New-KeyReader 'y', 'y') } {
            param($S, $R, $St, $G, $C, $Rs, $K2)
            Invoke-AfDomainLeave -Settings $S -OutputRoot $R -ReadKey $K2 -IsAdmin $true -GetStatus $St -GetCredential $G -Computer $C -Restart $Rs 6>$null
        }
        $script:Calls | Should -Be @('Remove-Computer Force,UnjoinDomainCredential,WorkgroupName')
        $script:Restarts.Count | Should -Be 1
    }
}

Describe 'Invoke-AfDomainCheck' {
    It 'runs only read-only steps, and redacts the domain on screen' {
        $calls = [System.Collections.ArrayList]::new()
        $standard = $script:Settings.PSObject.Copy()
        $standard.Mode = 'Standard'
        $screen = InModuleScope AutoFixer -Parameters @{ S = $standard; R = (Join-Path $TestDrive 'check'); St = (New-Status -OnDomain $true); Reach = $script:Pass; C = (New-FakeComputer $calls -Trust $true) } {
            param($S, $R, $St, $Reach, $C)
            Invoke-AfDomainCheck -Settings $S -OutputRoot $R -ReadText { throw 'no question' } -IsAdmin $true -GetStatus $St -Reach $Reach -Computer $C 6>&1
        }
        $calls | Should -Be @('Test-ComputerSecureChannel')
        $text = (@($screen) | ForEach-Object { [string]$_ }) -join "`n"
        $text | Should -Match 'trust with the domain is healthy'
        $text | Should -Not -Match 'contoso'
    }

    It 'skips the test when no domain is typed on a workgroup PC' {
        $calls = [System.Collections.ArrayList]::new()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = (Join-Path $TestDrive 'skip'); St = (New-Status); C = (New-FakeComputer $calls); T2 = (New-TextReader '') } {
            param($S, $R, $St, $C, $T2)
            Invoke-AfDomainCheck -Settings $S -OutputRoot $R -ReadText $T2 -IsAdmin $true -GetStatus $St -Reach { throw 'no check' } -Computer $C 6>$null
        }
        $calls.Count | Should -Be 0
    }
}

Describe 'Invoke-AfNetworkMenu' {
    BeforeAll {
        $script:Picked = [System.Collections.ArrayList]::new()
        $picked = $script:Picked
        $script:Actions = @{}
        foreach ($name in 'Credentials', 'Check', 'Join', 'Trust', 'Leave') {
            $script:Actions[$name] = { param($S) $null = $S; $null = $picked.Add($name) }.GetNewClosure()
        }
    }
    BeforeEach { $script:Picked.Clear() }

    It 'shows join, trust repair and leave only in Technician mode' {
        $standard = $script:Settings.PSObject.Copy()
        $standard.Mode = 'Standard'
        # Standard: J is unknown, then D runs the check (one key to return), then Back.
        InModuleScope AutoFixer -Parameters @{ S = $standard; R = $TestDrive; A = $script:Actions; K = (New-KeyReader 'j', 'd', 'x', 'b') } {
            param($S, $R, $A, $K)
            Invoke-AfNetworkMenu -Settings $S -OutputRoot $R -ReadKey $K -Credentials $A.Credentials -Check $A.Check -Join $A.Join -Trust $A.Trust -Leave $A.Leave 6>$null
        }
        $script:Picked | Should -Be @('Check')
        $script:Picked.Clear()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $TestDrive; A = $script:Actions; K = (New-KeyReader 'j', 'x', 't', 'x', 'l', 'x', 'c', 'Escape') } {
            param($S, $R, $A, $K)
            Invoke-AfNetworkMenu -Settings $S -OutputRoot $R -ReadKey $K -Credentials $A.Credentials -Check $A.Check -Join $A.Join -Trust $A.Trust -Leave $A.Leave 6>$null
        }
        $script:Picked | Should -Be @('Join', 'Trust', 'Leave', 'Credentials')
    }

    It 'opens from the main menu with N and with 3' {
        $opened = [System.Collections.ArrayList]::new()
        $network = { param($S) $null = $S; $null = $opened.Add('network') }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -NetworkAction $network `
            -ReadKey (New-KeyReader 'Enter', 'n', '3', 'q', 'y') 6>$null
        $opened.Count | Should -Be 2
    }
}
