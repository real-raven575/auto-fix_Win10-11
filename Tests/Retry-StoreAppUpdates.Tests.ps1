# Retry-StoreAppUpdates.ps1: retries Store app updates that failed with 0x80073D02
# because the app was open (SIG-WU-002, ADVICE-CLOSE-APP-RETRY). raven575 2026-11-10:
# force close is allowed, but only after a warning. Dot-sourcing loads the
# functions and runs no step, so nothing here touches the PC.
BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\Tools\Retry-StoreAppUpdates.ps1'
    . $script:Script -Plain

    function New-TestUpdateEvent([int] $Id, [int] $DaysAgo, [string] $Message) {
        [pscustomobject]@{ Id = $Id; TimeCreated = [datetime]'2026-11-10T12:00:00' - [timespan]::FromDays($DaysAgo); Message = $Message }
    }
    $script:Fail = 'Installation Failure: Windows failed to install the following update with error 0x80073D02: {0}.'
    $script:Ok = 'Installation Successful: Windows successfully installed the following update: {0}'
}

Describe 'Retry Store app updates: file' {
    It 'is pure ASCII, so Windows PowerShell 5.1 reads it' {
        @([System.IO.File]::ReadAllBytes($script:Script) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'turns -WhatIf off inside every read-only step (BEASTLY 2026-11-10: it blanked the app list)' {
        $text = Get-Content -LiteralPath $script:Script -Raw
        $readOnly = [regex]::Matches($text, 'Changes = \$null; Run = \{\r?\n\s*(?<first>[^\r\n]*)')
        $readOnly.Count | Should -Be 3
        foreach ($m in $readOnly) { $m.Groups['first'].Value | Should -Match '^\$WhatIfPreference = \$false' }
    }

    It 'never asks Windows for every user''s apps without administrator rights (Access is denied)' {
        $body = (Get-Command Get-StoreInstalledApp).Definition
        $body | Should -Match 'if \(Test-HerdAdmin\)'
        $body | Should -Match 'Get-AppxPackage -Name \$Name'
        (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match 'Get-AppxPackage -AllUsers -Name \$a\.Name'
    }

    It 'loads its functions without running any step when dot-sourced' {
        Get-Command Get-StoreStuckApp -CommandType Function | Should -Not -BeNullOrEmpty
        Get-Variable -Name Steps -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Retry Store app updates: reading the events' {
    It 'takes the app name from the event text, without the Store id in front' {
        ConvertTo-StoreAppName -Message ($script:Fail -f '9NBLGGH4R32N-Microsoft.GamingApp') | Should -Be 'Microsoft.GamingApp'
        ConvertTo-StoreAppName -Message ($script:Fail -f 'Microsoft.PowerShell') | Should -Be 'Microsoft.PowerShell'
        ConvertTo-StoreAppName -Message ($script:Ok -f '9WZDNCRFJ3PT-Microsoft.ZuneMusic') | Should -Be 'Microsoft.ZuneMusic'
    }

    It 'returns nothing for text without an app name' {
        ConvertTo-StoreAppName -Message '' | Should -Be ''
        ConvertTo-StoreAppName -Message 'Installation Failure: Windows failed: Security Update (KB5031356) for Windows' | Should -Be ''
    }

    It 'lists an app whose update failed with 0x80073D02 and did not install since' {
        $events = @(
            New-TestUpdateEvent 20 6 ($script:Fail -f 'Microsoft.GamingApp')
            New-TestUpdateEvent 20 5 ($script:Fail -f 'Microsoft.GamingApp')
        )
        $apps = @(Get-StoreStuckApp -Events $events)
        $apps.Count | Should -Be 1
        $apps[0].Name | Should -Be 'Microsoft.GamingApp'
        $apps[0].Failures | Should -Be 2
    }

    It 'drops an app that installed after its last failure (Windows retried it already)' {
        $events = @(
            New-TestUpdateEvent 20 6 ($script:Fail -f 'Microsoft.GamingApp')
            New-TestUpdateEvent 19 2 ($script:Ok -f '9NBLGGH4R32N-Microsoft.GamingApp')
            New-TestUpdateEvent 19 6 ($script:Ok -f 'Microsoft.Paint')
            New-TestUpdateEvent 20 1 ($script:Fail -f 'Microsoft.Paint')
        )
        @(Get-StoreStuckApp -Events $events | ForEach-Object Name) | Should -Be @('Microsoft.Paint')
    }

    It 'ignores failures with other error codes' {
        $other = 'Installation Failure: Windows failed to install the following update with error 0x80070005: Microsoft.Paint.'
        @(Get-StoreStuckApp -Events @(New-TestUpdateEvent 20 1 $other)).Count | Should -Be 0
    }
}

Describe 'Retry Store app updates: what may be closed' {
    It 'never touches Windows system apps or frameworks' {
        Test-StoreSystemPackage -Package ([pscustomobject]@{ SignatureKind = 'System'; IsFramework = $false; NonRemovable = $false }) | Should -BeTrue
        Test-StoreSystemPackage -Package ([pscustomobject]@{ SignatureKind = 'Store'; IsFramework = $true; NonRemovable = $false }) | Should -BeTrue
        Test-StoreSystemPackage -Package ([pscustomobject]@{ SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $true }) | Should -BeTrue
        Test-StoreSystemPackage -Package ([pscustomobject]@{ SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $false }) | Should -BeFalse
    }

    It 'protects this script and every parent, for example Windows Terminal' {
        $procs = @(
            [pscustomobject]@{ ProcessId = 40; ParentProcessId = 30 }   # powershell.exe (this script)
            [pscustomobject]@{ ProcessId = 30; ParentProcessId = 20 }   # WindowsTerminal.exe
            [pscustomobject]@{ ProcessId = 20; ParentProcessId = 10 }   # explorer.exe
            [pscustomobject]@{ ProcessId = 50; ParentProcessId = 20 }   # another app
        )
        $ids = Get-StoreProtectedProcessId -SelfId 40 -Processes $procs
        $ids | Should -Contain 40
        $ids | Should -Contain 30
        $ids | Should -Not -Contain 50
    }

    It 'stops on a parent loop instead of hanging' {
        $procs = @([pscustomobject]@{ ProcessId = 1; ParentProcessId = 2 }, [pscustomobject]@{ ProcessId = 2; ParentProcessId = 1 })
        @(Get-StoreProtectedProcessId -SelfId 1 -Processes $procs).Count | Should -Be 2
    }

    It 'finds processes started from the app folder only, minus protected ones' {
        $root = 'C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.21_x64__8wekyb3d8bbwe'
        $procs = @(
            [pscustomobject]@{ ProcessId = 30; ExecutablePath = "$root\WindowsTerminal.exe" }
            [pscustomobject]@{ ProcessId = 31; ExecutablePath = "$root\OpenConsole.exe" }
            [pscustomobject]@{ ProcessId = 32; ExecutablePath = "$root-other\x.exe" }
            [pscustomobject]@{ ProcessId = 33; ExecutablePath = $null }
        )
        @(Select-StoreAppProcess -InstallLocation $root -Processes $procs | ForEach-Object ProcessId) | Should -Be @(30, 31)
        @(Select-StoreAppProcess -InstallLocation $root -Processes $procs -ProtectedIds @(30) | ForEach-Object ProcessId) | Should -Be @(31)
        @(Select-StoreAppProcess -InstallLocation '' -Processes $procs).Count | Should -Be 0
    }
}

Describe 'Retry Store app updates: force close only after a warning' {
    It 'never closes an app that was skipped, such as the one this script runs in (BEASTLY 2026-11-10)' {
        $apps = @(
            [pscustomobject]@{ Name = 'Microsoft.PowerShell'; Status = 'skipped: this script runs inside it'; Processes = @([pscustomobject]@{ ProcessId = 7 }) }
            [pscustomobject]@{ Name = 'Microsoft.Paint'; Status = 'still waiting'; Processes = @([pscustomobject]@{ ProcessId = 8 }) }
            [pscustomobject]@{ Name = 'Microsoft.GamingApp'; Status = 'still waiting'; Processes = @() }
        )
        @(Select-StoreAppToClose -Apps $apps | ForEach-Object Name) | Should -Be @('Microsoft.Paint')
    }

    It 'asks when someone is at the keyboard' {
        Get-StoreCloseAction -Background $false -Go '' -CanWarn $false | Should -Be 'Ask'
    }

    It 'warns, then force-closes, in Background Mode with -Go YES' {
        Get-StoreCloseAction -Background $true -Go 'YES' -CanWarn $true | Should -Be 'WarnThenForce'
    }

    It 'never closes an app without a warning or without -Go YES' {
        Get-StoreCloseAction -Background $true -Go 'YES' -CanWarn $false | Should -Be 'Skip'
        Get-StoreCloseAction -Background $true -Go 'yes' -CanWarn $true | Should -Be 'Skip'
        Get-StoreCloseAction -Background $true -Go '' -CanWarn $true | Should -Be 'Skip'
    }

    It 'tells the user which apps close, when, and that unsaved work is lost' {
        $text = Get-StoreWarningText -AppNames @('Microsoft.Paint', 'Microsoft.GamingApp', 'Microsoft.Paint') -Seconds 60
        $text | Should -Match 'Microsoft\.GamingApp, Microsoft\.Paint'
        $text | Should -Match '60 seconds'
        $text | Should -Match 'lost'
        @([Text.Encoding]::UTF8.GetBytes($text) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'finds no msg.exe when Windows has none (Home), so nothing is force-closed' {
        Mock Test-Path { $false }
        Get-StoreMsgPath | Should -BeNullOrEmpty
    }

    It 'prefers Sysnative, so a 32-bit RMM agent reaches the real msg.exe' {
        Mock Test-Path { $true }
        Get-StoreMsgPath | Should -Match 'Sysnative\\msg\.exe$'
    }
}

Describe 'Retry Store app updates: waiting' {
    BeforeEach { Mock Start-Sleep { } }

    It 'stops waiting as soon as the check comes true' {
        Wait-StoreSecond -Seconds 300 -Text 'test' -Until { $true } | Should -BeTrue
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'waits the full time when the check stays false' {
        Wait-StoreSecond -Seconds 5 -Text 'test' -Until { $false } | Should -BeFalse
        Should -Invoke Start-Sleep -Times 5 -Exactly
    }

    It 'prints one line per app' {
        $apps = @([pscustomobject]@{ Name = 'Microsoft.Paint'; Status = 'updated' })
        Get-StoreAppLine -Apps $apps | Should -Be @('Microsoft.Paint: updated')
    }
}
