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
    It 'writes AF-<pc id>-<run>-scan.json and -scan.html into this PC''s folder' {
        $id = InModuleScope AutoFixer { Get-AfPcId }
        $saved = Export-AutoFixerReport -Result $script:Result -OutputRoot $TestDrive
        Split-Path $saved.Folder -Leaf | Should -BeExactly "PC-$id"
        Split-Path $saved.Json -Leaf | Should -BeExactly "AF-$id-20261020-120000-scan.json"
        Split-Path $saved.Html -Leaf | Should -BeExactly "AF-$id-20261020-120000-scan.html"
        $saved.Json | Should -Exist
        $saved.Html | Should -Exist

        $json = Get-Content $saved.Json -Raw | ConvertFrom-Json
        $json.schemaVersion | Should -Be 1
        $json.machine.pcId | Should -BeExactly $id
        Get-Content $saved.Html -Raw | Should -Match "PC id $id"
        $json.findings[0].signatureId | Should -Be 'SIG-DISK-001'
        @($json.findings[0].evidence).Count | Should -Be 3
    }

    It 'escapes log text in the HTML report' {
        $saved = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'html')
        $html = Get-Content $saved.Html -Raw
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match 'Disk is reporting read or write errors'
        $html | Should -Match '<h1>Auto-Fixer report</h1>'
    }

    It 'redacts user and machine names by default' {
        $saved = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'redacted')
        $raw = Get-Content $saved.Json -Raw
        $raw | Should -Not -Match 'alice'
        $raw | Should -Not -Match 'ALICE-PC'
        ($raw | ConvertFrom-Json).redacted | Should -BeTrue
        Get-Content $saved.Html -Raw | Should -Match 'sensitive data: redacted'
    }

    It 'keeps real values only with -IncludeSensitive and says so in the report' {
        $saved = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'raw') -IncludeSensitive
        $raw = Get-Content $saved.Json -Raw
        $raw | Should -Match 'ALICE-PC'
        ($raw | ConvertFrom-Json).redacted | Should -BeFalse
        Get-Content $saved.Html -Raw | Should -Match 'NOT redacted'
    }
}
