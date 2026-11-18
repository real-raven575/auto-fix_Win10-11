# Local admin account and Leave Azure AD. Nothing touches real accounts or a real
# Azure AD join: the account cmdlets, dsregcmd and the Settings page are fakes that
# record each call, and keys come from a queue. A queue that runs dry fails the test.
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

    # Hidden password prompts: each answer becomes a SecureString.
    function New-SecretReader([string[]] $Answers = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($a in $Answers) {
            $secure = [System.Security.SecureString]::new()
            foreach ($ch in $a.ToCharArray()) { $secure.AppendChar($ch) }
            $queue.Enqueue($secure)
        }
        return { param($Prompt) $null = $Prompt; $queue.Dequeue() }.GetNewClosure()
    }

    # Answers dsregcmd /status in order: the first call, then the check afterwards.
    function New-JoinStates([object[]] $States) {
        $queue = [System.Collections.Queue]::new()
        foreach ($st in $States) { $queue.Enqueue($st) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    function New-FakeAccount([System.Collections.ArrayList] $Calls) {
        return {
            param($Name, $Parameters)
            $null = $Calls.Add(('{0} {1}' -f $Name, (@($Parameters.Keys | Sort-Object) -join ',')).Trim())
        }.GetNewClosure()
    }

    $script:Accounts = {
        @(
            [pscustomobject]@{ Name = 'Administrator'; Enabled = $false; Admin = $true; BuiltIn = $true }
            [pscustomobject]@{ Name = 'helpdesk'; Enabled = $false; Admin = $true; BuiltIn = $false }
            [pscustomobject]@{ Name = 'kiosk'; Enabled = $true; Admin = $false; BuiltIn = $false }
        )
    }
    $script:WithAdmin = {
        @(
            [pscustomobject]@{ Name = 'Administrator'; Enabled = $false; Admin = $true; BuiltIn = $true }
            [pscustomobject]@{ Name = 'rescue'; Enabled = $true; Admin = $true; BuiltIn = $false }
        )
    }
    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
}

Describe 'Local admin account' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
    }

    It 'checks local account names the way Windows does' {
        InModuleScope AutoFixer {
            Test-AfLocalUserName 'rescue' | Should -BeTrue
            Test-AfLocalUserName 'IT Support 2' | Should -BeTrue
            Test-AfLocalUserName 'bad/name' | Should -BeFalse
            Test-AfLocalUserName 'a-name-that-is-far-too-long' | Should -BeFalse
            Test-AfLocalUserName '...' | Should -BeFalse
        }
    }

    It 'creates a local admin after a good name, matching passwords and Y, and never logs the password' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader 'c', 'n', 'y'); T = (New-TextReader 'bad/name', 'kiosk', 'rescue'); P = (New-SecretReader 'Pa55-first', 'Pa55-other', 'Pa55-word!', 'Pa55-word!') } {
            param($S, $R, $G, $A, $K, $T, $P)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret $P -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point asked' } 6>$null
        }
        $script:Calls | Should -Be @('New-LocalUser Description,Name,Password', 'Add-LocalGroupMember Member,SID')
        $log = Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-localadmin.log' | Get-Content -Raw
        $log | Should -Match 'created local admin'
        $log | Should -Not -Match 'Pa55|rescue'
    }

    It 'changes nothing on N, on Esc, without admin rights, or after three mismatched passwords' {
        $cases = @(
            @{ Admin = $true; Keys = @('c', 'n', 'n'); Text = @('rescue'); Secret = @('Pa55-word!', 'Pa55-word!') }
            @{ Admin = $true; Keys = @('Escape'); Text = @(); Secret = @() }
            @{ Admin = $false; Keys = @(); Text = @(); Secret = @() }
            @{ Admin = $true; Keys = @('c'); Text = @('rescue'); Secret = @('a1', 'b1', 'a2', 'b2', 'a3', 'b3') }
        )
        foreach ($case in $cases) {
            InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; Ad = $case.Admin; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader $case.Keys); T = (New-TextReader $case.Text); P = (New-SecretReader $case.Secret) } {
                param($S, $R, $Ad, $G, $A, $K, $T, $P)
                Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret $P -IsAdmin $Ad -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point asked' } 6>$null
            }
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'resets a password and offers to turn a disabled account on' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader 'r', 'x', '2', 'n', 'y', 'y'); T = (New-TextReader); P = (New-SecretReader 'Pa55-word!', 'Pa55-word!') } {
            param($S, $R, $G, $A, $K, $T, $P)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret $P -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point asked' } 6>$null
        }
        $script:Calls | Should -Be @('Set-LocalUser Name,Password', 'Enable-LocalUser Name')
    }
}

Describe 'Create local admin and Change local admin password (main menu items)' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Points = [System.Collections.ArrayList]::new()
        $points = $script:Points
        $script:PointOk = { $null = $points.Add('point'); [pscustomobject]@{ Ok = $true; Reason = $null } }.GetNewClosure()
        $script:PointFail = { $null = $points.Add('point'); [pscustomobject]@{ Ok = $false; Reason = 'System Protection is off.' } }.GetNewClosure()
    }

    It 'stops before any question or change when there is no keyboard' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls) } {
            param($S, $R, $G, $A)
            foreach ($action in 'Menu', 'Create', 'Change') {
                Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey { throw 'no key' } -ReadText { throw 'no text' } -ReadSecret { throw 'no password' } `
                    -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $false -RestorePoint { throw 'no restore point' } -Action $action 6>$null
            }
        }
        $script:Calls.Count | Should -Be 0
        Test-Path $script:Runs | Should -BeFalse
    }

    It 'Create skips the C/R/M choice, makes the restore point on Y, then creates after Y' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); RP = $script:PointOk; K = (New-KeyReader 'y', 'y'); T = (New-TextReader 'rescue'); P = (New-SecretReader 'Pa55-word!', 'Pa55-word!') } {
            param($S, $R, $G, $A, $RP, $K, $T, $P)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret $P -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint $RP -Action Create 6>$null
        }
        @($script:Points) | Should -Be @('point')
        $script:Calls | Should -Be @('New-LocalUser Description,Name,Password', 'Add-LocalGroupMember Member,SID')
        $log = Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-localadmin.log' | Get-Content -Raw
        $log | Should -Match 'Restore point: created'
        $log | Should -Not -Match 'Pa55|rescue'
    }

    It 'warns but does not stop when no restore point can be made, and the tech still decides at Y/N' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); RP = $script:PointFail; K = (New-KeyReader 'y', 'y'); T = (New-TextReader 'rescue'); P = (New-SecretReader 'Pa55-word!', 'Pa55-word!') } {
            param($S, $R, $G, $A, $RP, $K, $T, $P)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret $P -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint $RP -Action Create 6>$null
        }
        $script:Calls | Should -Be @('New-LocalUser Description,Name,Password', 'Add-LocalGroupMember Member,SID')
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-localadmin.log' | Get-Content -Raw | Should -Match 'Restore point: WARNING, not created'
    }

    It 'Change offers only accounts in Administrators and sets the password after Y, never logging it' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader '2', 'n', 'y', 'n'); T = (New-TextReader); P = (New-SecretReader 'Pa55-new!', 'Pa55-new!') } {
            param($S, $R, $G, $A, $K, $T, $P)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret $P -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point asked' } -Action Change 6>$null
        }
        $script:Calls | Should -Be @('Set-LocalUser Name,Password')
        $log = Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-localadmin.log' | Get-Content -Raw
        $log | Should -Match 'password changed for'
        $log | Should -Not -Match 'Pa55|helpdesk'
    }

    It 'Change does not offer a non-admin account (item 3 does not exist in its list)' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader '3', '3') } {
            param($S, $R, $G, $A, $K)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText { throw 'no text' } -ReadSecret { throw 'no password' } -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point' } -Action Change 6>$null
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'Change stops with a pointer to Create when there is no local admin' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; A = (New-FakeAccount $script:Calls) } {
            param($S, $R, $A)
            $none = { @([pscustomobject]@{ Name = 'kiosk'; Enabled = $true; Admin = $false; BuiltIn = $false }) }
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey { throw 'no key' } -ReadText { throw 'no text' } -ReadSecret { throw 'no password' } -IsAdmin $true -GetAccounts $none -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point' } -Action Change 6>$null
        }
        $script:Calls.Count | Should -Be 0
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-localadmin.log' | Get-Content -Raw | Should -Match 'no local admin to change'
    }

    It 'the Local admin account menu opens Create with C and Change with W, and goes back on Esc' {
        $picked = [System.Collections.ArrayList]::new()
        $create = { param($S) $null = $S; $null = $picked.Add('Create') }.GetNewClosure()
        $change = { param($S) $null = $S; $null = $picked.Add('Change') }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; C = $create; W = $change; K = (New-KeyReader 'c', 'x', 'w', 'x', 'Escape') } {
            param($S, $R, $C, $W, $K)
            $script:AfLogKey = $null
            Invoke-AfLocalAdminMenu -Settings $S -OutputRoot $R -ReadKey $K -Create $C -Change $W 6>$null
        }
        @($picked) | Should -Be @('Create', 'Change')
    }

    It 'opens from the main menu with L in Technician mode only' {
        $opened = [System.Collections.ArrayList]::new()
        $local = { param($S) $null = $opened.Add($S.Mode) }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'la-tech.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -LocalAdminAction $local `
            -ReadKey (New-KeyReader 't', 'y', 'l', 'q', 'y') 6>$null
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'la-std.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -LocalAdminAction $local `
            -ReadKey (New-KeyReader 'Enter', 'l', 'q', 'y') 6>$null
        @($opened) | Should -Be @('Technician')
    }
}

Describe 'Make a local account an admin' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Calls = [System.Collections.ArrayList]::new()
    }

    It 'lists only not-admin accounts by number, shows real names on S, and adds the pick after Y' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader 'm', 's', '1', 'n', 'y'); T = (New-TextReader) } {
            param($S, $R, $G, $A, $K, $T)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret { throw 'no password' } -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point asked' } 6>$null
        }
        $script:Calls | Should -Be @('Add-LocalGroupMember Member,SID')
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-localadmin.log' | Get-Content -Raw | Should -Not -Match 'kiosk'
    }

    It 'changes nothing on N' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; G = $script:Accounts; A = (New-FakeAccount $script:Calls); K = (New-KeyReader 'm', '1', 'n', 'n'); T = (New-TextReader) } {
            param($S, $R, $G, $A, $K, $T)
            Invoke-AfLocalAdminTool -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -ReadSecret { throw 'no password' } -IsAdmin $true -GetAccounts $G -Account $A -HasKeyboard $true -RestorePoint { throw 'no restore point asked' } 6>$null
        }
        $script:Calls.Count | Should -Be 0
    }
}

Describe 'Leave Azure AD' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Tools = [System.Collections.ArrayList]::new()
        $script:Opened = [System.Collections.ArrayList]::new()
        $tools = $script:Tools
        $opened = $script:Opened
        $script:RunTool = { param($Name, $ArgumentList) $null = $tools.Add(('{0} {1}' -f $Name, ($ArgumentList -join ' '))); [pscustomobject]@{ ExitCode = 0; Lines = @() } }.GetNewClosure()
        $script:Open = { $null = $opened.Add('workplace') }.GetNewClosure()
    }

    It 'reads AzureAdJoined and DomainJoined from dsregcmd /status' {
        InModuleScope AutoFixer {
            $st = Get-AfDeviceJoinState -RunTool { param($Name, $ArgumentList) $null = $Name, $ArgumentList; [pscustomobject]@{ ExitCode = 0; Lines = @('         AzureAdJoined : YES', '          DomainJoined : NO') } }
            $st.AzureAd | Should -BeTrue
            $st.Domain | Should -BeFalse
            Get-AfDeviceJoinState -RunTool { throw 'missing' } | Should -BeNullOrEmpty
        }
    }

    It 'stops before any warning when the PC is not on Azure AD, or on N at "Set up a local admin now?"' {
        foreach ($case in @(@{ State = [pscustomobject]@{ AzureAd = $false; Domain = $false }; Accounts = $script:WithAdmin; Keys = @() }, @{ State = [pscustomobject]@{ AzureAd = $true; Domain = $false }; Accounts = $script:Accounts; Keys = @('n') })) {
            InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; J = (New-JoinStates @($case.State)); G = $case.Accounts; RT = $script:RunTool; O = $script:Open; K = (New-KeyReader $case.Keys); T = (New-TextReader) } {
                param($S, $R, $J, $G, $RT, $O, $K, $T)
                Invoke-AfAzureAdLeave -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -IsAdmin $true -GetJoinState $J -GetAccounts $G -RunTool $RT -OpenSettings $O 6>$null
            }
        }
        $script:Tools.Count | Should -Be 0
        $script:Opened.Count | Should -Be 0
    }

    It 'opens the local admin screen when none is ready, then carries on to the warning' {
        $lists = [System.Collections.Queue]::new()
        $lists.Enqueue((& $script:Accounts)); $lists.Enqueue((& $script:WithAdmin))
        $script:LocalAdminRuns = [System.Collections.ArrayList]::new()
        $runs = $script:LocalAdminRuns
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; J = (New-JoinStates @([pscustomobject]@{ AzureAd = $true; Domain = $false }, [pscustomobject]@{ AzureAd = $false; Domain = $false })); G = { $lists.Dequeue() }.GetNewClosure(); L = { $null = $runs.Add('U') }.GetNewClosure(); RT = $script:RunTool; O = $script:Open; K = (New-KeyReader 'y', 'y', '1', 'x'); T = (New-TextReader) } {
            param($S, $R, $J, $G, $L, $RT, $O, $K, $T)
            $script:Result = Invoke-AfAzureAdLeave -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -IsAdmin $true -GetJoinState $J -GetAccounts $G -LocalAdmin $L -RunTool $RT -OpenSettings $O 6>$null
            $script:Result | Should -Be 'left'
        }
        $script:LocalAdminRuns | Should -Be @('U')
        $script:Opened | Should -Be @('workplace')
    }

    It 'changes nothing on N at "Are you sure?"' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; J = (New-JoinStates @([pscustomobject]@{ AzureAd = $true; Domain = $true })); G = $script:WithAdmin; RT = $script:RunTool; O = $script:Open; K = (New-KeyReader 'n'); T = (New-TextReader) } {
            param($S, $R, $J, $G, $RT, $O, $K, $T)
            Invoke-AfAzureAdLeave -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -IsAdmin $true -GetJoinState $J -GetAccounts $G -RunTool $RT -OpenSettings $O 6>$null
        }
        $script:Tools.Count | Should -Be 0
    }

    It 'runs dsregcmd /debug /leave only on a hybrid PC, then checks again' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; J = (New-JoinStates @([pscustomobject]@{ AzureAd = $true; Domain = $true }, [pscustomobject]@{ AzureAd = $false; Domain = $true })); G = { throw 'no account check on hybrid' }; RT = $script:RunTool; O = $script:Open; K = (New-KeyReader 'y'); T = (New-TextReader) } {
            param($S, $R, $J, $G, $RT, $O, $K, $T)
            Invoke-AfAzureAdLeave -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -IsAdmin $true -GetJoinState $J -GetAccounts $G -RunTool $RT -OpenSettings $O 6>$null
        }
        $script:Tools | Should -Be @('dsregcmd.exe /debug /leave')
        $script:Opened.Count | Should -Be 0
        Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-azuread.log' | Get-Content -Raw | Should -Match 'left Azure AD'
    }

    It 'on an Azure AD only PC opens Settings after picking a working local admin, and never scripts the leave' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; J = (New-JoinStates @([pscustomobject]@{ AzureAd = $true; Domain = $false }, [pscustomobject]@{ AzureAd = $true; Domain = $false })); G = $script:WithAdmin; RT = $script:RunTool; O = $script:Open; K = (New-KeyReader 'y', '1', 'x'); T = (New-TextReader) } {
            param($S, $R, $J, $G, $RT, $O, $K, $T)
            Invoke-AfAzureAdLeave -Settings $S -OutputRoot $R -ReadKey $K -ReadText $T -IsAdmin $true -GetJoinState $J -GetAccounts $G -RunTool $RT -OpenSettings $O 6>$null
        }
        $script:Tools.Count | Should -Be 0
        $script:Opened | Should -Be @('workplace')
        $log = Get-ChildItem $script:Runs -Recurse -Filter 'AF-*-azuread.log' | Get-Content -Raw
        $log | Should -Match 'still joined'
        $log | Should -Not -Match 'rescue'
    }
}
