# Disk space (Clean up menu): used and free on each fixed drive. Read-only, so nothing
# real is touched here: the drive lists are fakes, and the log goes to TestDrive.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    # C: 476 GB with 9 GB free (low), D: 2 TB with 1.5 TB free, plus drives that must be left out.
    $script:Volumes = @(
        [pscustomobject]@{ DriveLetter = 'c'; DriveType = 'Fixed'; FileSystem = 'NTFS'; Size = 476GB; SizeRemaining = 9GB; FileSystemLabel = 'TestLabelName' }
        [pscustomobject]@{ DriveLetter = 'D'; DriveType = 'Fixed'; FileSystem = 'exFAT'; Size = 2TB; SizeRemaining = 1.5TB }
        [pscustomobject]@{ DriveLetter = 'E'; DriveType = 'Removable'; FileSystem = 'FAT32'; Size = 32GB; SizeRemaining = 1GB }
        [pscustomobject]@{ DriveLetter = ''; DriveType = 'Fixed'; FileSystem = 'NTFS'; Size = 500MB; SizeRemaining = 100MB }
        [pscustomobject]@{ DriveLetter = 'F'; DriveType = 'Fixed'; FileSystem = ''; Size = 0; SizeRemaining = 0 }
    )
}

Describe 'Test-AfLowSpace' {
    It 'is low under 10% free, or under 15 GB free on the Windows drive' {
        InModuleScope AutoFixer {
            Test-AfLowSpace -Size 100GB -Free 9GB | Should -BeTrue
            Test-AfLowSpace -Size 100GB -Free 11GB | Should -BeFalse
            Test-AfLowSpace -Size 100GB -Free 14GB -IsSystem | Should -BeTrue
            Test-AfLowSpace -Size 100GB -Free 14GB | Should -BeFalse
            Test-AfLowSpace -Size 0 -Free 0 | Should -BeFalse
        }
    }
}

Describe 'Get-AfDiskSpace' {
    It 'lists fixed drives with a letter, with used = size - free' {
        $d = InModuleScope AutoFixer -Parameters @{ V = $script:Volumes } {
            param($V)
            Get-AfDiskSpace -GetVolumes { $V }.GetNewClosure() -GetMedia { param($L) if ($L -eq 'C') { 'SSD' } else { 'HDD' } } -SystemDrive 'C:'
        }
        @($d).Count | Should -Be 2
        $d[0].Letter | Should -Be 'C'
        $d[0].Media | Should -Be 'SSD'
        $d[0].Used | Should -Be (476GB - 9GB)
        $d[0].Free | Should -Be 9GB
        $d[0].IsSystem | Should -BeTrue
        $d[0].Low | Should -BeTrue
        $d[1].Letter | Should -Be 'D'
        $d[1].FileSystem | Should -Be 'exFAT'
        $d[1].UsedPercent | Should -Be 25
        $d[1].IsSystem | Should -BeFalse
        $d[1].Low | Should -BeFalse
    }

    It 'never carries the volume label' {
        $d = InModuleScope AutoFixer -Parameters @{ V = $script:Volumes } {
            param($V)
            Get-AfDiskSpace -GetVolumes { $V }.GetNewClosure() -GetMedia { 'SSD' } -SystemDrive 'C:'
        }
        ($d | ConvertTo-Json) | Should -Not -Match 'TestLabelName'
    }

    It 'skips the drive type check with -SkipMedia' {
        $d = InModuleScope AutoFixer -Parameters @{ V = $script:Volumes } {
            param($V)
            Get-AfDiskSpace -GetVolumes { $V }.GetNewClosure() -GetMedia { throw 'media must not be read' } -SystemDrive 'C:' -SkipMedia
        }
        @($d).Count | Should -Be 2
        $d[0].Media | Should -Be ''
    }

    It 'uses Windows'' drive list when Get-Volume fails' {
        $drives = @(
            [pscustomobject]@{ Name = 'C:\'; DriveType = 'Fixed'; IsReady = $true; DriveFormat = 'NTFS'; TotalSize = 100GB; TotalFreeSpace = 40GB }
            [pscustomobject]@{ Name = 'Z:\'; DriveType = 'Network'; IsReady = $true; DriveFormat = 'NTFS'; TotalSize = 1TB; TotalFreeSpace = 1GB }
            [pscustomobject]@{ Name = 'G:\'; DriveType = 'Fixed'; IsReady = $false; DriveFormat = ''; TotalSize = 0; TotalFreeSpace = 0 }
        )
        $d = InModuleScope AutoFixer -Parameters @{ D = $drives } {
            param($D)
            Get-AfDiskSpace -GetVolumes { throw 'Get-Volume is not available' } -GetDrives { $D }.GetNewClosure() -SkipMedia -SystemDrive 'C:'
        }
        @($d).Count | Should -Be 1
        $d[0].Letter | Should -Be 'C'
        $d[0].Used | Should -Be 60GB
        $d[0].UsedPercent | Should -Be 60
    }

    It 'never reports more free than the size, or less than zero' {
        $v = @([pscustomobject]@{ DriveLetter = 'C'; DriveType = 'Fixed'; FileSystem = 'NTFS'; Size = 10GB; SizeRemaining = 12GB })
        $d = InModuleScope AutoFixer -Parameters @{ V = $v } {
            param($V)
            Get-AfDiskSpace -GetVolumes { $V }.GetNewClosure() -SkipMedia -SystemDrive 'C:'
        }
        $d[0].Free | Should -Be 10GB
        $d[0].Used | Should -Be 0
    }
}

Describe 'Disk space text' {
    It 'shows exact bytes the same way on every PC' {
        InModuleScope AutoFixer {
            Format-AfExactBytes 381012345600 | Should -Be '381,012,345,600'
            Format-AfExactBytes 0 | Should -Be '0'
            Format-AfExactBytes $null | Should -Be 'not known'
        }
    }

    It 'never rounds a nearly full or nearly empty drive to 100% or 0%' {
        InModuleScope AutoFixer {
            Format-AfPercent 99.6 | Should -Be '99.6%'
            Format-AfPercent 0.4 | Should -Be '0.4%'
            Format-AfPercent 80.04 | Should -Be '80%'
            Format-AfPercent 100 | Should -Be '100%'
            Format-AfUsageBar 80 | Should -Be '[########--]'
            Format-AfUsageBar 0 | Should -Be '[----------]'
            Format-AfUsageBar 150 | Should -Be '[##########]'
        }
    }

    It 'lists each drive, a total, exact bytes and a warning for a low drive' {
        $lines = InModuleScope AutoFixer -Parameters @{ V = $script:Volumes } {
            param($V)
            $d = Get-AfDiskSpace -GetVolumes { $V }.GetNewClosure() -GetMedia { 'SSD' } -SystemDrive 'C:'
            Get-AfDiskSpaceText -Drives $d
        }
        $text = ($lines | ForEach-Object Text) -join "`n"
        $text | Should -Match 'C:\*\s+SSD'
        $text | Should -Match 'Total'
        $text | Should -Match ([regex]::Escape((476GB - 9GB).ToString('N0', [Globalization.CultureInfo]::InvariantCulture)))
        $text | Should -Match 'WARNING  C: is low on space'
        $text | Should -Not -Match 'WARNING  D:'
        @($lines | Where-Object Color -eq 'Warning').Count | Should -Be 1
    }

    It 'says so when there is no drive' {
        $lines = InModuleScope AutoFixer { Get-AfDiskSpaceText -Drives @() }
        $lines[0].Text | Should -Match 'No fixed drives'
    }

    It 'gives the Clean up menu one line for the Windows drive' {
        InModuleScope AutoFixer {
            $c = [pscustomobject]@{ Letter = 'C'; IsSystem = $true; Size = 100GB; Free = 40GB; UsedPercent = 60; Low = $false }
            Format-AfDiskSpaceLine -Drives @($c) | Should -Be 'Windows drive C: 40.0 GB free of 100 GB (60% used).'
            $c.Low = $true
            Format-AfDiskSpaceLine -Drives @($c) | Should -Match 'Low on space\.$'
            Format-AfDiskSpaceLine -Drives @() | Should -Be 'Windows drive: size not known.'
        }
    }
}

Describe 'Show-AfDiskSpace' {
    It 'prints the drives and writes the same lines to a log' {
        $root = Join-Path $TestDrive 'Runs'
        $d = InModuleScope AutoFixer -Parameters @{ V = $script:Volumes; Root = $root } {
            param($V, $Root)
            # Read first: a closure made with GetNewClosure() runs outside the module and cannot see its functions.
            $drives = Get-AfDiskSpace -GetVolumes { $V }.GetNewClosure() -GetMedia { 'HDD' } -SystemDrive 'C:'
            Show-AfDiskSpace -OutputRoot $Root -GetSpace { $drives }.GetNewClosure() 6>$null
        }
        @($d).Count | Should -Be 2
        $log = @(Get-ChildItem -Path $root -Recurse -Filter '*-diskspace.log')
        $log.Count | Should -Be 1
        $content = Get-Content -LiteralPath $log[0].FullName -Raw
        $content | Should -Match 'Task      : Disk space'
        $content | Should -Match 'WARNING  C: is low on space'
        $content | Should -Not -Match 'TestLabelName'
    }

    It 'reports a failure to read the drives and returns nothing' {
        $d = InModuleScope AutoFixer -Parameters @{ Root = (Join-Path $TestDrive 'Runs2') } {
            param($Root)
            Show-AfDiskSpace -OutputRoot $Root -GetSpace { throw 'no access' } 6>$null
        }
        @($d).Count | Should -Be 0
    }
}

Describe 'Format-AfSpaceChange' {
    It 'shows used and free before and after a cleanup, and the change' {
        $lines = InModuleScope AutoFixer { Format-AfSpaceChange -Size 100GB -FreeBefore 10GB -FreeAfter 12.5GB }
        $lines[0] | Should -Be 'Windows drive, size 100 GB:'
        $lines[2] | Should -Match '^Before\s+90\.0 GB\s+10\.0 GB$'
        $lines[3] | Should -Match '^After\s+87\.5 GB\s+12\.5 GB$'
        $lines[4] | Should -Match '^Change\s+-2\.5 GB\s+\+2\.5 GB$'
    }

    It 'shows a drop in free space as a drop, and unknown sizes as not known' {
        InModuleScope AutoFixer {
            (Format-AfSpaceChange -Size 100GB -FreeBefore 10GB -FreeAfter 9GB)[4] | Should -Match '^Change\s+\+1\.0 GB\s+-1\.0 GB$'
            $lines = Format-AfSpaceChange -Size $null -FreeBefore 10GB -FreeAfter $null
            $lines[0] | Should -Be 'Windows drive, size not known:'
            $lines[3] | Should -Match 'not known\s+not known$'
            @($lines).Count | Should -Be 4
        }
    }
}
