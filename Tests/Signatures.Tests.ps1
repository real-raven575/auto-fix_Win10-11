BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    $script:SigPath = Join-Path $PSScriptRoot '..\AutoFixer\Signatures'
    $script:Now = [datetime]'2026-10-20T12:00:00'

    function New-TestEvent([string]$Source, [string]$Provider, [int]$Id, [int]$DaysAgo = 1, [string]$Message = 'test', [int]$Level = 2) {
        New-AfEvidence -Source $Source -Provider $Provider -EventId $Id -Level $Level -Message $Message -TimeCreated $script:Now.AddDays(-$DaysAgo)
    }
}

Describe 'Starter signatures' {
    It 'all load and carry the required fields' {
        $sigs = @(Import-AfSignature -Path $script:SigPath)
        $sigs.Count | Should -Be 10
        foreach ($sig in $sigs) {
            $sig.id | Should -Match '^SIG-[A-Z]+-\d{3}$'
            @($sig.fixes).Count | Should -BeGreaterThan 0
        }
    }

    It 'have unique ids' {
        $ids = @(Import-AfSignature -Path $script:SigPath | ForEach-Object id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }
}

Describe 'Invoke-AfDiagnosis' {
    BeforeAll { $script:Sigs = @(Import-AfSignature -Path $script:SigPath) }

    It 'returns no findings for a clean machine' {
        $findings = Invoke-AfDiagnosis -Evidence @() -Signatures $script:Sigs -Now $script:Now
        @($findings).Count | Should -Be 0
    }

    It 'flags disk errors once there are at least three' {
        $evidence = @(
            New-TestEvent System disk 7 1
            New-TestEvent System disk 51 2
            New-TestEvent System Microsoft-Windows-Ntfs 55 3
        )
        $finding = Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now
        $finding.SignatureId | Should -Be 'SIG-DISK-001'
        $finding.Count | Should -Be 3
        $finding.Explanation | Should -Match '^Windows logged 3 disk errors since 2026-10-17'
    }

    It 'ignores disk errors below the minimum count' {
        $evidence = @(New-TestEvent System disk 7 1; New-TestEvent System disk 51 2)
        @(Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now).Count | Should -Be 0
    }

    It 'ignores evidence older than the window' {
        $evidence = @(1..3 | ForEach-Object { New-TestEvent System disk 7 30 })
        @(Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now).Count | Should -Be 0
    }

    It 'counts blue screens from both the event log and crash dumps' {
        $evidence = @(
            New-TestEvent System Microsoft-Windows-WER-SystemErrorReporting 1001 2
            New-AfEvidence -Source Minidump -Provider CrashDump -TimeCreated $script:Now.AddDays(-2)
        )
        $finding = Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now
        $finding.SignatureId | Should -Be 'SIG-BSOD-001'
        $finding.Severity | Should -Be 'Critical'
    }

    It 'sends a spooler crash to the printing signature, not the generic service one' {
        $evidence = @(1..3 | ForEach-Object { New-TestEvent System 'Service Control Manager' 7031 $_ 'The Print Spooler service terminated unexpectedly.' })
        $ids = @(Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now | ForEach-Object SignatureId)
        $ids | Should -Contain 'SIG-PRINT-001'
        $ids | Should -Not -Contain 'SIG-SVC-001'
    }

    It 'matches WER app crashes through a parsed field' {
        $evidence = @(1..3 | ForEach-Object {
                New-AfEvidence -Source WER -TimeCreated $script:Now.AddDays(-$_) -Fields @{ EventType = 'APPCRASH' }
            })
        (Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now).SignatureId | Should -Be 'SIG-APP-001'
    }

    It 'ranks findings by severity, most severe first' {
        $evidence = @(
            New-AfEvidence -Source PnP -Provider PnP -EventId 43 -TimeCreated $script:Now.AddHours(-1)
            New-TestEvent System Microsoft-Windows-WER-SystemErrorReporting 1001 1
            New-TestEvent System Microsoft-Windows-WER-SystemErrorReporting 1001 2
            New-AfEvidence -Source CBS -Provider CBS -Message 'Cannot repair member file' -TimeCreated $script:Now.AddDays(-1)
        )
        $order = @(Invoke-AfDiagnosis -Evidence $evidence -Signatures $script:Sigs -Now $script:Now | ForEach-Object Severity)
        $order | Should -Be @('Critical', 'High', 'Medium')
    }

    It 'supports "all" conditions that each need a match' {
        $sig = '{"id":"SIG-TEST-001","title":"t","severity":"Low","explain":"x","match":{"all":[{"source":"System","eventId":[1]},{"source":"Application","eventId":[2]}]}}' | ConvertFrom-Json
        $onlyOne = @(New-TestEvent System p 1)
        @(Invoke-AfDiagnosis -Evidence $onlyOne -Signatures @($sig) -Now $script:Now).Count | Should -Be 0
        $both = @(New-TestEvent System p 1; New-TestEvent Application p 2)
        (Invoke-AfDiagnosis -Evidence $both -Signatures @($sig) -Now $script:Now).Count | Should -Be 2
    }
}
