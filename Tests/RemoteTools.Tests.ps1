# Remote access check. Nothing real runs here: every source (registry, services, tasks,
# startup, processes, files), the uninstaller, the restore point and the keyboard are
# fakes. A key queue that runs dry fails the test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    $script:Standard = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Tech = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:NotManaged = [pscustomobject]@{ IsManaged = $false; Reasons = @() }
    $script:Managed = [pscustomobject]@{ IsManaged = $true; Reasons = @('joined to Microsoft Entra (Azure AD)') }

    # A PC with TeamViewer installed but hidden from Apps, AnyDesk as a loose copy in
    # Downloads, an RMM agent, a remote-sounding unknown program, and Windows' own parts.
    $script:Sources = @{
        Programs  = {
            [pscustomobject]@{ Source = 'Installed programs'; DisplayName = 'TeamViewer'; Publisher = 'TeamViewer'; Version = '15.50.5'; InstallDate = '20261101'; InstallLocation = 'C:\Program Files\TeamViewer'; UninstallString = '"C:\Program Files\TeamViewer\uninstall.exe"'; SystemComponent = $true; KeyName = 'TeamViewer' }
            [pscustomobject]@{ Source = 'Installed programs'; DisplayName = 'Contoso Remote Helper'; Publisher = 'Contoso'; Version = '1.0'; InstallDate = ''; InstallLocation = 'C:\Program Files\Contoso'; UninstallString = 'MsiExec.exe /I{12345678-ABCD-ABCD-ABCD-1234567890AB}'; SystemComponent = $false; KeyName = '{12345678-ABCD-ABCD-ABCD-1234567890AB}' }
            [pscustomobject]@{ Source = 'Installed programs'; DisplayName = 'Microsoft Remote Desktop'; Publisher = 'Microsoft Corporation'; Version = '1.2'; InstallDate = ''; InstallLocation = ''; UninstallString = 'MsiExec.exe /X{AAAAAAAA-ABCD-ABCD-ABCD-1234567890AB}'; SystemComponent = $false; KeyName = 'x' }
            [pscustomobject]@{ Source = 'Installed programs'; DisplayName = 'Notepad++'; Publisher = 'Notepad++ Team'; Version = '8'; InstallDate = ''; InstallLocation = 'C:\Program Files\Notepad++'; UninstallString = '"C:\Program Files\Notepad++\uninstall.exe"'; SystemComponent = $false; KeyName = 'npp' }
        }
        Services  = {
            [pscustomobject]@{ Source = 'Services'; Name = 'TeamViewer'; DisplayName = 'TeamViewer'; Path = '"C:\Program Files\TeamViewer\TeamViewer_Service.exe"'; StartMode = 'Auto'; State = 'Running' }
            [pscustomobject]@{ Source = 'Services'; Name = 'NinjaRMMAgent'; DisplayName = 'NinjaRMMAgent'; Path = 'C:\ProgramData\NinjaRMMAgent\NinjaRMMAgent.exe'; StartMode = 'Auto'; State = 'Running' }
            [pscustomobject]@{ Source = 'Services'; Name = 'TermService'; DisplayName = 'Remote Desktop Services'; Path = 'C:\Windows\System32\svchost.exe -k NetworkService'; StartMode = 'Manual'; State = 'Stopped' }
        }
        Tasks     = { }
        Startup   = { }
        Processes = { [pscustomobject]@{ Source = 'Running now'; Name = 'TeamViewer.exe'; Path = 'C:\Program Files\TeamViewer\TeamViewer.exe' } }
        Files     = {
            [pscustomobject]@{ Source = 'Files (not installed)'; Name = 'AnyDesk.exe'; Path = 'C:\Users\pat\Downloads\AnyDesk.exe' }
            [pscustomobject]@{ Source = 'Files (not installed)'; Name = 'remote-setup.exe'; Path = 'C:\Users\pat\Downloads\remote-setup.exe' }
        }
    }
}

Describe 'Get-AfRemoteToolList' {
    It 'loads the known tools, each with a name, a kind and a working pattern' {
        InModuleScope AutoFixer {
            $list = @(Get-AfRemoteToolList)
            $list.Count | Should -BeGreaterThan 30
            foreach ($t in $list) {
                $t.Name | Should -Not -BeNullOrEmpty
                $t.Kind | Should -BeIn @('Remote control', 'IT management agent')
                { [regex]::new($t.Pattern) } | Should -Not -Throw
            }
            ($list | Where-Object Name -eq 'TeamViewer').Kind | Should -Be 'Remote control'
            ($list | Where-Object Name -eq 'NinjaOne').Kind | Should -Be 'IT management agent'
        }
    }

    It 'does not match everyday names' {
        InModuleScope AutoFixer {
            $list = @(Get-AfRemoteToolList)
            foreach ($name in 'Notepad++', 'Microsoft Edge', 'Lateral Thinking Game', 'Synchronization Host', 'Adobe Acrobat', 'Google Chrome') {
                @($list | Where-Object { $name -match $_.Pattern }).Count | Should -Be 0 -Because $name
            }
        }
    }
}

Describe 'Find-AfRemoteTool' {
    BeforeAll {
        $script:Result = InModuleScope AutoFixer -Parameters @{ Sources = $script:Sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        $script:ByName = @{}
        foreach ($f in $script:Result.Findings) { $script:ByName[$f.Name] = $f }
    }

    It 'groups every source of one tool into one finding' {
        $tv = $script:ByName['TeamViewer']
        $tv | Should -Not -BeNullOrEmpty
        $tv.FoundIn | Should -Be @('Installed programs', 'Services', 'Running now')
        $tv.Running | Should -BeTrue
        $tv.StartsWithWindows | Should -BeTrue
        $tv.Version | Should -Be '15.50.5'
    }

    It 'flags an install that hides from the Apps list' {
        $script:ByName['TeamViewer'].HiddenFromApps | Should -BeTrue
        $script:ByName['TeamViewer'].Portable | Should -BeFalse
    }

    It 'finds a copy that runs without being installed' {
        $any = $script:ByName['AnyDesk']
        $any.Portable | Should -BeTrue
        $any.HiddenFromApps | Should -BeFalse
        $any.FoundIn | Should -Be @('Files (not installed)')
    }

    It 'marks IT management agents by kind' {
        $script:ByName['NinjaOne'].Kind | Should -Be 'IT management agent'
    }

    It 'lists a remote-sounding unknown program as Possible, but never Windows or Microsoft parts or loose files' {
        $script:ByName['Contoso Remote Helper'].Kind | Should -Be 'Possible, check it'
        $script:ByName.Keys | Should -Not -Contain 'Microsoft Remote Desktop'
        $script:ByName.Keys | Should -Not -Contain 'Remote Desktop Services'
        $script:ByName.Keys | Should -Not -Contain 'remote-setup.exe'
        $script:ByName.Keys | Should -Not -Contain 'Notepad++'
    }

    It 'puts known tools before the ones to check by hand' {
        $script:Result.Findings[-1].Kind | Should -Be 'Possible, check it'
    }

    It 'keeps going when one source fails, and names it' {
        $sources = $script:Sources.Clone()
        $sources.Services = { throw 'access denied' }
        $r = InModuleScope AutoFixer -Parameters @{ Sources = $sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        $r.Skipped | Should -Be @('Services: access denied')
        @($r.Findings | Where-Object Name -eq 'TeamViewer').Count | Should -Be 1
    }

    It 'finds nothing on a clean PC' {
        $empty = @{ Programs = { }; Services = { }; Tasks = { }; Startup = { }; Processes = { }; Files = { } }
        $r = InModuleScope AutoFixer -Parameters @{ Sources = $empty } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        @($r.Findings).Count | Should -Be 0
    }
}

Describe 'Get-AfRemoteProgramPath' {
    It 'keeps only the program file, so connection details in the arguments never reach the screen or the log' {
        InModuleScope AutoFixer {
            $sc = Get-AfRemoteProgramPath '"C:\Program Files (x86)\ScreenConnect Client (a1b2c3d4e5f60708)\ScreenConnect.ClientService.exe" "?e=Access&h=relay.example.net&p=443&s=0f0f0f0f-1111-2222-3333-444455556666&k=BgIAAACk&v=AAAA"'
            $sc | Should -Be 'C:\Program Files (x86)\ScreenConnect Client (<ID>)\ScreenConnect.ClientService.exe'
            Get-AfRemoteProgramPath 'C:\Program Files\TightVNC\tvnserver.exe -controlservice -slave' | Should -Be 'C:\Program Files\TightVNC\tvnserver.exe'
            Get-AfRemoteProgramPath '"C:\Program Files\Google\remoting_host.exe" --host-config="C:\ProgramData\host.json"' | Should -Be 'C:\Program Files\Google\remoting_host.exe'
            Get-AfRemoteProgramPath 'C:\Program Files\Parsec' | Should -Be 'C:\Program Files\Parsec'
        }
    }
}

Describe 'Known tools found on a real PC (BEASTLY Part A, 2026-11-09)' {
    It 'names the TightVNC service TightVNC, not RealVNC, and lists it once' {
        $sources = @{
            Programs  = { [pscustomobject]@{ Source = 'Installed programs'; DisplayName = 'TightVNC'; Publisher = 'GlavSoft LLC.'; Version = '2.8.85.0'; InstallDate = ''; InstallLocation = ''; UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'; SystemComponent = $false; KeyName = 'x' } }
            Services  = { [pscustomobject]@{ Source = 'Services'; Name = 'tvnserver'; DisplayName = 'TightVNC Server'; Path = '"C:\Program Files\TightVNC\tvnserver.exe" -service'; StartMode = 'Auto'; State = 'Running' } }
            Tasks     = { }; Startup = { }; Processes = { }; Files = { }
        }
        $r = InModuleScope AutoFixer -Parameters @{ Sources = $sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        @($r.Findings).Count | Should -Be 1
        $r.Findings[0].Name | Should -Be 'TightVNC'
        $r.Findings[0].HiddenFromApps | Should -BeFalse
        ($r.Findings[0].Paths -join ' ') | Should -Not -Match '-service'
    }

    It 'shows a 4-part version as a version, not as a hidden IP address, in the log text' {
        $scan = [pscustomobject]@{ Skipped = @(); Findings = @([pscustomobject]@{ Name = 'Parsec'; Kind = 'Remote control'; Version = '150.97.0.0'; Running = $true; StartsWithWindows = $true; HiddenFromApps = $false; Portable = $false; FoundIn = @('Services'); Paths = @('C:\Program Files\Parsec\pservice.exe') }) }
        $lines = InModuleScope AutoFixer -Parameters @{ Scan = $scan; M = $script:NotManaged } {
            param($Scan, $M)
            $r = New-AfRedactor -Names @('pat') -Serials @()
            foreach ($l in (Format-AfRemoteReport -Scan $Scan -Managed $M -Redactor $r)) { Protect-AfText -Redactor $r -Text $l }
        }
        ($lines -join "`n") | Should -Match 'Parsec version 150\.97\.0\.0'
        ($lines -join "`n") | Should -Not -Match '<IP-'
    }
}

Describe 'Get-AfBuiltInRemoteState' {
    It 'reads Windows'' own remote features and never fails' {
        $values = @{ 'fDenyTSConnections' = 0; 'fAllowToGetHelp' = 1 }
        $state = InModuleScope AutoFixer -Parameters @{ V = $values } {
            param($V)
            Get-AfBuiltInRemoteState -GetValue ({ param($Path, $Name) $null = $Path; $V[$Name] }.GetNewClosure()) `
                -GetService { param($Name) if ($Name -eq 'sshd') { throw 'no such service' }; [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } } `
                -HasQuickAssist { $true }
        }
        ($state | Where-Object Name -eq 'Remote Desktop').State | Should -Match '^ON'
        ($state | Where-Object Name -eq 'Remote Assistance').State | Should -Match '^On'
        ($state | Where-Object Name -eq 'OpenSSH Server').State | Should -Be 'Not installed'
        ($state | Where-Object Name -like '*WinRM*').State | Should -Be 'Installed, running, starts automatic'
    }

    It 'says Not known when Windows cannot tell' {
        $state = InModuleScope AutoFixer {
            Get-AfBuiltInRemoteState -GetValue { throw 'no key' } -GetService { $null } -HasQuickAssist { throw 'no appx' }
        }
        ($state | Where-Object Name -eq 'Remote Desktop').State | Should -Be 'Not known'
        ($state | Where-Object Name -eq 'Quick Assist').State | Should -Be 'Not known'
    }
}

Describe 'Test-AfManagedPc' {
    It 'is not managed on a home PC' {
        $m = InModuleScope AutoFixer { Test-AfManagedPc -IsDomainJoined { $false } -IsAzureAdJoined { $false } -IsMdmEnrolled { $false } }
        $m.IsManaged | Should -BeFalse
    }

    It 'is managed when joined, enrolled or running an IT agent, and says why' {
        $m = InModuleScope AutoFixer { Test-AfManagedPc -IsDomainJoined { $false } -IsAzureAdJoined { $true } -IsMdmEnrolled { $true } }
        $m.IsManaged | Should -BeTrue
        $m.Reasons.Count | Should -Be 2
        $agent = [pscustomobject]@{ Name = 'NinjaOne'; Kind = 'IT management agent' }
        $m = InModuleScope AutoFixer -Parameters @{ A = $agent } { param($A) Test-AfManagedPc -Findings @($A) -IsDomainJoined { $false } -IsAzureAdJoined { $false } -IsMdmEnrolled { $false } }
        $m.IsManaged | Should -BeTrue
        $m.Reasons[0] | Should -Match 'NinjaOne'
    }

    It 'treats a check that fails as No' {
        $m = InModuleScope AutoFixer { Test-AfManagedPc -IsDomainJoined { throw 'x' } -IsAzureAdJoined { $null } -IsMdmEnrolled { throw 'y' } }
        $m.IsManaged | Should -BeFalse
    }
}

Describe 'Get-AfUninstallCommand' {
    It 'runs a quoted vendor uninstaller with its own arguments' {
        $c = InModuleScope AutoFixer { Get-AfUninstallCommand -UninstallString '"C:\Program Files\AnyDesk\AnyDesk.exe" --uninstall' -FileExists { $true } }
        $c.Ok | Should -BeTrue
        $c.FilePath | Should -Be 'C:\Program Files\AnyDesk\AnyDesk.exe'
        $c.Arguments | Should -Be '--uninstall'
    }

    It 'reads an unquoted path with spaces up to .exe' {
        $c = InModuleScope AutoFixer { Get-AfUninstallCommand -UninstallString 'C:\Program Files (x86)\Splashtop\uninst.exe /S2' -FileExists { $true } }
        $c.FilePath | Should -Be 'C:\Program Files (x86)\Splashtop\uninst.exe'
        $c.Arguments | Should -Be '/S2'
    }

    It 'turns an MSI install string into msiexec /x with its own window' {
        $c = InModuleScope AutoFixer { Get-AfUninstallCommand -UninstallString 'MsiExec.exe /I{12345678-abcd-ABCD-ABCD-1234567890AB}' -FileExists { $false } -SystemFolder 'C:\Windows\System32' }
        $c.Ok | Should -BeTrue
        $c.FilePath | Should -Be 'C:\Windows\System32\msiexec.exe'
        $c.Arguments | Should -Be '/x {12345678-ABCD-ABCD-ABCD-1234567890AB}'
        $c.Arguments | Should -Not -Match '/q'
    }

    It 'refuses a missing file, a command shell, a script host and an empty entry' {
        InModuleScope AutoFixer {
            (Get-AfUninstallCommand -UninstallString '"C:\Gone\uninstall.exe"' -FileExists { $false }).Ok | Should -BeFalse
            (Get-AfUninstallCommand -UninstallString 'C:\Windows\System32\cmd.exe /c del C:\x' -FileExists { $true }).Ok | Should -BeFalse
            (Get-AfUninstallCommand -UninstallString '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File x.ps1' -FileExists { $true }).Ok | Should -BeFalse
            (Get-AfUninstallCommand -UninstallString 'mshta.exe vbscript:Close' -FileExists { $true }).Ok | Should -BeFalse
            (Get-AfUninstallCommand -UninstallString '' -FileExists { $true }).Ok | Should -BeFalse
            (Get-AfUninstallCommand -UninstallString '"C:\x\uninstall.exe' -FileExists { $true }).Ok | Should -BeFalse
        }
    }
}

Describe 'Get-AfUninstallExitText' {
    It 'explains the common codes and shows any other number' {
        InModuleScope AutoFixer {
            Get-AfUninstallExitText 0 | Should -Match 'without an error'
            Get-AfUninstallExitText 1602 | Should -Match 'Cancelled'
            Get-AfUninstallExitText 3010 | Should -Match 'restart'
            Get-AfUninstallExitText 77 | Should -Match '77'
        }
    }
}

Describe 'Format-AfRemoteReport' {
    It 'hides the user name in paths, warns on a managed PC and states the honest limit' {
        $scan = InModuleScope AutoFixer -Parameters @{ Sources = $script:Sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        $lines = InModuleScope AutoFixer -Parameters @{ Scan = $scan; M = $script:Managed } {
            param($Scan, $M)
            $r = New-AfRedactor -Names @('pat') -Serials @()
            Format-AfRemoteReport -Scan $Scan -BuiltIn @([pscustomobject]@{ Name = 'Remote Desktop'; State = 'Off' }) -Managed $M -Redactor $r
        }
        $text = $lines -join "`n"
        $text | Should -Match 'looks managed by an organization'
        $text | Should -Match 'NOT IN APPS LIST'
        $text | Should -Match 'Remote Desktop: Off'
        $text | Should -Match 'renamed or custom tool can still hide'
        $text | Should -Not -Match '\\pat\\'
    }
}

Describe 'Get-AfRemovalPlan' {
    BeforeAll {
        $script:Tv = [pscustomobject]@{ Name = 'TeamViewer'; Kind = 'Remote control'; Portable = $false
            Programs = @([pscustomobject]@{ UninstallString = '"C:\Program Files\TeamViewer\uninstall.exe"' }) }
        $script:Agent = [pscustomobject]@{ Name = 'NinjaOne'; Kind = 'IT management agent'; Portable = $false
            Programs = @([pscustomobject]@{ UninstallString = '"C:\Program Files\Ninja\uninstall.exe"' }) }
        $script:Loose = [pscustomobject]@{ Name = 'AnyDesk'; Kind = 'Remote control'; Portable = $true; Programs = @() }
    }

    It 'offers no removal in Standard mode on a managed PC' {
        $p = InModuleScope AutoFixer -Parameters @{ F = $script:Tv; M = $script:Managed } { param($F, $M) Get-AfRemovalPlan -Finding $F -Managed $M -Mode 'Standard' -FileExists { $true } }
        $p.Action | Should -Be 'Blocked'
    }

    It 'lets Technician mode remove on a managed PC, with the extra warning' {
        $p = InModuleScope AutoFixer -Parameters @{ F = $script:Tv; M = $script:Managed } { param($F, $M) Get-AfRemovalPlan -Finding $F -Managed $M -Mode 'Technician' -FileExists { $true } }
        $p.Action | Should -Be 'Run'
        $p.ExtraWarning | Should -BeTrue
    }

    It 'always warns extra for an IT management agent' {
        $p = InModuleScope AutoFixer -Parameters @{ F = $script:Agent; M = $script:NotManaged } { param($F, $M) Get-AfRemovalPlan -Finding $F -Managed $M -FileExists { $true } }
        $p.ExtraWarning | Should -BeTrue
        $p = InModuleScope AutoFixer -Parameters @{ F = $script:Tv; M = $script:NotManaged } { param($F, $M) Get-AfRemovalPlan -Finding $F -Managed $M -FileExists { $true } }
        $p.ExtraWarning | Should -BeFalse
    }

    It 'gives manual steps when there is no uninstaller' {
        $p = InModuleScope AutoFixer -Parameters @{ F = $script:Loose; M = $script:NotManaged } { param($F, $M) Get-AfRemovalPlan -Finding $F -Managed $M -FileExists { $true } }
        $p.Action | Should -Be 'Manual'
        $p.Reason | Should -Match 'without being installed'
    }
}

Describe 'Invoke-AfRemoteToolRemoval' {
    BeforeEach {
        $script:Runs = [System.Collections.ArrayList]::new()
        $runs = $script:Runs
        $script:Run = { param($FilePath, $Arguments) $null = $runs.Add(('{0}|{1}' -f $FilePath, $Arguments)); 0 }.GetNewClosure()
        $script:Rp = [System.Collections.ArrayList]::new()
        $rp = $script:Rp
        $script:Restore = { $null = $rp.Add('rp'); [pscustomobject]@{ Ok = $true; Reason = $null } }.GetNewClosure()
        $script:Finding = [pscustomobject]@{ Name = 'TeamViewer'; Kind = 'Remote control'; Portable = $false; FoundIn = @('Installed programs')
            Programs = @([pscustomobject]@{ UninstallString = '"C:\Program Files\TeamViewer\uninstall.exe"' }) }
    }

    It 'asks for a restore point and Y, runs the vendor uninstaller, then checks again' {
        $r = InModuleScope AutoFixer -Parameters @{ F = $script:Finding; M = $script:NotManaged; S = $script:Standard; Run = $script:Run; Rp = $script:Restore; Keys = (New-KeyReader 'y', 'y', 'Enter') } {
            param($F, $M, $S, $Run, $Rp, $Keys)
            Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -ReadKey $Keys -FileExists { $true } -RunUninstaller $Run -RestorePoint $Rp -Recheck { $null } 6>$null
        }
        $r.Result | Should -Be 'Ran'
        $r.ExitCode | Should -Be 0
        $r.StillFound | Should -BeFalse
        $script:Rp.Count | Should -Be 1
        $script:Runs | Should -Be @('C:\Program Files\TeamViewer\uninstall.exe|')
    }

    It 'runs nothing when the answer is N' {
        $r = InModuleScope AutoFixer -Parameters @{ F = $script:Finding; M = $script:NotManaged; S = $script:Standard; Run = $script:Run; Rp = $script:Restore; Keys = (New-KeyReader 'n', 'n') } {
            param($F, $M, $S, $Run, $Rp, $Keys)
            Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -ReadKey $Keys -FileExists { $true } -RunUninstaller $Run -RestorePoint $Rp -Recheck { $null } 6>$null
        }
        $r.Result | Should -Be 'Declined'
        $script:Runs.Count | Should -Be 0
        $script:Rp.Count | Should -Be 0
    }

    It 'reports a cancelled uninstall and that the program is still there' {
        $cancel = { param($FilePath, $Arguments) $null = $FilePath; $null = $Arguments; 1602 }
        $still = { param($Name) [pscustomobject]@{ Name = $Name; FoundIn = @('Services') } }
        $r = InModuleScope AutoFixer -Parameters @{ F = $script:Finding; M = $script:NotManaged; S = $script:Standard; Run = $cancel; Again = $still; Keys = (New-KeyReader 'n', 'y', 'Enter') } {
            param($F, $M, $S, $Run, $Again, $Keys)
            Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -ReadKey $Keys -FileExists { $true } -RunUninstaller $Run -RestorePoint { throw 'not asked' } -Recheck $Again 6>$null
        }
        $r.ExitCode | Should -Be 1602
        $r.StillFound | Should -BeTrue
    }

    It 'shows the IT warning first on a managed PC in Technician mode, and N there runs nothing' {
        $r = InModuleScope AutoFixer -Parameters @{ F = $script:Finding; M = $script:Managed; S = $script:Tech; Run = $script:Run; Keys = (New-KeyReader 'n') } {
            param($F, $M, $S, $Run, $Keys)
            Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -ReadKey $Keys -FileExists { $true } -RunUninstaller $Run -Recheck { $null } 6>$null
        }
        $r.Result | Should -Be 'Declined'
        $script:Runs.Count | Should -Be 0
    }

    It 'asks nothing and runs nothing in Standard mode on a managed PC' {
        $r = InModuleScope AutoFixer -Parameters @{ F = $script:Finding; M = $script:Managed; S = $script:Standard; Run = $script:Run; Keys = (New-KeyReader) } {
            param($F, $M, $S, $Run, $Keys)
            Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -ReadKey $Keys -FileExists { $true } -RunUninstaller $Run -Recheck { $null } 6>$null
        }
        $r.Result | Should -Be 'Blocked'
        $script:Runs.Count | Should -Be 0
    }

    It 'only offers to open Settings when there is no uninstaller' {
        $loose = [pscustomobject]@{ Name = 'AnyDesk'; Kind = 'Remote control'; Portable = $true; FoundIn = @('Files (not installed)'); Programs = @() }
        $opened = [System.Collections.ArrayList]::new()
        $open = { $null = $opened.Add('settings') }.GetNewClosure()
        $r = InModuleScope AutoFixer -Parameters @{ F = $loose; M = $script:NotManaged; S = $script:Standard; Run = $script:Run; Open = $open; Keys = (New-KeyReader 'y') } {
            param($F, $M, $S, $Run, $Open, $Keys)
            Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -ReadKey $Keys -RunUninstaller $Run -OpenAppsSettings $Open -Recheck { $null } 6>$null
        }
        $r.Result | Should -Be 'Manual'
        $opened.Count | Should -Be 1
        $script:Runs.Count | Should -Be 0
    }
}

Describe 'Invoke-AfRemoteAccessMenu' {
    BeforeEach { Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue }

    It 'scans, writes a redacted log, and returns on any key without removing' {
        $removed = [System.Collections.ArrayList]::new()
        $remove = { param($F) $null = $removed.Add($F.Name) }.GetNewClosure()
        $scan = InModuleScope AutoFixer -Parameters @{ Sources = $script:Sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        $find = { $scan }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Standard; Root = (Join-Path $TestDrive 'Runs'); Find = $find; Remove = $remove; Keys = (New-KeyReader 'x') } {
            param($S, $Root, $Find, $Remove, $Keys)
            Invoke-AfRemoteAccessMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -Find $Find -BuiltIn { } -Managed { [pscustomobject]@{ IsManaged = $false; Reasons = @() } } -Remove $Remove 6>$null
        }
        $removed.Count | Should -Be 0
        $log = @(Get-ChildItem (Join-Path $TestDrive 'Runs') -Recurse -Filter '*-remote.log')
        $log.Count | Should -Be 1
        (Get-Content $log[0].FullName -Raw) | Should -Match 'TeamViewer'
    }

    It 'removes only the one program picked, after R' {
        $removed = [System.Collections.ArrayList]::new()
        $remove = { param($F) $null = $removed.Add($F.Name) }.GetNewClosure()
        $scan = InModuleScope AutoFixer -Parameters @{ Sources = $script:Sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        $find = { $scan }.GetNewClosure()
        $first = $scan.Findings[0].Name
        InModuleScope AutoFixer -Parameters @{ S = $script:Tech; Root = (Join-Path $TestDrive 'Runs'); Find = $find; Remove = $remove; Keys = (New-KeyReader 'R', '1', 'Enter') } {
            param($S, $Root, $Find, $Remove, $Keys)
            Invoke-AfRemoteAccessMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -Find $Find -BuiltIn { } -Managed { [pscustomobject]@{ IsManaged = $false; Reasons = @() } } -Remove $Remove 6>$null
        }
        $removed | Should -Be @($first)
    }

    It 'offers no removal on a managed PC in Standard mode' {
        $removed = [System.Collections.ArrayList]::new()
        $remove = { param($F) $null = $removed.Add($F.Name) }.GetNewClosure()
        $scan = InModuleScope AutoFixer -Parameters @{ Sources = $script:Sources } { param($Sources) Find-AfRemoteTool -Sources $Sources }
        $find = { $scan }.GetNewClosure()
        # One key only: R here just returns to the menu.
        InModuleScope AutoFixer -Parameters @{ S = $script:Standard; Root = (Join-Path $TestDrive 'Runs'); Find = $find; Remove = $remove; M = $script:Managed; Keys = (New-KeyReader 'R') } {
            param($S, $Root, $Find, $Remove, $M, $Keys)
            Invoke-AfRemoteAccessMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -Find $Find -BuiltIn { } -Managed ({ $M }.GetNewClosure()) -Remove $Remove 6>$null
        }
        $removed.Count | Should -Be 0
    }

    It 'opens from the main menu with E and with 6' {
        $opened = [System.Collections.ArrayList]::new()
        $remote = { param($S) $null = $S; $null = $opened.Add('remote') }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -RemoteAction $remote `
            -ReadKey (New-KeyReader 'Enter', 'e', '6', 'q', 'y') 6>$null
        $opened.Count | Should -Be 2
    }
}
