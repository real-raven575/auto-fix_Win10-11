# One folder per PC, and the PC id and UTC time in every file name (Core/LogFiles.ps1).
# pc-id.txt is pointed at the test drive, so the real ProgramData is never touched here.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    InModuleScope AutoFixer -Parameters @{ IdPath = (Join-Path $TestDrive 'ProgramData\AutoFixer\pc-id.txt') } {
        param($IdPath)
        $script:AfPcIdPath = $IdPath
        $script:AfPcId = $null
    }
    $script:IdPath = Join-Path $TestDrive 'ProgramData\AutoFixer\pc-id.txt'
}

Describe 'The PC id' {
    It 'is 6 random characters with no look-alikes (0, O, 1, I)' {
        InModuleScope AutoFixer {
            $ids = @(1..50 | ForEach-Object { New-AfPcIdText })
            foreach ($id in $ids) { $id | Should -MatchExactly '^[A-HJ-NP-Z2-9]{6}$' }
            @($ids | Select-Object -Unique).Count | Should -BeGreaterThan 45
        }
    }

    It 'is made once, saved in pc-id.txt and read back the same next time' {
        $first = InModuleScope AutoFixer { Get-AfPcId }
        $script:IdPath | Should -Exist
        (Get-Content $script:IdPath -Raw).Trim() | Should -BeExactly $first
        InModuleScope AutoFixer { $script:AfPcId = $null }
        InModuleScope AutoFixer { Get-AfPcId } | Should -BeExactly $first
    }

    It 'is not made from the PC or user name' {
        $id = InModuleScope AutoFixer { Get-AfPcId }
        foreach ($name in @($env:COMPUTERNAME, $env:USERNAME, [Environment]::MachineName) | Where-Object { $_ }) {
            $id | Should -Not -Be $name
        }
        InModuleScope AutoFixer -Parameters @{ P = (Join-Path $TestDrive 'other\pc-id.txt') } { param($P) Get-AfPcId -Path $P } | Should -Not -BeExactly $id
    }

    It 'replaces a damaged pc-id.txt with a new id' {
        $path = Join-Path $TestDrive 'damaged\pc-id.txt'
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        Set-Content -Path $path -Value 'not an id'
        $id = InModuleScope AutoFixer -Parameters @{ P = $path } { param($P) Get-AfPcId -Path $P }
        $id | Should -MatchExactly '^[A-HJ-NP-Z2-9]{6}$'
        (Get-Content $path -Raw).Trim() | Should -BeExactly $id
    }

    It 'still gives an id when pc-id.txt cannot be written' {
        $blocker = Join-Path $TestDrive 'blocker'
        Set-Content -Path $blocker -Value 'a file where the folder should be'
        $id = InModuleScope AutoFixer -Parameters @{ P = (Join-Path $blocker 'pc-id.txt') } { param($P) Get-AfPcId -Path $P }
        $id | Should -MatchExactly '^[A-HJ-NP-Z2-9]{6}$'
    }
}

Describe 'Log file names' {
    It 'stamps UTC time with a Z' {
        $local = [datetime]::SpecifyKind([datetime]'2026-10-29T23:35:47', 'Utc').ToLocalTime()
        InModuleScope AutoFixer -Parameters @{ T = $local } { param($T) Get-AfLogStamp -Time $T } | Should -BeExactly '20261029-233547Z'
    }

    It 'puts every file in PC-<id> as AF-<id>-<time>-<kind>' {
        $root = Join-Path $TestDrive 'Runs'
        $id = InModuleScope AutoFixer { Get-AfPcId }
        $stem = InModuleScope AutoFixer -Parameters @{ R = $root } { param($R) New-AfLogStem -OutputRoot $R -Kind 'repair' -Extension 'log' -Stamp '20261029-234210Z' }
        $stem | Should -BeExactly (Join-Path (Join-Path $root "PC-$id") "AF-$id-20261029-234210Z-repair")
        Join-Path $root "PC-$id" | Should -Exist
    }

    It 'adds -2, -3 after the time instead of overwriting a file' {
        $root = Join-Path $TestDrive 'Clash'
        $make = { param($Kind, $Ext) InModuleScope AutoFixer -Parameters @{ R = $root; K = $Kind; E = $Ext } { param($R, $K, $E) New-AfLogStem -OutputRoot $R -Kind $K -Extension $E -Stamp '20261030-001502Z' } }
        $one = & $make 'network' @('log'); Set-Content "$one.log" 'first'
        $two = & $make 'network' @('log'); Set-Content "$two.log" 'second'
        $three = & $make 'network' @('log')
        $two | Should -BeLike '*-20261030-001502Z-2-network'
        $three | Should -BeLike '*-20261030-001502Z-3-network'
        Get-Content "$one.log" | Should -Be 'first'

        # A scan writes .json and .html together; either one existing moves both on.
        $scan = & $make 'scan' @('json', 'html'); Set-Content "$scan.html" 'x'
        & $make 'scan' @('json', 'html') | Should -BeLike '*-20261030-001502Z-2-scan'
    }
}

Describe 'repair-history.csv' {
    It 'reads the older file in Runs until this PC has one, then copies it in once and leaves the old one' {
        $root = Join-Path $TestDrive 'History'
        $null = New-Item -ItemType Directory -Path $root -Force
        $old = Join-Path $root 'repair-history.csv'
        Set-Content -Path $old -Value 'Step,Seconds,ExitCode,Date'
        $id = InModuleScope AutoFixer { Get-AfPcId }

        InModuleScope AutoFixer -Parameters @{ R = $root } { param($R) Get-AfHistoryPath -OutputRoot $R } | Should -BeExactly $old
        Join-Path $root "PC-$id" | Should -Not -Exist

        $new = InModuleScope AutoFixer -Parameters @{ R = $root } { param($R) Get-AfHistoryPath -OutputRoot $R -Prepare }
        $new | Should -BeExactly (Join-Path (Join-Path $root "PC-$id") 'repair-history.csv')
        Get-Content $new | Should -Be 'Step,Seconds,ExitCode,Date'
        $old | Should -Exist
        InModuleScope AutoFixer -Parameters @{ R = $root } { param($R) Get-AfHistoryPath -OutputRoot $R } | Should -BeExactly $new
    }
}
