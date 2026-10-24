BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    $script:Data = Join-Path $PSScriptRoot 'Data'
}

Describe 'ConvertFrom-AfWerReport' {
    It 'turns Sig pairs into named fields' {
        InModuleScope AutoFixer -Parameters @{ Data = $script:Data } {
            param($Data)
            $lines = Get-Content (Join-Path $Data 'Report.wer')
            $ev = ConvertFrom-AfWerReport -Lines $lines -Path 'Report.wer'
            $ev.Source | Should -Be 'WER'
            $ev.Fields['EventType'] | Should -Be 'APPCRASH'
            $ev.Fields['Application Name'] | Should -Be 'editor.exe'
            $ev.Message | Should -Be 'APPCRASH: editor.exe (faulting module renderer.dll)'
            $ev.TimeCreated.Year | Should -Be 2025
        }
    }

    It 'returns nothing for an empty file' {
        InModuleScope AutoFixer { @(ConvertFrom-AfWerReport -Lines @('')).Count | Should -Be 0 }
    }
}

Describe 'ConvertFrom-AfCbsLog' {
    It 'keeps only corruption lines inside the window' {
        InModuleScope AutoFixer -Parameters @{ Data = $script:Data } {
            param($Data)
            $lines = Get-Content (Join-Path $Data 'CBS.log')
            $ev = @(ConvertFrom-AfCbsLog -Lines $lines -Source CBS -Since ([datetime]'2026-10-06'))
            $ev.Count | Should -Be 2
            $ev[0].Message | Should -Match 'Cannot repair member file'
            $ev[1].Message | Should -Match '0x800f081f'
            $ev[0].TimeCreated | Should -Be ([datetime]'2026-10-18T09:15:44')
        }
    }
}

Describe 'ConvertFrom-AfSetupApiLog' {
    It 'reports failed device installs with their section name' {
        InModuleScope AutoFixer -Parameters @{ Data = $script:Data } {
            param($Data)
            $lines = Get-Content (Join-Path $Data 'setupapi.dev.log')
            $ev = @(ConvertFrom-AfSetupApiLog -Lines $lines -Since ([datetime]'2026-10-06'))
            $ev.Count | Should -Be 1
            $ev[0].Fields.ExitStatus | Should -Be '0xe0000219'
            $ev[0].Message | Should -Match 'USB\\VID_1234'
        }
    }
}

Describe 'Event log collectors' {
    It 'converts event records to evidence' {
        Mock -ModuleName AutoFixer Get-WinEvent {
            [pscustomobject]@{ Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; Level = 1; LogName = 'System'
                TimeCreated = [datetime]'2026-10-19T08:00:00'; Message = 'The system has rebooted without cleanly shutting down first.' }
        }
        $ev = InModuleScope AutoFixer { Get-AfSystemLogEvidence -Since ([datetime]'2026-10-06') }
        $ev.Source | Should -Be 'System'
        $ev.EventId | Should -Be 41
        $ev.Provider | Should -Be 'Microsoft-Windows-Kernel-Power'
    }

    It 'treats "no events found" as an empty result, not a failure' {
        Mock -ModuleName AutoFixer Get-WinEvent { throw [System.Exception]::new('No events were found that match the specified selection criteria.') }
        $ev = InModuleScope AutoFixer { @(Get-AfApplicationLogEvidence -Since ([datetime]'2026-10-06')) }
        $ev.Count | Should -Be 0
    }

    It 'lets real errors through so the step is marked failed' {
        Mock -ModuleName AutoFixer Get-WinEvent { throw [System.UnauthorizedAccessException]::new('Access is denied.') }
        { InModuleScope AutoFixer { Get-AfSystemLogEvidence -Since ([datetime]'2026-10-06') } } | Should -Throw '*Access is denied*'
    }
}

Describe 'Reliability collector' {
    It 'reads the stability index and the reliability records since the window start' {
        Mock -ModuleName AutoFixer Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ReliabilityStabilityMetrics' } {
            [pscustomobject]@{ TimeGenerated = [datetime]'2026-10-22T00:00:00'; SystemStabilityIndex = 5.09 }
        }
        Mock -ModuleName AutoFixer Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ReliabilityRecords' } {
            [pscustomobject]@{ TimeGenerated = [datetime]'2026-10-19T21:21:00'; SourceName = 'Microsoft-Windows-WindowsUpdateClient'
                EventIdentifier = 20; ProductName = 'KB5126657'; Message = 'Installation Failure: Windows failed to install the following update' }
        }

        $ev = @(InModuleScope AutoFixer { Get-AfReliabilityEvidence -Since ([datetime]'2026-10-06') })
        $ev.Count | Should -Be 2
        $ev[0].Fields.StabilityIndex | Should -Be 5.09
        $ev[1].Provider | Should -Be 'Microsoft-Windows-WindowsUpdateClient'
        $ev[1].EventId | Should -Be 20
        Should -Invoke -ModuleName AutoFixer Get-CimInstance -ParameterFilter { $Filter -match "^TimeGenerated >= '\d{14}\.000000\+000'$" } -Times 1
    }
}
