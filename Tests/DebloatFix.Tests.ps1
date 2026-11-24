# Debloat damage check. Every Windows call is a fake from New-FakeOps, so nothing on the
# test PC is read or changed. Keys come from a queue; a queue that runs dry fails the
# test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    # State.Services (name -> StartMode), State.Policies ('path|value' -> value),
    # State.Apps (installed names), State.OnDisk (name -> folder), State.Hosts (lines).
    # State.Calls records every change. Sticks = $false makes changes not take.
    function New-FakeOps([hashtable] $State, [bool] $Sticks = $true) {
        $all = @('wuauserv', 'BITS', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'CryptSvc', 'TrustedInstaller', 'ClipSVC', 'LicenseManager', 'InstallService', 'AppXSvc', 'wlidsvc', 'DiagTrack')
        if (-not $State.Services) { $State.Services = @{} }
        foreach ($n in $all) { if (-not $State.Services.ContainsKey($n) -and -not ($State.Missing -contains $n)) { $State.Services[$n] = 'Manual' } }
        foreach ($k in 'Policies', 'OnDisk') { if (-not $State[$k]) { $State[$k] = @{} } }
        if ($null -eq $State.Apps) { $State.Apps = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller') }
        if ($null -eq $State.Hosts) { $State.Hosts = @('# hosts', '127.0.0.1 localhost') }
        if (-not $State.ContainsKey('Managed')) { $State.Managed = $false }
        if (-not $State.ContainsKey('Point')) { $State.Point = $true }
        $State.Calls = [System.Collections.ArrayList]::new()
        $State.Admin = $(if ($State.ContainsKey('Admin')) { $State.Admin } else { $true })
        return @{
            GetServices     = { param($Names) $m = @{}; foreach ($n in $Names) { if ($State.Services.ContainsKey($n)) { $m[$n] = $State.Services[$n] } }; $m }.GetNewClosure()
            SetServiceStart = { param($Name, $Start) $null = $State.Calls.Add("sc $Name $Start"); if ($Sticks) { $State.Services[$Name] = 'Manual'; 0 } else { 5 } }.GetNewClosure()
            GetPolicy       = { param($Path, $Value) $State.Policies["$Path|$Value"] }.GetNewClosure()
            RemovePolicy    = { param($Path, $Value) $null = $State.Calls.Add("remove $Value"); if ($Sticks) { $State.Policies.Remove("$Path|$Value") } }.GetNewClosure()
            HasApp          = { param($Name) $State.Apps -contains $Name }.GetNewClosure()
            FindApp         = { param($Name) $State.OnDisk[$Name] }.GetNewClosure()
            RegisterApp     = { param($Folder) $null = $State.Calls.Add("register $Folder"); if ($Sticks) { foreach ($k in @($State.OnDisk.Keys)) { if ($State.OnDisk[$k] -eq $Folder) { $State.Apps += $k } } } }.GetNewClosure()
            ReadHosts       = { $State.Hosts }.GetNewClosure()
            WriteHosts      = { param($Lines) $null = $State.Calls.Add('write hosts'); if ($Sticks) { $State.Hosts = $Lines } }.GetNewClosure()
            BackupHosts     = { param($OutputRoot) $null = $State.Calls.Add('backup hosts'); 'C:\backup.txt' }.GetNewClosure()
            IsManaged       = { $State.Managed }.GetNewClosure()
            IsAdmin         = { $State.Admin }.GetNewClosure()
            RestorePoint    = { $null = $State.Calls.Add('restore point'); [pscustomobject]@{ Ok = $State.Point; Reason = 'System Protection is off' } }.GetNewClosure()
        }
    }

    $script:Tech = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Std = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Defender = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender|DisableAntiSpyware'
}

Describe 'Get-AfDebloatHostsLine' {
    It 'finds blocking lines for update and Store names, and ignores comments and other names' {
        InModuleScope AutoFixer {
            $lines = @('# 0.0.0.0 update.microsoft.com', '127.0.0.1 localhost', '0.0.0.0 fe2.update.microsoft.com # blocked', '0.0.0.0 example.com', '0.0.0.0   a.b  download.windowsupdate.com', '0.0.0.0 notwindowsupdate.com')
            $hits = @(Get-AfDebloatHostsLine -Lines $lines)
            $hits.Index | Should -Be @(2, 4)
            $hits[0].Names | Should -Be 'fe2.update.microsoft.com'
            $hits[1].Names | Should -Be 'download.windowsupdate.com'
        }
    }
}

Describe 'Get-AfDebloatFinding' {
    It 'finds nothing on a PC with Windows defaults' {
        InModuleScope AutoFixer -Parameters @{ Ops = (New-FakeOps @{}) } {
            param($Ops)
            @(Get-AfDebloatFinding -Ops $Ops) | Should -BeNullOrEmpty
        }
    }

    It 'offers to put back a disabled service at its Windows default start type' {
        InModuleScope AutoFixer -Parameters @{ Ops = (New-FakeOps @{ Services = @{ wuauserv = 'Disabled'; DoSvc = 'Disabled' } }) } {
            param($Ops)
            $f = @(Get-AfDebloatFinding -Ops $Ops)
            $f.Count | Should -Be 2
            $f[0].Fixable | Should -BeTrue
            $f[0].Change | Should -Match 'sc.exe config wuauserv start= demand'
            $f[1].Change | Should -Match 'start= delayed-auto'
        }
    }

    It 'reports a missing service and diagnostic data off as information only' {
        $ops = New-FakeOps @{ Missing = @('BITS'); Services = @{ DiagTrack = 'Disabled' }; Policies = @{ 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry' = 0 } }
        InModuleScope AutoFixer -Parameters @{ Ops = $ops } {
            param($Ops)
            $f = @(Get-AfDebloatFinding -Ops $Ops)
            $f.Count | Should -Be 3
            @($f | Where-Object Fixable) | Should -BeNullOrEmpty
            $f[0].Detail | Should -Match 'BITS is missing'
        }
    }

    It 'offers to remove a blocking policy on a home PC, but leaves it to IT on a work PC' {
        $homeState = New-FakeOps @{ Policies = @{ $script:Defender = 1; 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System|EnableSmartScreen' = 1 } }
        $work = New-FakeOps @{ Managed = $true; Policies = @{ $script:Defender = 1 } }
        InModuleScope AutoFixer -Parameters @{ HomeOps = $homeState; WorkOps = $work } {
            param($HomeOps, $WorkOps)
            # SmartScreen = 1 means on, so only the Defender value is a finding.
            $f = @(Get-AfDebloatFinding -Ops $HomeOps)
            $f.Count | Should -Be 1
            $f[0].Fixable | Should -BeTrue
            $f[0].Change | Should -Match 'DisableAntiSpyware'
            $w = @(Get-AfDebloatFinding -Ops $WorkOps)
            $w[0].Fixable | Should -BeFalse
            $w[0].Detail | Should -Match 'work PC'
        }
    }

    It 'offers to register a missing Store app only when its files are on the PC and Auto-Fixer is admin' {
        $ops = New-FakeOps @{ Apps = @('Microsoft.DesktopAppInstaller'); OnDisk = @{ 'Microsoft.WindowsStore' = 'C:\Apps\Store' } }
        $gone = New-FakeOps @{ Apps = @('Microsoft.DesktopAppInstaller') }
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Gone = $gone } {
            param($Ops, $Gone)
            $f = @(Get-AfDebloatFinding -Ops $Ops)
            $f[0].Fixable | Should -BeTrue
            $f[0].Change | Should -Match 'Register Microsoft.WindowsStore'
            @(Get-AfDebloatFinding -Ops $Ops -IsAdmin $false)[0].Fixable | Should -BeFalse
            $g = @(Get-AfDebloatFinding -Ops $Gone)
            $g[0].Fixable | Should -BeFalse
            $g[0].Detail | Should -Match 'wsreset -i'
        }
    }
}

Describe 'Invoke-AfDebloatFix' {
    It 'says nothing to put back and asks no question on a PC with defaults' {
        $state = @{}
        $ops = New-FakeOps $state
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader) } {
            param($Ops, $Root, $Tech, $Keys0)
            $r = Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $Ops 6>$null
            $r.Tag | Should -Be 'NOTHING'
            Test-Path -LiteralPath $r.LogPath | Should -BeTrue
        }
        $state.Calls.Count | Should -Be 0
    }

    It 'changes nothing when the user says No to the list' {
        $state = @{ Services = @{ wuauserv = 'Disabled' } }
        $ops = New-FakeOps $state
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader 'N') } {
            param($Ops, $Root, $Tech, $Keys0)
            (Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $Ops 6>$null).Tag | Should -Be 'CANCELLED'
        }
        $state.Calls.Count | Should -Be 0
    }

    It 'makes a restore point, then asks for each item and changes only the ones said Yes to' {
        $state = @{ Services = @{ wuauserv = 'Disabled'; BITS = 'Disabled' }; Policies = @{ $script:Defender = 1 } }
        $ops = New-FakeOps $state
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader 'Y', 'Y', 'N', 'Y') } {
            param($Ops, $Root, $Tech, $Keys0)
            $r = Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $Ops 6>$null
            $r.Tag | Should -Be 'OK'
            $r.Fixed | Should -Be 2
            (Get-Content -LiteralPath $r.LogPath -Raw) | Should -Match 'SKIPPED'
        }
        $state.Calls | Should -Be @('restore point', 'sc wuauserv demand', 'remove DisableAntiSpyware')
        $state.Services.BITS | Should -Be 'Disabled'
    }

    It 'reports FAILED with the exit code when a change does not stick' {
        $state = @{ Services = @{ WaaSMedicSvc = 'Disabled' } }
        $ops = New-FakeOps $state -Sticks $false
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader 'Y', 'Y') } {
            param($Ops, $Root, $Tech, $Keys0)
            $r = Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $Ops 6>$null
            $r.Tag | Should -Be 'FAILED'
            (Get-Content -LiteralPath $r.LogPath -Raw) | Should -Match 'exit code 5 \(access denied'
        }
    }

    It 'without a restore point: Technician is warned and goes on, Standard is asked' {
        $tech = @{ Point = $false; Services = @{ wuauserv = 'Disabled' } }
        $std = @{ Point = $false; Services = @{ wuauserv = 'Disabled' } }
        $techOps = New-FakeOps $tech
        $stdOps = New-FakeOps $std
        InModuleScope AutoFixer -Parameters @{ TechOps = $techOps; StdOps = $stdOps; Root = $TestDrive; Tech = $script:Tech; Std = $script:Std; Keys0 = (New-KeyReader 'Y', 'Y'); Keys1 = (New-KeyReader 'Y', 'N') } {
            param($TechOps, $StdOps, $Root, $Tech, $Std, $Keys0, $Keys1)
            (Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $TechOps 6>$null).Fixed | Should -Be 1
            (Invoke-AfDebloatFix -Settings $Std -OutputRoot $Root -ReadKey $Keys1 -Ops $StdOps 6>$null).Tag | Should -Be 'CANCELLED'
        }
        $tech.Calls | Should -Be @('restore point', 'sc wuauserv demand')
        $std.Calls | Should -Be @('restore point')
    }

    It 'changes nothing without admin rights' {
        $state = @{ Admin = $false; Services = @{ wuauserv = 'Disabled' } }
        $ops = New-FakeOps $state
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader) } {
            param($Ops, $Root, $Tech, $Keys0)
            (Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $Ops 6>$null).Tag | Should -Be 'CANCELLED'
        }
        $state.Calls.Count | Should -Be 0
    }

    It 'backs up the hosts file and turns only the blocking lines into comments' {
        $state = @{ Hosts = @('127.0.0.1 localhost', '0.0.0.0 update.microsoft.com', '0.0.0.0 example.com') }
        $ops = New-FakeOps $state
        InModuleScope AutoFixer -Parameters @{ Ops = $ops; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader 'Y', 'Y') } {
            param($Ops, $Root, $Tech, $Keys0)
            (Invoke-AfDebloatFix -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -Ops $Ops 6>$null).Fixed | Should -Be 1
        }
        $state.Calls | Should -Be @('restore point', 'backup hosts', 'write hosts')
        $state.Hosts | Should -Be @('127.0.0.1 localhost', '# Auto-Fixer put back: 0.0.0.0 update.microsoft.com', '0.0.0.0 example.com')
    }
}

Describe 'Repair menu' {
    It 'opens the debloat damage check on D' {
        $called = @{ N = 0 }
        $fix = { $called.N++ }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ Fix = $fix; Root = $TestDrive; Tech = $script:Tech; Keys0 = (New-KeyReader 'D', 'x', 'B') } {
            param($Fix, $Root, $Tech, $Keys0)
            Invoke-AfRepairMenu -Settings $Tech -OutputRoot $Root -ReadKey $Keys0 -DebloatFix $Fix -RunBatch { throw 'ran a repair' } 6>$null *>$null
        }
        $called.N | Should -Be 1
    }
}
