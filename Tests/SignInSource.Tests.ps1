# Sign-in source check. Nothing runs dsregcmd, nltest or DNS here: the tools are fakes
# that return sample output (made-up names such as contoso.local and DC01), so every
# join type and failure can be tested on any PC.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    # dsregcmd /status output with the device section first, as Windows prints it.
    function New-DsregLines([string] $Aad = 'NO', [string] $Dom = 'NO', [string] $Workplace = 'NO', [string] $Domain = '', [string] $Tenant = '') {
        $lines = @(
            '+----------------------------------------------------------------------+'
            '| Device State                                                         |'
            '+----------------------------------------------------------------------+'
            ('             AzureAdJoined : {0}' -f $Aad)
            '          EnterpriseJoined : NO'
            ('              DomainJoined : {0}' -f $Dom)
        )
        if ($Domain) { $lines += ('                DomainName : {0}' -f $Domain) }
        if ($Tenant) { $lines += ('                TenantName : {0}' -f $Tenant) }
        $lines += @('| User State |', '                    NgcSet : NO', ('           WorkplaceJoined : {0}' -f $Workplace))
        return $lines
    }

    $script:NltestOk = @(
        '           DC: \\DC01.contoso.local'
        '      Address: \\10.20.30.40'
        '     Dom Guid: 11111111-2222-3333-4444-555555555555'
        '     Dom Name: contoso.local'
        '  Forest Name: contoso.local'
        ' Dc Site Name: Default-First-Site-Name'
        'The command completed successfully'
    )
    $script:NltestFail = @('Getting DC name failed: Status = 1355 0x54b ERROR_NO_SUCH_DOMAIN')

    # A fake tool runner: dsregcmd and nltest answer from the given lines; every call is recorded.
    function New-FakeTool([System.Collections.ArrayList] $Calls, [string[]] $Dsreg, [string[]] $Nltest = @(), [int] $NltestExit = 0) {
        return {
            param($Name, $ArgumentList)
            $null = $Calls.Add(('{0} {1}' -f $Name, ($ArgumentList -join ' ')))
            if ($Name -eq 'dsregcmd.exe') { return [pscustomobject]@{ ExitCode = 0; Lines = $Dsreg } }
            if ($Name -eq 'nltest.exe') { return [pscustomobject]@{ ExitCode = $NltestExit; Lines = $Nltest } }
            throw ('unexpected tool {0}' -f $Name)
        }.GetNewClosure()
    }

    function New-Env([string] $UserDomain = 'CONTOSO', [string] $LogonServer = '\\DC01') {
        return @{ ComputerName = 'TESTPC-01'; UserDomain = $UserDomain; UserName = 'jtester'; LogonServer = $LogonServer }
    }

    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
}

Describe 'ConvertFrom-AfDsregStatus and Get-AfJoinType' {
    It 'names all five join types' {
        InModuleScope AutoFixer -Parameters @{ Make = ${function:New-DsregLines} } {
            param($Make)
            $cases = @(
                @{ Lines = (& $Make -Aad 'YES' -Dom 'YES'); Kind = 'Hybrid' }
                @{ Lines = (& $Make -Dom 'YES'); Kind = 'OnPremAD' }
                @{ Lines = (& $Make -Aad 'YES'); Kind = 'Entra' }
                @{ Lines = (& $Make -Workplace 'YES'); Kind = 'Workplace' }
                @{ Lines = (& $Make); Kind = 'Local' }
            )
            foreach ($c in $cases) { (Get-AfJoinType -Status (ConvertFrom-AfDsregStatus -Lines $c.Lines)).Kind | Should -Be $c.Kind }
        }
    }

    It 'reads the domain and a tenant name with spaces' {
        InModuleScope AutoFixer -Parameters @{ Lines = (New-DsregLines -Aad 'YES' -Dom 'YES' -Domain 'CONTOSO' -Tenant 'Contoso Test Ltd') } {
            param($Lines)
            $s = ConvertFrom-AfDsregStatus -Lines $Lines
            $s.DomainName | Should -Be 'CONTOSO'
            $s.TenantName | Should -Be 'Contoso Test Ltd'
            $s.AzureAdJoined | Should -Be 'YES'
        }
    }

    It 'treats empty output as not joined' {
        InModuleScope AutoFixer { (Get-AfJoinType -Status (ConvertFrom-AfDsregStatus -Lines @())).Kind | Should -Be 'Local' }
    }
}

Describe 'ConvertFrom-AfNltestDc' {
    It 'reads the controller, its address and the domain without the leading backslashes' {
        InModuleScope AutoFixer -Parameters @{ Lines = $script:NltestOk } {
            param($Lines)
            $r = ConvertFrom-AfNltestDc -Lines $Lines
            $r.Controller | Should -Be 'DC01.contoso.local'
            $r.Address | Should -Be '10.20.30.40'
            $r.Domain | Should -Be 'contoso.local'
            $r.Status | Should -Be 0
        }
    }

    It 'reads the status number of a failure and explains it' {
        InModuleScope AutoFixer -Parameters @{ Lines = $script:NltestFail } {
            param($Lines)
            $r = ConvertFrom-AfNltestDc -Lines $Lines
            $r.Controller | Should -BeNullOrEmpty
            $r.Status | Should -Be 1355
            Get-AfNltestMeaning 1355 | Should -Match 'no domain controller could be reached'
            Get-AfNltestMeaning 4242 | Should -Match 'log'
        }
    }
}

Describe 'Get-AfAccountKind' {
    It 'tells cloud, local and domain accounts apart' {
        InModuleScope AutoFixer {
            Get-AfAccountKind -UserDomain 'AzureAD' -ComputerName 'TESTPC-01' | Should -Be 'Cloud'
            Get-AfAccountKind -UserDomain 'TESTPC-01' -ComputerName 'TESTPC-01' | Should -Be 'Local'
            Get-AfAccountKind -UserDomain 'CONTOSO' -ComputerName 'TESTPC-01' | Should -Be 'Domain'
        }
    }
}

Describe 'Get-AfSignInFact' {
    It 'on a domain PC runs nltest and looks up the logon DC' {
        $calls = [System.Collections.ArrayList]::new()
        $tool = New-FakeTool -Calls $calls -Dsreg (New-DsregLines -Dom 'YES' -Domain 'CONTOSO') -Nltest $script:NltestOk
        $resolved = [System.Collections.ArrayList]::new()
        $resolve = { param($Name) $null = $resolved.Add($Name); @('10.20.30.40') }.GetNewClosure()
        $f = InModuleScope AutoFixer -Parameters @{ E = (New-Env); T = $tool; R = $resolve } {
            param($E, $T, $R)
            Get-AfSignInFact -Environment $E -RunTool $T -Resolve $R
        }
        $calls | Should -Be @('dsregcmd.exe /status', 'nltest.exe /dsgetdc:')
        $resolved | Should -Be @('DC01')
        $f.JoinType.Kind | Should -Be 'OnPremAD'
        $f.AccountKind | Should -Be 'Domain'
        $f.LogonServer | Should -Be 'DC01'
        $f.LogonServerIp | Should -Be @('10.20.30.40')
        $f.Nltest.Controller | Should -Be 'DC01.contoso.local'
        $f.NltestError | Should -BeNullOrEmpty
    }

    It 'on a PC that is not on a domain never runs nltest or DNS' {
        $calls = [System.Collections.ArrayList]::new()
        $tool = New-FakeTool -Calls $calls -Dsreg (New-DsregLines -Aad 'YES' -Tenant 'Contoso Test Ltd')
        $f = InModuleScope AutoFixer -Parameters @{ E = (New-Env -UserDomain 'AzureAD' -LogonServer '\\TESTPC-01'); T = $tool } {
            param($E, $T)
            Get-AfSignInFact -Environment $E -RunTool $T -Resolve { throw 'no DNS' }
        }
        $calls | Should -Be @('dsregcmd.exe /status')
        $f.JoinType.Kind | Should -Be 'Entra'
        $f.AccountKind | Should -Be 'Cloud'
        $f.LogonServerError | Should -BeNullOrEmpty
    }

    It 'reports nltest''s exit code and meaning when no domain controller answers' {
        $calls = [System.Collections.ArrayList]::new()
        $tool = New-FakeTool -Calls $calls -Dsreg (New-DsregLines -Dom 'YES') -Nltest $script:NltestFail -NltestExit 1355
        $f = InModuleScope AutoFixer -Parameters @{ E = (New-Env); T = $tool } {
            param($E, $T)
            Get-AfSignInFact -Environment $E -RunTool $T -Resolve { throw 'DNS down' }
        }
        $f.NltestError | Should -Match 'exit code 1355'
        $f.NltestError | Should -Match 'no domain controller could be reached'
        $f.LogonServerError | Should -Match 'DNS'
    }

    It 'says the join type is unknown when dsregcmd fails' {
        $tool = { param($Name, $ArgumentList) $null = $ArgumentList; if ($Name -eq 'dsregcmd.exe') { [pscustomobject]@{ ExitCode = 5; Lines = @() } } }
        $f = InModuleScope AutoFixer -Parameters @{ E = (New-Env -UserDomain 'TESTPC-01' -LogonServer '\\TESTPC-01'); T = $tool } {
            param($E, $T)
            Get-AfSignInFact -Environment $E -RunTool $T -Resolve { throw 'no DNS' }
        }
        $f.DsregError | Should -Match 'exit code 5'
    }
}

Describe 'Invoke-AfSignInSourceCheck' {
    BeforeEach {
        $calls = [System.Collections.ArrayList]::new()
        $tool = New-FakeTool -Calls $calls -Dsreg (New-DsregLines -Aad 'YES' -Dom 'YES' -Domain 'CONTOSO' -Tenant 'Contoso Test Ltd') -Nltest $script:NltestOk
        $script:GetFacts = InModuleScope AutoFixer -Parameters @{ E = (New-Env); T = $tool } {
            param($E, $T)
            $facts = Get-AfSignInFact -Environment $E -RunTool $T -Resolve { @('10.20.30.40') }
            { $facts }.GetNewClosure()
        }
    }

    It 'shows the join type and both domain controllers, with names and IPs hidden on screen and in the log' {
        $out = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $TestDrive; F = $script:GetFacts } {
            param($S, $R, $F)
            Invoke-AfSignInSourceCheck -Settings $S -OutputRoot $R -GetFacts $F 6>&1
        }
        $screen = ($out | ForEach-Object { [string]$_ }) -join "`n"
        $screen | Should -Match 'Hybrid'
        $screen | Should -Match 'Logon DC'
        $screen | Should -Match 'Current DC'
        $screen | Should -Match 'signed in by the domain controller'
        $log = Get-ChildItem -Path $TestDrive -Recurse -Filter '*-signin.log' | Select-Object -First 1
        $log | Should -Not -BeNullOrEmpty
        $text = Get-Content -LiteralPath $log.FullName -Raw
        $text | Should -Match 'Current DC'
        $text | Should -Match 'nltest /dsgetdc: exit code 0'
        foreach ($secret in 'DC01', 'contoso', 'CONTOSO', 'TESTPC-01', 'jtester', 'Contoso Test Ltd', '10.20.30.40') {
            $screen | Should -Not -Match ([regex]::Escape($secret))
            $text | Should -Not -Match ([regex]::Escape($secret))
        }
    }

    It 'shows real names on screen only when Show sensitive data is on' {
        $show = $script:Settings.PSObject.Copy()
        $show.ShowSensitive = $true
        $out = InModuleScope AutoFixer -Parameters @{ S = $show; R = $TestDrive; F = $script:GetFacts } {
            param($S, $R, $F)
            Invoke-AfSignInSourceCheck -Settings $S -OutputRoot $R -GetFacts $F 6>&1
        }
        (($out | ForEach-Object { [string]$_ }) -join "`n") | Should -Match 'DC01\.contoso\.local \(10\.20\.30\.40\)'
        $log = Get-ChildItem -Path $TestDrive -Recurse -Filter '*-signin.log' | Sort-Object LastWriteTime | Select-Object -Last 1
        Get-Content -LiteralPath $log.FullName -Raw | Should -Not -Match 'DC01'
    }

    It 'says no domain controller is used for a local account on a PC that is not joined' {
        $tool = New-FakeTool -Calls ([System.Collections.ArrayList]::new()) -Dsreg (New-DsregLines)
        $facts = InModuleScope AutoFixer -Parameters @{ E = (New-Env -UserDomain 'TESTPC-01' -LogonServer '\\TESTPC-01'); T = $tool } {
            param($E, $T)
            Get-AfSignInFact -Environment $E -RunTool $T -Resolve { throw 'no DNS' }
        }
        $out = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $TestDrive; F = { $facts }.GetNewClosure() } {
            param($S, $R, $F)
            Invoke-AfSignInSourceCheck -Settings $S -OutputRoot $R -GetFacts $F 6>&1
        }
        $screen = ($out | ForEach-Object { [string]$_ }) -join "`n"
        $screen | Should -Match 'local account on this PC'
        $screen | Should -Match 'not on an on-prem domain'
    }
}

Describe 'Network and domain menu' {
    It 'opens the sign-in source check with S in Technician mode only' {
        $picked = [System.Collections.ArrayList]::new()
        $signIn = { param($S) $null = $S; $null = $picked.Add('SignIn') }.GetNewClosure()
        $standard = $script:Settings.PSObject.Copy()
        $standard.Mode = 'Standard'
        foreach ($case in @(@{ S = $standard; Keys = @('s', 'b') }, @{ S = $script:Settings; Keys = @('s', 'x', 'b') })) {
            $queue = [System.Collections.Queue]::new()
            foreach ($k in $case.Keys) { $queue.Enqueue($k) }
            $reader = { $queue.Dequeue() }.GetNewClosure()
            InModuleScope AutoFixer -Parameters @{ S = $case.S; R = $TestDrive; K = $reader; A = $signIn } {
                param($S, $R, $K, $A)
                Invoke-AfNetworkMenu -Settings $S -OutputRoot $R -ReadKey $K -SignIn $A 6>$null
            }
            $queue.Count | Should -Be 0
        }
        $picked | Should -Be @('SignIn')
    }
}
