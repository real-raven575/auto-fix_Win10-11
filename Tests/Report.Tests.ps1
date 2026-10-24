BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    $evidence = @(1..3 | ForEach-Object {
            New-AfEvidence -Source System -Provider disk -EventId 7 -Level 2 -TimeCreated ([datetime]'2026-10-19').AddHours(-$_) `
                -Message 'The device, \Device\Harddisk0\DR0, has a bad block. <script>alert(1)</script>' -Path 'C:\Users\alice\notes.txt'
        })
    $sigs = @(Import-AfSignature -Path (Join-Path $PSScriptRoot '..\AutoFixer\Signatures'))
    $script:Result = [pscustomobject]@{
        RunId = '20261020-120000'; StartedAt = [datetime]'2026-10-20T12:00:00'; FinishedAt = [datetime]'2026-10-20T12:00:30'; Days = 14
        Machine = [pscustomobject]@{ ComputerName = 'ALICE-PC'; UserName = 'alice'; Domain = 'CONTOSO'; OS = 'Windows 11 Pro (10.0.22631)'; PowerShell = '5.1'; IsAdmin = $true }
        StabilityIndex = 6.5; EvidenceCount = 3
        Steps = @([pscustomobject]@{ Id = 'system-log'; Name = 'Read System event log'; Status = 'Done'; Seconds = 1.2; Count = 3; Summary = '3 item(s)'; Error = $null })
        Findings = Invoke-AfDiagnosis -Evidence $evidence -Signatures $sigs -Now ([datetime]'2026-10-20T12:00:00')
    }
}

Describe 'Export-AutoFixerReport' {
    It 'writes results.json and report.html into a folder named after the run' {
        $dir = Export-AutoFixerReport -Result $script:Result -OutputRoot $TestDrive
        $dir.Name | Should -Be '20261020-120000'
        Join-Path $dir 'results.json' | Should -Exist
        Join-Path $dir 'report.html' | Should -Exist

        $json = Get-Content (Join-Path $dir 'results.json') -Raw | ConvertFrom-Json
        $json.schemaVersion | Should -Be 1
        $json.findings[0].signatureId | Should -Be 'SIG-DISK-001'
        @($json.findings[0].evidence).Count | Should -Be 3
    }

    It 'escapes log text in the HTML report' {
        $dir = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'html')
        $html = Get-Content (Join-Path $dir 'report.html') -Raw
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match 'Disk is reporting read or write errors'
        $html | Should -Match '<h1>auto-fix_Win report</h1>'
    }

    It 'redacts user and machine names by default' {
        $dir = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'redacted')
        $raw = Get-Content (Join-Path $dir 'results.json') -Raw
        $raw | Should -Not -Match 'alice'
        $raw | Should -Not -Match 'ALICE-PC'
        ($raw | ConvertFrom-Json).redacted | Should -BeTrue
        Get-Content (Join-Path $dir 'report.html') -Raw | Should -Match 'sensitive data: redacted'
    }

    It 'keeps real values only with -IncludeSensitive and says so in the report' {
        $dir = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'raw') -IncludeSensitive
        $raw = Get-Content (Join-Path $dir 'results.json') -Raw
        $raw | Should -Match 'ALICE-PC'
        ($raw | ConvertFrom-Json).redacted | Should -BeFalse
        Get-Content (Join-Path $dir 'report.html') -Raw | Should -Match 'NOT redacted'
    }
}
