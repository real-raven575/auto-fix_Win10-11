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
        $html | Should -Match '<h1>Auto-Fixer report</h1>'
    }

    It 'redacts user and machine names by default' {
        $dir = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'redacted')
        $raw = Get-Content (Join-Path $dir 'results.json') -Raw
        $raw | Should -Not -Match 'alice'
        $raw | Should -Not -Match 'ALICE-PC'
        ($raw | ConvertFrom-Json).redacted | Should -BeTrue
        Get-Content (Join-Path $dir 'report.html') -Raw | Should -Match 'sensitive data: <strong class="bad">redacted</strong>'
    }

    It 'keeps real values only with -IncludeSensitive and says so in the report' {
        $dir = Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'raw') -IncludeSensitive
        $raw = Get-Content (Join-Path $dir 'results.json') -Raw
        $raw | Should -Match 'ALICE-PC'
        ($raw | ConvertFrom-Json).redacted | Should -BeFalse
        $html = Get-Content (Join-Path $dir 'report.html') -Raw
        $html | Should -Match '<div class="alert">NOT redacted - handle this file with care'
    }

    It 'follows the Windows light or dark theme, with zebra rows and the key words marked' {
        $html = Get-Content (Join-Path (Export-AutoFixerReport -Result $script:Result -OutputRoot (Join-Path $TestDrive 'theme')) 'report.html') -Raw
        $html | Should -Match '<meta name="color-scheme" content="light dark">'
        $html | Should -Match '@media \(prefers-color-scheme: dark\)'
        $html | Should -Match 'tr:nth-child\(even\) td \{ background:var\(--zebra\)'
        $html | Should -Match 'administrator: <strong class="ok">Yes</strong>'
    }
}

Describe 'Long log messages in report.html' {
    It 'are never cut: a long one folds and opens on a click, with its link whole and clickable' {
        InModuleScope AutoFixer {
            $url = 'https://go.microsoft.com/fwlink/?linkid=37020&name=Trojan:Win32/Example.A!ml&threatid=2147735505'
            $msg = ('Microsoft Defender Antivirus has detected malware or other potentially unwanted software. ' * 4) + "`r`nFor more information please see the following:`r`n" + $url + '.'
            $html = Get-AfHtmlMessage $msg
            $html | Should -Match '^<details class="msg"><summary><span class="preview">Microsoft Defender'
            $html | Should -Match '<span class="more">Show more</span>'
            $html | Should -Not -Match '\.\.\.'
            $href = [System.Net.WebUtility]::HtmlEncode($url)
            $html | Should -Match ([regex]::Escape(('<a href="{0}" target="_blank" rel="noopener noreferrer">{0}</a>.' -f $href)))
            # The whole message sits inside the fold, line breaks kept.
            $html.Contains('<div>' + (ConvertTo-AfHtmlText $msg) + '</div></details>') | Should -BeTrue
            $html | Should -Match 'unwanted software\. <br>For more information'
        }
    }

    It 'keeps a short message as it is, and never turns log text into code or a script link' {
        InModuleScope AutoFixer {
            Get-AfHtmlMessage 'Short message.' | Should -BeExactly 'Short message.'
            $html = Get-AfHtmlMessage '<script>alert(1)</script> javascript:alert(1) "https://example.com/a"'
            $html | Should -Not -Match '<script>'
            $html | Should -Not -Match 'href="javascript'
            $html | Should -Match '&quot;<a href="https://example.com/a" target="_blank" rel="noopener noreferrer">https://example.com/a</a>&quot;'
        }
    }
}
