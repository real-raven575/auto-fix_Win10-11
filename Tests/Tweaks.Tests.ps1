# Windows tweaks: the classic right-click menu. The registry, the Windows build, the
# account check and the Explorer restart are fakes, and keys come from a queue. A queue
# that runs dry fails the test, which proves no extra question was asked. One test
# writes a throwaway key under HKCU\Software to check the real registry calls.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    # A fake classic-menu key: State.On is the key, Calls records each set and restart.
    function New-FakeTweak([bool] $On = $false, [bool] $Sticks = $true) {
        $state = @{ On = $On; Calls = [System.Collections.ArrayList]::new() }
        return @{
            State   = $state
            TestKey = { $state.On }.GetNewClosure()
            SetKey  = { param([bool] $To) $null = $state.Calls.Add("set $To"); if ($Sticks) { $state.On = $To } }.GetNewClosure()
            Restart = { $null = $state.Calls.Add('restart'); $true }.GetNewClosure()
        }
    }

    $script:Tech = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
}

Describe 'Get-AfClassicMenuState' {
    It 'is NotWin11 on Windows 10 and when the build is unknown, and never reads the key there' {
        InModuleScope AutoFixer {
            Get-AfClassicMenuState -GetBuild { 19045 } -TestKey { throw 'read the key' } | Should -Be 'NotWin11'
            Get-AfClassicMenuState -GetBuild { 0 } -TestKey { throw 'read the key' } | Should -Be 'NotWin11'
        }
    }

    It 'is On or Off on Windows 11 by the key' {
        InModuleScope AutoFixer {
            Get-AfClassicMenuState -GetBuild { 22000 } -TestKey { $true } | Should -Be 'On'
            Get-AfClassicMenuState -GetBuild { 26100 } -TestKey { $false } | Should -Be 'Off'
        }
    }
}

Describe 'Set-AfClassicMenuKey and Test-AfClassicMenuKey (real registry, throwaway key)' {
    BeforeAll { $script:Root = 'HKCU:\Software\AutoFixer-Pester-{0}' -f [guid]::NewGuid().ToString('N') }
    AfterAll { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'adds the key with an empty default value, reads it back, and removes it' -Skip:($env:OS -ne 'Windows_NT') {
        InModuleScope AutoFixer -Parameters @{ Root = $script:Root } {
            param($Root)
            Test-AfClassicMenuKey -Root $Root | Should -BeFalse
            Set-AfClassicMenuKey -On $true -Root $Root
            Test-AfClassicMenuKey -Root $Root | Should -BeTrue
            (Get-Item -LiteralPath (Join-Path $Root 'InprocServer32')).GetValue('', $null) | Should -BeExactly ''
            # Running it twice is safe.
            Set-AfClassicMenuKey -On $true -Root $Root
            Test-AfClassicMenuKey -Root $Root | Should -BeTrue
            Set-AfClassicMenuKey -On $false -Root $Root
            Test-Path -LiteralPath $Root | Should -BeFalse
            # Undo when there is nothing to undo is safe too.
            Set-AfClassicMenuKey -On $false -Root $Root
        }
    }

    It 'does not count a key without a default value as on' -Skip:($env:OS -ne 'Windows_NT') {
        InModuleScope AutoFixer -Parameters @{ Root = $script:Root } {
            param($Root)
            $null = New-Item -Path (Join-Path $Root 'InprocServer32') -Force
            Test-AfClassicMenuKey -Root $Root | Should -BeFalse
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
    }
}

Describe 'Invoke-AfClassicMenuTweak' {
    It 'changes nothing on Windows 10 and asks nothing' {
        $f = New-FakeTweak
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $TestDrive; F = $f; Keys = (New-KeyReader) } {
            param($S, $Root, $F, $Keys)
            $r = Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 19045 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $true } -RestartExplorer $F.Restart 6>$null
            $r.Tag | Should -Be 'SKIPPED'
            $r.Detail | Should -Match 'Windows 10'
        }
        $f.State.Calls.Count | Should -Be 0
    }

    It 'changes nothing when the build is unknown' {
        $f = New-FakeTweak
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $TestDrive; F = $f; Keys = (New-KeyReader) } {
            param($S, $Root, $F, $Keys)
            (Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 0 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $true } -RestartExplorer $F.Restart 6>$null).Tag | Should -Be 'SKIPPED'
        }
        $f.State.Calls.Count | Should -Be 0
    }

    It 'refuses when Auto-Fixer runs as a different account from the signed-in one' {
        $f = New-FakeTweak
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $TestDrive; F = $f; Keys = (New-KeyReader) } {
            param($S, $Root, $F, $Keys)
            $r = Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $false } -RestartExplorer $F.Restart 6>$null
            $r.Tag | Should -Be 'SKIPPED'
        }
        $f.State.Calls.Count | Should -Be 0
    }

    It 'changes nothing on N and writes no log' {
        $f = New-FakeTweak
        $root = Join-Path $TestDrive 'no'
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $root; F = $f; Keys = (New-KeyReader 'n') } {
            param($S, $Root, $F, $Keys)
            (Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $true } -RestartExplorer $F.Restart 6>$null).Tag | Should -Be 'CANCELLED'
        }
        $f.State.Calls.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*-tweaks.log' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'turns the classic menu on after Y, restarts Explorer after a second Y, and logs both' {
        $f = New-FakeTweak -On $false
        $root = Join-Path $TestDrive 'on'
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $root; F = $f; Keys = (New-KeyReader 'y', 'y') } {
            param($S, $Root, $F, $Keys)
            $r = Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $true } -RestartExplorer $F.Restart 6>$null
            $r.Tag | Should -Be 'OK'
            $r.Detail | Should -Match 'Classic right-click menu is on'
        }
        @($f.State.Calls) | Should -Be @('set True', 'restart')
        $log = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*-tweaks.log')
        $log.Count | Should -Be 1
        $text = Get-Content -LiteralPath $log[0].FullName -Raw
        $text | Should -Match 'Before    : Windows 11 menu'
        $text | Should -Match 'add HKCU\\Software\\Classes\\CLSID\\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2\}\\InprocServer32'
        $text | Should -Match 'OK     Classic right-click menu is on'
        $text | Should -Match 'File Explorer restarted'
    }

    It 'undoes it when it is on, and leaves Explorer alone on N' {
        $f = New-FakeTweak -On $true
        $root = Join-Path $TestDrive 'off'
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $root; F = $f; Keys = (New-KeyReader 'y', 'n') } {
            param($S, $Root, $F, $Keys)
            $r = Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $true } -RestartExplorer $F.Restart 6>$null
            $r.Tag | Should -Be 'OK'
            $r.Detail | Should -Match 'Windows 11 right-click menu is back'
        }
        @($f.State.Calls) | Should -Be @('set False')
        $text = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $root -Recurse -Filter '*-tweaks.log')[0].FullName -Raw
        $text | Should -Match 'remove HKCU'
        $text | Should -Match 'Skipped: File Explorer restart'
    }

    It 'reports FAILED, and offers no restart, when the change does not read back' {
        $f = New-FakeTweak -On $false -Sticks $false
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = (Join-Path $TestDrive 'stuck'); F = $f; Keys = (New-KeyReader 'y') } {
            param($S, $Root, $F, $Keys)
            (Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $true } -RestartExplorer $F.Restart 6>$null).Tag | Should -Be 'FAILED'
        }
        @($f.State.Calls) | Should -Be @('set True')
    }

    It 'reports FAILED with the error when the registry write throws' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = (Join-Path $TestDrive 'throw'); Keys = (New-KeyReader 'y') } {
            param($S, $Root, $Keys)
            $r = Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey { $false } -SetKey { throw 'Access denied' } -SameUser { $true } -RestartExplorer { throw 'must not restart' } 6>$null
            $r.Tag | Should -Be 'FAILED'
            $r.Detail | Should -Match 'Access denied'
        }
    }

    It 'still works, with a note, when it cannot tell which account Explorer runs as' {
        $f = New-FakeTweak
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = (Join-Path $TestDrive 'unknown'); F = $f; Keys = (New-KeyReader 'y', 'n') } {
            param($S, $Root, $F, $Keys)
            (Invoke-AfClassicMenuTweak -Settings $S -OutputRoot $Root -ReadKey $Keys -GetBuild { 22631 } -TestKey $F.TestKey -SetKey $F.SetKey -SameUser { $null } -RestartExplorer $F.Restart 6>$null).Tag | Should -Be 'OK'
        }
        @($f.State.Calls) | Should -Be @('set True')
    }
}

Describe 'Windows tweaks menu' {
    It 'opens from the main menu with K in Technician mode' {
        $opened = [System.Collections.ArrayList]::new()
        $tweaks = { param($S) $null = $opened.Add($S.Mode) }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'tech-settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -TweaksAction $tweaks `
            -ReadKey (New-KeyReader 't', 'y', 'k', 'q', 'y') 6>$null
        @($opened) | Should -Be @('Technician')
    }

    It 'is not in the Standard main menu' {
        $opened = [System.Collections.ArrayList]::new()
        $tweaks = { param($S) $null = $opened.Add($S.Mode) }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'std-settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -TweaksAction $tweaks `
            -ReadKey (New-KeyReader 'Enter', 'k', 'q', 'y') 6>$null
        $opened.Count | Should -Be 0
    }

    It 'keeps main menu numbers 1 to 9 the same in Technician mode' {
        $opened = [System.Collections.ArrayList]::new()
        $office = { param($S) $null = $S; $null = $opened.Add('office') }.GetNewClosure()
        $tweaks = { param($S) $null = $S; $null = $opened.Add('tweaks') }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'num-settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -OfficeAction $office -TweaksAction $tweaks `
            -ReadKey (New-KeyReader 't', 'y', '5', 'q', 'y') 6>$null
        @($opened) | Should -Be @('office')
    }

    It 'shows the state in the label, runs the switch, and goes back on Esc' {
        $seen = [System.Collections.ArrayList]::new()
        $run = { param($S) $null = $seen.Add('classic ' + $S.Mode) }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = $TestDrive; R = $run; Keys = (New-KeyReader 'c', 'x', 'Escape') } {
            param($S, $Root, $R, $Keys)
            $script:AfLogKey = $null
            Invoke-AfTweaksMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -GetState { 'Off' } -ClassicMenu $R 6>$null
        }
        @($seen) | Should -Be @('classic Technician')
    }
}
