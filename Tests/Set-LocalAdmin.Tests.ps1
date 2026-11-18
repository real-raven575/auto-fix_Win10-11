# Tools\Set-LocalAdmin.ps1: create a local admin or change its password from an RMM
# with no keyboard (password from the AF_ADMIN_PASSWORD variable only) or at a console.
# Dot-sourced, so it loads its functions and runs nothing. Every Windows part is a
# fake that records its calls: no real account or restore point is touched.
BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '..\Tools\Set-LocalAdmin.ps1'
    . $script:Tool -Plain

    function Set-FakeWindows([object[]] $Accounts, [switch] $NoRestorePoint) {
        $calls = [System.Collections.ArrayList]::new()
        $script:FakeCalls = $calls
        $list = $Accounts
        $script:SlaGetAccounts = { $list }.GetNewClosure()
        $script:SlaAccount = {
            param($Command, $Parameters)
            $null = $calls.Add(('{0} {1}' -f $Command, (@($Parameters.Keys | Sort-Object) -join ',')))
            if ($Parameters.Password -and $Parameters.Password -isnot [securestring]) { throw 'password was not a SecureString' }
        }.GetNewClosure()
        if ($NoRestorePoint) { $script:SlaRestorePoint = { $null = $calls.Add('restore point'); throw 'System Protection is off for drive C:.' }.GetNewClosure() }
        else { $script:SlaRestorePoint = { $null = $calls.Add('restore point') }.GetNewClosure() }
        $script:SlaHasLocalAccounts = { $true }
        $script:SlaReadSecret = { throw 'no hidden prompt expected' }
    }

    $script:Some = @(
        [pscustomobject]@{ Name = 'helpdesk'; Enabled = $false; Admin = $true }
        [pscustomobject]@{ Name = 'kiosk'; Enabled = $true; Admin = $false }
    )
    $script:Secret = 'Pa55-Secret!9'
}

Describe 'Set-LocalAdmin: file' {
    It 'stays pure ASCII and loads without running anything when dot-sourced' {
        @([System.IO.File]::ReadAllBytes($script:Tool) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        Get-Command Invoke-SetLocalAdmin -CommandType Function | Should -Not -BeNullOrEmpty
    }

    It 'has no -Password parameter, so a password can never go on a command line' {
        (Get-Command $script:Tool).Parameters.Keys | Should -Not -Contain 'Password'
    }

    It 'checks names the way Windows does' {
        Test-SlaName 'rescue' | Should -BeTrue
        Test-SlaName 'bad/name' | Should -BeFalse
        Test-SlaName '' | Should -BeFalse
        Test-SlaName 'a-name-that-is-far-too-long' | Should -BeFalse
    }
}

Describe 'Set-LocalAdmin: password variable' {
    It 'reads AF_ADMIN_PASSWORD once as a SecureString and clears it at once' {
        [Environment]::SetEnvironmentVariable('AF_ADMIN_PASSWORD', $script:Secret, 'Process')
        $s = Read-SlaPasswordVariable
        $s | Should -BeOfType [securestring]
        [Net.NetworkCredential]::new('', $s).Password | Should -BeExactly $script:Secret
        [Environment]::GetEnvironmentVariable('AF_ADMIN_PASSWORD', 'Process') | Should -BeNullOrEmpty
        Read-SlaPasswordVariable | Should -BeNullOrEmpty
    }
}

Describe 'Set-LocalAdmin: Background Mode (no keyboard)' {
    BeforeEach {
        $script:HerdLog.Clear(); $script:SlaNames.Clear()
        $script:HerdBackground = $true; $script:HerdGo = 'YES'
        [Environment]::SetEnvironmentVariable('AF_ADMIN_PASSWORD', $script:Secret, 'Process')
    }
    AfterEach { [Environment]::SetEnvironmentVariable('AF_ADMIN_PASSWORD', $null, 'Process') }

    It 'creates the local admin with -Go YES, after a restore point, and never shows or logs the password or name' {
        Set-FakeWindows $script:Some
        $out = Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>&1 | Out-String
        @($script:FakeCalls) | Should -Be @('restore point', 'New-LocalUser Description,Name,Password,PasswordNeverExpires', 'Add-LocalGroupMember Member,SID')
        ($script:HerdLog -join "`n") | Should -Not -Match 'Pa55|rescue'
        ($script:HerdLog -join "`n") | Should -Match 'created local admin <ACCOUNT-1>'
        $out | Should -Not -Match 'Pa55'
    }

    It 'returns 0 when done' {
        Set-FakeWindows $script:Some
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 0
    }

    It 'warns but goes on when no restore point can be made' {
        Set-FakeWindows $script:Some -NoRestorePoint
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 0
        @($script:FakeCalls)[1] | Should -Match '^New-LocalUser'
        ($script:HerdLog -join "`n") | Should -Match 'WARNING: No restore point'
    }

    It 'changes nothing without -Go YES and returns 4' {
        Set-FakeWindows $script:Some
        $script:HerdGo = 'yes'
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 4
        $script:FakeCalls.Count | Should -Be 0
    }

    It 'returns 1 and changes nothing with no password variable (it never waits for a prompt)' {
        Set-FakeWindows $script:Some
        [Environment]::SetEnvironmentVariable('AF_ADMIN_PASSWORD', $null, 'Process')
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 1
        $script:FakeCalls.Count | Should -Be 0
    }

    It 'returns 1 for a bad name, an existing name on Create, a missing or non-admin account on Change' {
        $cases = @(
            @{ Action = 'Create'; Name = 'bad/name' }
            @{ Action = 'Create'; Name = 'kiosk' }
            @{ Action = 'Change'; Name = 'nobody' }
            @{ Action = 'Change'; Name = 'kiosk' }
        )
        foreach ($c in $cases) {
            Set-FakeWindows $script:Some
            Invoke-SetLocalAdmin -Action $c.Action -Name $c.Name -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 1 -Because ('{0} {1}' -f $c.Action, $c.Name)
            $script:FakeCalls.Count | Should -Be 0
        }
    }

    It 'returns 2 without administrator rights or outside Windows PowerShell 5.1' {
        Set-FakeWindows $script:Some
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $false 6>$null | Select-Object -Last 1 | Should -Be 2
        $script:SlaHasLocalAccounts = { $false }
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 2
        $script:FakeCalls.Count | Should -Be 0
    }

    It 'changes the password of a local admin and turns it on when it was off' {
        Set-FakeWindows $script:Some
        Invoke-SetLocalAdmin -Action Change -Name 'helpdesk' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 0
        @($script:FakeCalls) | Should -Be @('restore point', 'Set-LocalUser Name,Password', 'Enable-LocalUser Name')
        ($script:HerdLog -join "`n") | Should -Not -Match 'Pa55|helpdesk'
    }

    It 'returns 3 with the Windows message when Windows refuses' {
        Set-FakeWindows $script:Some
        $script:SlaAccount = { param($Command, $Parameters) $null = $Command, $Parameters; throw 'The password does not meet the password policy requirements.' }
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 3
        ($script:HerdLog -join "`n") | Should -Match 'password policy'
    }
}

Describe 'Set-LocalAdmin: at a console' {
    BeforeEach {
        $script:HerdLog.Clear(); $script:SlaNames.Clear()
        $script:HerdBackground = $false; $script:HerdGo = ''
        [Environment]::SetEnvironmentVariable('AF_ADMIN_PASSWORD', $null, 'Process')
    }

    It 'asks twice in hidden prompts when no variable is set, then asks Y/N before each change' {
        Set-FakeWindows $script:Some
        $queue = [System.Collections.Queue]::new()
        foreach ($a in 'Pa55-word!', 'Pa55-word!') { $s = New-Object System.Security.SecureString; foreach ($ch in $a.ToCharArray()) { $s.AppendChar($ch) }; $queue.Enqueue($s) }
        $script:SlaReadSecret = { param($Prompt) $null = $Prompt; $queue.Dequeue() }.GetNewClosure()
        Mock Read-Host { 'y' }
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 0
        Should -Invoke Read-Host -Times 2 -Exactly
        @($script:FakeCalls).Count | Should -Be 3
    }

    It 'changes nothing on N and returns 4' {
        Set-FakeWindows $script:Some
        [Environment]::SetEnvironmentVariable('AF_ADMIN_PASSWORD', $script:Secret, 'Process')
        Mock Read-Host { 'n' }
        Invoke-SetLocalAdmin -Action Create -Name 'rescue' -IsAdmin $true 6>$null | Select-Object -Last 1 | Should -Be 4
        $script:FakeCalls.Count | Should -Be 0
    }
}
