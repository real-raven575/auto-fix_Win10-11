# DISM version and repair-source check. Registry reads, file versions and dism.exe
# are all passed in, so every cause is tested without Windows and nothing runs DISM.
BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    # A fake registry: path -> properties; a missing path throws, like Get-ItemProperty.
    function New-FakeRegistry([hashtable] $Keys) {
        return {
            param($Path)
            if (-not $Keys.ContainsKey($Path)) { throw "Cannot find path '$Path'." }
            [pscustomobject]$Keys[$Path]
        }.GetNewClosure()
    }

    $script:Cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:Servicing = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'
    $script:Au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $script:Win11 = @{ CurrentBuild = '26100'; UBR = 4652; DisplayVersion = '24H2'; EditionID = 'Professional'; ProductName = 'Windows 10 Pro' }

    # What "dism /English /Get-WimInfo" prints, first the list, then one index.
    $script:WimList = @(
        'Deployment Image Servicing and Management tool', 'Version: 10.0.26100.1', '',
        'Details for image : E:\sources\install.wim', '',
        'Index : 1', 'Name : Windows 11 Home', 'Description : Windows 11 Home', 'Size : 18,000,000,000 bytes', '',
        'Index : 6', 'Name : Windows 11 Pro', 'Description : Windows 11 Pro', 'Size : 18,500,000,000 bytes', '',
        'The operation completed successfully.')
    function Get-WimDetail([int] $Index, [string] $Edition, [int] $Build = 26100, [int] $Ubr = 1742) {
        @('Details for image : E:\sources\install.wim', '', "Index : $Index", "Name : Windows 11 $Edition", "Version : 10.0.$Build",
            "ServicePack Build : $Ubr", 'ServicePack Level : 0', "Edition : $Edition", 'Installation : Client',
            'Languages :', '        en-US (Default)', 'Created : 9/5/2026 - 6:12:34 AM', '', 'The operation completed successfully.')
    }
}

Describe 'Reading this PC' {
    It 'names Windows 11 by its build, not by ProductName' {
        InModuleScope AutoFixer -Parameters @{ R = (New-FakeRegistry @{ $script:Cv = $script:Win11 }) } {
            param($R)
            $os = Get-AfOsBuild -ReadRegistry $R
            $os.Name | Should -Be 'Windows 11'
            $os.Build | Should -Be 26100
            $os.Ubr | Should -Be 4652
            $os.Text | Should -Be 'Windows 11 24H2, build 26100.4652, Professional'
        }
    }

    It 'names the Windows Insider channel when the PC has one' {
        $reg = New-FakeRegistry @{ $script:Cv = $script:Win11; 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' = @{ BranchName = 'Dev' } }
        InModuleScope AutoFixer -Parameters @{ R = $reg } {
            param($R)
            $os = Get-AfOsBuild -ReadRegistry $R
            $os.Insider | Should -Be 'Dev'
            $os.Text | Should -Match 'Windows Insider \(Dev\)$'
        }
    }

    It 'returns nothing when the build cannot be read' {
        InModuleScope AutoFixer -Parameters @{ R = (New-FakeRegistry @{}) } {
            param($R)
            Get-AfOsBuild -ReadRegistry $R | Should -BeNullOrEmpty
        }
    }

    It 'reads the DISM file version, and says "not found" when it is missing' {
        InModuleScope AutoFixer {
            $v = [pscustomobject]@{ FileMajorPart = 10; FileMinorPart = 0; FileBuildPart = 26100; FilePrivatePart = 4652 }
            $d = Get-AfDismBuild -Path 'C:\Windows\System32\dism.exe' -GetVersion { $v }.GetNewClosure()
            $d.Build | Should -Be 26100
            $d.Text | Should -Be '10.0.26100.4652'
            (Get-AfDismBuild -Path 'C:\nope\dism.exe' -GetVersion { throw 'missing' }).Text | Should -Be 'not found'
        }
    }

    It 'reads the repair-source policy and WSUS without keeping the policy path' {
        $reg = New-FakeRegistry @{ $script:Servicing = @{ LocalSourcePath = '\\server\share\sources'; UseWindowsUpdate = 2 }; $script:Au = @{ UseWUServer = 1 } }
        InModuleScope AutoFixer -Parameters @{ R = $reg } {
            param($R)
            $p = Get-AfRepairSourcePolicy -ReadRegistry $R
            $p.LocalSource | Should -BeTrue
            $p.NeverWindowsUpdate | Should -BeTrue
            $p.Wsus | Should -BeTrue
            $p.DirectWindowsUpdate | Should -BeFalse
            ($p | ConvertTo-Json) | Should -Not -Match 'server'
        }
    }

    It 'treats missing policy keys as "no policy"' {
        InModuleScope AutoFixer -Parameters @{ R = (New-FakeRegistry @{}) } {
            param($R)
            $p = Get-AfRepairSourcePolicy -ReadRegistry $R
            $p.LocalSource, $p.NeverWindowsUpdate, $p.Wsus | Should -Be @($false, $false, $false)
        }
    }

    It 'finds the last 0x800F0 error in dism.log' {
        $log = Join-Path $TestDrive 'dism.log'
        Set-Content -LiteralPath $log -Value @(
            '2026-10-28 19:01:02, Error                 DISM   DISM Package Manager: PID=1 Failed. - CPackageManagerCLIHandler::Private_ProcessCommand(hr:0x800f0906)',
            '2026-10-28 20:12:01, Info                  DISM   Something else',
            '2026-10-28 20:12:44, Error                 DISM   DISM Package Manager: PID=2 Failed finalizing changes. - (hr:0x800f081f)',
            '2026-10-28 20:12:45, Info                  DISM   Exit code 0x0')
        InModuleScope AutoFixer -Parameters @{ L = $log } {
            param($L)
            $last = Get-AfDismLogLastError -Path $L
            $last.Code | Should -Be '0x800F081F'
            $last.When | Should -Be '2026-10-28 20:12'
            Get-AfDismLogLastError -Path (Join-Path $TestDrive 'none.log') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Verdict' {
    BeforeAll {
        $script:Os = [pscustomobject]@{ Build = 26100; Ubr = 4652; Edition = 'Professional' }
        $script:Same = [pscustomobject]@{ Build = 26100 }
        $script:NoPolicy = [pscustomobject]@{ LocalSource = $false; NeverWindowsUpdate = $false; DirectWindowsUpdate = $false; Wsus = $false }
    }

    It 'says OK when DISM matches Windows and nothing failed' {
        InModuleScope AutoFixer -Parameters @{ Os = $script:Os; D = $script:Same; P = $script:NoPolicy } {
            param($Os, $D, $P)
            $f = @(Get-AfDismSourceVerdict -Os $Os -Dism $D -Policy $P -Online $true)
            $f.Count | Should -Be 1
            $f[0].Level | Should -Be 'OK'
        }
    }

    It 'warns when DISM and Windows builds differ' {
        InModuleScope AutoFixer -Parameters @{ Os = $script:Os; P = $script:NoPolicy } {
            param($Os, $P)
            $f = @(Get-AfDismSourceVerdict -Os $Os -Dism ([pscustomobject]@{ Build = 22621 }) -Policy $P -Online $true)
            $f[0].Level | Should -Be 'WARN'
            $f[0].Text | Should -Be 'DISM is build 22621 but Windows is build 26100.'
            $f[0].Next | Should -Match 'in-place repair install'
        }
    }

    It 'accepts DISM 26100 on 25H2 and 26H2 builds, which keep the 24H2 DISM' {
        InModuleScope AutoFixer -Parameters @{ P = $script:NoPolicy } {
            param($P)
            foreach ($build in 26200, 26300) {
                $f = @(Get-AfDismSourceVerdict -Os ([pscustomobject]@{ Build = $build; Ubr = 7000 }) -Dism ([pscustomobject]@{ Build = 26100 }) -Policy $P -Online $true)
                $f[0].Level | Should -Be 'OK' -Because $build
            }
            (Get-AfDismSourceVerdict -Os ([pscustomobject]@{ Build = 19045 }) -Dism ([pscustomobject]@{ Build = 19041 }) -Policy $P -Online $true)[0].Level | Should -Be 'OK'
        }
    }

    It 'answers 0x800F0915 with: go online, restart, run R alone, then "Fix problems using Windows Update"' {
        InModuleScope AutoFixer -Parameters @{ P = $script:NoPolicy } {
            param($P)
            $os = [pscustomobject]@{ Build = 26300; Ubr = 7674; Edition = 'Professional'; Insider = 'Dev' }
            $f = @(Get-AfDismSourceVerdict -Os $os -Dism ([pscustomobject]@{ Build = 26100 }) -Policy $P -LastCode '0x800F0915' -Online $true)
            ($f | Where-Object Text -Match 'Insider').Level | Should -Be 'NOTE'
            ($f | Where-Object Text -Match '^0x800F0915').Next | Should -Match 'Fix problems using Windows Update'
            ($f | Where-Object Text -Match '^0x800F0915').Next | Should -Match 'run R on its own'
            $off = @(Get-AfDismSourceVerdict -Os $os -Dism ([pscustomobject]@{ Build = 26100 }) -Policy $P -LastCode '0x800F0915' -Online $false)
            ($off | Where-Object Text -Match '^0x800F0915').Next | Should -Match 'Go online when a step needs it'
        }
    }

    It 'sends 0x800F081F to Windows Update while the Online switch is off' {
        InModuleScope AutoFixer -Parameters @{ Os = $script:Os; D = $script:Same; P = $script:NoPolicy } {
            param($Os, $D, $P)
            $f = @(Get-AfDismSourceVerdict -Os $Os -Dism $D -Policy $P -LastCode '0x800F081F' -Online $false)
            ($f | Where-Object Text -Match '^0x800F081F').Next | Should -Match 'Go online when a step needs it'
            ($f | Where-Object Level -EQ 'NOTE').Text | Should -Match 'Online switch is off'
        }
    }

    It 'blames the policy for 0x800F081F when WSUS keeps DISM away from Windows Update' {
        $policy = [pscustomobject]@{ LocalSource = $false; NeverWindowsUpdate = $false; DirectWindowsUpdate = $false; Wsus = $true }
        InModuleScope AutoFixer -Parameters @{ Os = $script:Os; D = $script:Same; P = $policy } {
            param($Os, $D, $P)
            $f = @(Get-AfDismSourceVerdict -Os $Os -Dism $D -Policy $P -LastCode '0x800F081F' -Online $true)
            ($f | Where-Object Text -Match '^0x800F081F').Next | Should -Match 'policy keeps DISM away'
            ($f | Where-Object Text -Match 'WSUS').Level | Should -Be 'NOTE'
        }
    }

    It 'gives a next step for every code it knows' {
        InModuleScope AutoFixer -Parameters @{ Os = $script:Os; D = $script:Same; P = $script:NoPolicy } {
            param($Os, $D, $P)
            foreach ($code in $script:AfDismCodes.Keys) {
                $f = @(Get-AfDismSourceVerdict -Os $Os -Dism $D -Policy $P -LastCode $code -Online $true) | Where-Object Text -Match ('^' + $code)
                $f.Next | Should -Not -BeNullOrEmpty -Because $code
            }
        }
    }

    It 'adds nothing for a code it does not know' {
        InModuleScope AutoFixer -Parameters @{ Os = $script:Os; D = $script:Same; P = $script:NoPolicy } {
            param($Os, $D, $P)
            @(Get-AfDismSourceVerdict -Os $Os -Dism $D -Policy $P -LastCode '0x80070005' -Online $true).Count | Should -Be 1
        }
    }

    It 'formats the check without the policy path' {
        $reg = New-FakeRegistry @{ $script:Cv = $script:Win11; $script:Servicing = @{ LocalSourcePath = '\\server\share' } }
        InModuleScope AutoFixer -Parameters @{ R = $reg; L = (Join-Path $TestDrive 'none.log') } {
            param($R, $L)
            $check = Get-AfDismSourceCheck -Online $true -ReadRegistry $R -LogPath $L
            $text = (Format-AfDismSourceCheck -Check $check) -join "`n"
            $text | Should -Match 'Windows   : Windows 11 24H2, build 26100.4652, Professional'
            $text | Should -Match 'policy repair path set'
            $text | Should -Not -Match 'server'
        }
    }
}

Describe 'Windows image as a repair source' {
    It 'reads every index with its build, edition and languages' {
        InModuleScope AutoFixer -Parameters @{ List = $script:WimList; HomeInfo = (Get-WimDetail 1 'Home'); Pro = (Get-WimDetail 6 'Professional') } {
            param($List, $HomeInfo, $Pro)
            $run = { param([string[]] $Arguments) if ($Arguments -contains '/Index:1') { $HomeInfo } elseif ($Arguments -contains '/Index:6') { $Pro } else { $List } }.GetNewClosure()
            $images = @(Get-AfWimInfo -Path 'E:\sources\install.wim' -RunDism $run)
            $images.Count | Should -Be 2
            $images[1].Index | Should -Be 6
            $images[1].Edition | Should -Be 'Professional'
            $images[1].Build | Should -Be 26100
            $images[1].Ubr | Should -Be 1742
            $images[1].Languages | Should -Be @('en-US')
        }
    }

    It 'says MATCH, OLDER, OTHERBUILD or NOEDITION' {
        InModuleScope AutoFixer {
            $os = [pscustomobject]@{ Build = 26100; Ubr = 4652; Edition = 'Professional' }
            $img = { param($Edition, $Build, $Ubr) [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Edition = $Edition; Build = $Build; Ubr = $Ubr; Languages = @('en-US') } }
            (Compare-AfWimToOs -Images @(& $img 'Professional' 26100 4652) -Os $os).Verdict | Should -Be 'MATCH'
            (Compare-AfWimToOs -Images @(& $img 'Professional' 26100 1742) -Os $os).Verdict | Should -Be 'OLDER'
            (Compare-AfWimToOs -Images @(& $img 'Professional' 22631 4000) -Os $os).Verdict | Should -Be 'OTHERBUILD'
            $none = Compare-AfWimToOs -Images @(& $img 'Core' 26100 4652) -Os $os
            $none.Verdict | Should -Be 'NOEDITION'
            $none.Text | Should -Match 'it has: Core'
        }
    }

    It 'builds the /Source value and refuses paths with spaces' {
        InModuleScope AutoFixer {
            Get-AfWimSourceArgument -Path 'E:\sources\install.wim' -Index 6 | Should -Be 'wim:E:\sources\install.wim:6'
            Get-AfWimSourceArgument -Path 'E:\sources\install.esd' -Index 6 | Should -Be 'esd:E:\sources\install.esd:6'
            Get-AfWimSourceArgument -Path 'D:\My ISOs\install.wim' -Index 6 | Should -BeNullOrEmpty
        }
    }

    It 'finds install.wim or install.esd from a folder, and nothing elsewhere' {
        $sources = Join-Path $TestDrive 'iso\sources'
        $null = New-Item -ItemType Directory -Path $sources -Force
        Set-Content -LiteralPath (Join-Path $sources 'install.esd') -Value 'x'
        InModuleScope AutoFixer -Parameters @{ S = $sources; Empty = $TestDrive } {
            param($S, $Empty)
            Resolve-AfWimPath -Path $S | Should -Be (Join-Path $S 'install.esd')
            Resolve-AfWimPath -Path ('"{0}"' -f (Join-Path $S 'install.esd')) | Should -Be (Join-Path $S 'install.esd')
            Resolve-AfWimPath -Path $Empty | Should -BeNullOrEmpty
            Resolve-AfWimPath -Path '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'DISM version and source screen' {
    BeforeAll {
        $script:Check = {
            param($Online)
            [pscustomobject]@{
                Os       = [pscustomobject]@{ Build = 26100; Ubr = 4652; Edition = 'Professional'; Text = 'Windows 11 24H2, build 26100.4652, Professional' }
                Dism     = [pscustomobject]@{ Path = 'C:\Windows\System32\dism.exe'; Build = 26100; Text = '10.0.26100.4652' }
                Policy   = [pscustomobject]@{ LocalSource = $false; NeverWindowsUpdate = $false; DirectWindowsUpdate = $false; Wsus = $false }
                Last     = $null
                Findings = @([pscustomobject]@{ Level = 'OK'; Text = 'DISM 26100 is the right one for Windows build 26100.'; Next = $null })
            }
        }
        $script:Wim = { param($Path) [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Edition = 'Professional'; Build = 26100; Ubr = 4652; Languages = @('en-US') } }
        $script:Resolve = { param($Path) 'E:\sources\install.wim' }
    }

    It 'only shows the check in Standard mode and asks nothing' {
        $p = @{ Check = $script:Check; Keys = (New-KeyReader @()) }
        InModuleScope AutoFixer -Parameters $p {
            param($Check, $Keys)
            $s = [pscustomobject]@{ Mode = 'Standard'; Online = $false }
            Invoke-AfDismSourceScreen -Settings $s -ReadKey $Keys -Check $Check 6>$null | Should -BeNullOrEmpty
        }
    }

    It 'returns a /Source value in Technician mode after two Yes answers' {
        $p = @{ Check = $script:Check; Wim = $script:Wim; Resolve = $script:Resolve; Keys = (New-KeyReader 'y', 'y') }
        InModuleScope AutoFixer -Parameters $p {
            param($Check, $Wim, $Resolve, $Keys)
            $s = [pscustomobject]@{ Mode = 'Technician'; Online = $false }
            Invoke-AfDismSourceScreen -Settings $s -ReadKey $Keys -ReadLine { 'E:' } -Check $Check -WimInfo $Wim -ResolvePath $Resolve 6>$null |
                Should -Be 'wim:E:\sources\install.wim:6'
        }
    }

    It 'returns nothing when the image is another build' {
        $other = { param($Path) [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro'; Edition = 'Professional'; Build = 22631; Ubr = 4000; Languages = @('en-US') } }
        $p = @{ Check = $script:Check; Wim = $other; Resolve = $script:Resolve; Keys = (New-KeyReader 'y') }
        InModuleScope AutoFixer -Parameters $p {
            param($Check, $Wim, $Resolve, $Keys)
            $s = [pscustomobject]@{ Mode = 'Technician'; Online = $false }
            Invoke-AfDismSourceScreen -Settings $s -ReadKey $Keys -ReadLine { 'E:' } -Check $Check -WimInfo $Wim -ResolvePath $Resolve 6>$null | Should -BeNullOrEmpty
        }
    }

    It 'reads this real PC without changing it' -Skip:(-not $script:OnWindows) {
        InModuleScope AutoFixer {
            $check = Get-AfDismSourceCheck -Online $false
            $check.Os.Build | Should -BeGreaterThan 10000
            $check.Dism.Build | Should -BeGreaterThan 10000
            @(Format-AfDismSourceCheck -Check $check).Count | Should -BeGreaterThan 2
        }
    }
}
