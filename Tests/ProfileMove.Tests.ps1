# Move a user profile. Nothing touches real profiles here: the profile list, the
# accounts, the backups and ChangeOwner are fakes that record each call, and keys
# come from a queue. A queue that runs dry fails the test, which proves no extra
# question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    $script:Technician = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Me = 'S-1-5-21-1-2-3-1001'
    $script:Old = 'S-1-12-1-11-22-33-44'
    $script:New = 'S-1-5-21-1-2-3-1002'

    function Invoke-Move([string[]] $Keys, $Calls, [bool] $Loaded = $false, [bool] $NewHasProfile = $false, [bool] $PointOk = $true, $Settings = $script:Technician) {
        $runs = Join-Path $TestDrive ([guid]::NewGuid())
        $profiles = @(
            [pscustomobject]@{ Sid = $script:Me; Name = 'TESTPC-01\techadmin'; Path = 'C:\Users\techadmin'; Loaded = $true; LastUse = $null }
            [pscustomobject]@{ Sid = $script:Old; Name = 'AzureAD\JordanWorker'; Path = 'C:\Users\JordanWorker'; Loaded = $Loaded; LastUse = [datetime]'2026-10-29' }
        )
        if ($NewHasProfile) { $profiles += [pscustomobject]@{ Sid = $script:New; Name = 'TESTPC-01\jordanlocal'; Path = 'C:\Users\jordanlocal'; Loaded = $false; LastUse = $null } }
        $p = @{ S = $Settings; R = $runs; K = (New-KeyReader $Keys); C = $Calls; Pr = $profiles; Me = $script:Me; New = $script:New; Ok = $PointOk }
        $screen = InModuleScope AutoFixer -Parameters $p {
            param($S, $R, $K, $C, $Pr, $Me, $New, $Ok)
            $getProfiles = { $Pr }.GetNewClosure()
            $accounts = { @([pscustomobject]@{ Name = 'jordanlocal'; Enabled = $true; Admin = $false; BuiltIn = $false }) }
            $resolve = { param($Name) if ($Name -match 'jordanlocal$') { $New } }.GetNewClosure()
            $point = { $null = $C.Add('restore point'); [pscustomobject]@{ Ok = $Ok; Reason = 'System Protection is off' } }.GetNewClosure()
            $run = { param($Name, $ArgumentList) $null = $C.Add(('{0} {1}' -f $Name, $ArgumentList[0])); [pscustomobject]@{ ExitCode = 0; Lines = @() } }.GetNewClosure()
            $change = { param($Sid, $NewSid, $Flags) $null = $C.Add(('ChangeOwner {0} {1} {2}' -f $Sid, $NewSid, $Flags)); 0 }.GetNewClosure()
            Invoke-AfProfileMove -Settings $S -OutputRoot $R -ReadKey $K -ReadText { throw 'no typing' } -IsAdmin $true -CurrentSid $Me -GetProfiles $getProfiles -GetAccounts $accounts `
                -ResolveSid $resolve -LocalAdmin { throw 'no local admin screen' } -RestorePoint $point -RunTool $run -ChangeOwner $change 6>&1
        }
        $log = @(Get-ChildItem $runs -Recurse -Filter 'profile.log' -ErrorAction SilentlyContinue | Get-Content -Raw) -join ''
        return [pscustomobject]@{ Screen = ((@($screen) | ForEach-Object { [string]$_ }) -join "`n"); Log = $log }
    }
}

Describe 'Invoke-AfProfileMove' {
    BeforeEach { $script:Calls = [System.Collections.ArrayList]::new() }

    It 'is Technician only' {
        $standard = $script:Technician.PSObject.Copy()
        $standard.Mode = 'Standard'
        (Invoke-Move -Keys @() -Calls $script:Calls -Settings $standard).Screen | Should -Match 'Technician mode only'
        $script:Calls.Count | Should -Be 0
    }

    It 'refuses the account running Auto-Fixer and a profile that is in use' {
        $r = Invoke-Move -Keys @('1', '2', 'Escape') -Calls $script:Calls -Loaded $true
        $r.Screen | Should -Match 'account running Auto-Fixer'
        $r.Screen | Should -Match 'That profile is in use'
        $script:Calls.Count | Should -Be 0
    }

    It 'changes nothing on N at "Are you sure?"' {
        Invoke-Move -Keys @('2', '1', 'n') -Calls $script:Calls | Out-Null
        $script:Calls.Count | Should -Be 0
    }

    It 'backs up first, then moves the profile, and keeps names out of the log' {
        $r = Invoke-Move -Keys @('2', '1', 'y') -Calls $script:Calls
        $script:Calls | Should -Be @('restore point', 'reg.exe export', ('ChangeOwner {0} {1} 0' -f $script:Old, $script:New))
        $r.Screen | Should -Match 'now opens this profile'
        $r.Screen | Should -Not -Match 'JordanWorker|jordanlocal'
        $r.Log | Should -Match 'Outcome   : moved'
        $r.Log | Should -Not -Match 'JordanWorker|jordanlocal|S-1-12-1-11'
    }

    It 'asks before replacing an existing profile, and never asks Windows to delete it' {
        Invoke-Move -Keys @('2', '1', 'n') -Calls $script:Calls -NewHasProfile $true | Out-Null
        $script:Calls.Count | Should -Be 0
        Invoke-Move -Keys @('2', '1', 'y', 'y') -Calls $script:Calls -NewHasProfile $true | Out-Null
        $script:Calls[-1] | Should -Be ('ChangeOwner {0} {1} 1' -f $script:Old, $script:New)
    }

    It 'asks to continue when no restore point could be made' {
        Invoke-Move -Keys @('2', '1', 'y', 'n') -Calls $script:Calls -PointOk $false | Out-Null
        $script:Calls | Should -Be @('restore point')
    }

    It 'shows real names after S, on that screen only' {
        $r = Invoke-Move -Keys @('s', '2', '1', 'n') -Calls $script:Calls
        $r.Screen | Should -Match 'JordanWorker'
    }

    It 'opens from Network and domain with P in Technician mode only' {
        $opened = [System.Collections.ArrayList]::new()
        $move = { param($S) $null = $opened.Add($S.Mode) }.GetNewClosure()
        $standard = $script:Technician.PSObject.Copy()
        $standard.Mode = 'Standard'
        foreach ($case in @(@{ S = $standard; Keys = @('p', 'b') }, @{ S = $script:Technician; Keys = @('p', 'x', 'b') })) {
            InModuleScope AutoFixer -Parameters @{ S = $case.S; R = $TestDrive; M = $move; K = (New-KeyReader $case.Keys) } {
                param($S, $R, $M, $K)
                Invoke-AfNetworkMenu -Settings $S -OutputRoot $R -ReadKey $K -ProfileMove $M 6>$null
            }
        }
        $opened | Should -Be @('Technician')
    }
}
