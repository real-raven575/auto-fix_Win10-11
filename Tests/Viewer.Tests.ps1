# The in-app results viewer. Reports are written by Export-AutoFixerReport, as a
# real scan writes them, and keys are fed from a queue, as in Menu.Tests.ps1.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    function New-KeyReader([string[]] $Keys) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    $evidence = @(1..3 | ForEach-Object {
            New-AfEvidence -Source System -Provider disk -EventId 7 -Level 2 -TimeCreated ([datetime]'2026-10-19').AddHours(-$_) `
                -Message 'The device, \Device\Harddisk0\DR0, has a bad block. Seen by alice on ALICE-PC.' -Path 'C:\Users\alice\notes.txt'
        })
    $sigs = @(Import-AfSignature -Path (Join-Path $PSScriptRoot '..\AutoFixer\Signatures'))
    $script:Result = [pscustomobject]@{
        RunId = '20261020-120000'; StartedAt = [datetime]'2026-10-20T12:00:00'; FinishedAt = [datetime]'2026-10-20T12:00:30'; Days = 14
        Machine = [pscustomobject]@{ ComputerName = 'ALICE-PC'; UserName = 'alice'; Domain = 'CONTOSO'; OS = 'Windows 11 Pro (10.0.22631)'; PowerShell = '5.1'; IsAdmin = $true }
        StabilityIndex = 6.5; EvidenceCount = 3
        Steps = @([pscustomobject]@{ Id = 'system-log'; Name = 'Read System event log'; Status = 'Done'; Seconds = 1.2; Count = 3; Summary = '3 item(s)'; Error = $null })
        Findings = Invoke-AfDiagnosis -Evidence $evidence -Signatures $sigs -Now ([datetime]'2026-10-20T12:00:00')
    }
    $script:Runs = Join-Path $TestDrive 'Runs'
    $script:Json = (Export-AutoFixerReport -Result $script:Result -OutputRoot $script:Runs).Json
}

Describe 'Reading a saved scan' {
    It 'loads results.json and sums the findings by severity, in words' {
        InModuleScope AutoFixer -Parameters @{ Json = $script:Json } {
            param($Json)
            $model = Read-AfReportModel -Path $Json
            @($model.findings).Count | Should -Be 1
            $lines = @(Get-AfReportSummaryLines -Model $model)
            $lines[0] | Should -Be '1 problem(s) found in the last 14 days.'
            $lines[1] | Should -BeExactly 'CRITICAL 0  HIGH 1  MEDIUM 0  LOW 0  INFO 0'
            $lines[2] | Should -Match 'Stability 6.5 / 10, 3 log entries checked'
            $lines[-1] | Should -Be 'Sensitive data: redacted'
            foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 46 -Because $line }
        }
    }

    It 'shows the file as saved: redacted by default, with a warning when it is not' {
        InModuleScope AutoFixer -Parameters @{ Json = $script:Json; Result = $script:Result; Root = (Join-Path $TestDrive 'Open') } {
            param($Json, $Result, $Root)
            $text = (Get-AfReportLines -Model (Read-AfReportModel -Path $Json)) -join "`n"
            $text | Should -Not -Match 'alice'
            $text | Should -Not -Match 'ALICE-PC'
            $text | Should -Match 'bad block'

            $open = (Export-AutoFixerReport -Result $Result -OutputRoot $Root -IncludeSensitive).Json
            $lines = @(Get-AfReportSummaryLines -Model (Read-AfReportModel -Path $open))
            $lines[-1] | Should -Be 'NOT redacted - handle with care'
        }
    }

    It 'fits every line of the text report in an 80-column console, with no escape codes' {
        InModuleScope AutoFixer -Parameters @{ Json = $script:Json } {
            param($Json)
            $lines = @(Get-AfReportLines -Model (Read-AfReportModel -Path $Json))
            $lines -join "`n" | Should -Match 'Suggested fixes'
            $lines -join "`n" | Should -Match 'Evidence \(3 entries, newest first\)'
            $lines -join "`n" | Should -Match 'What was checked'
            foreach ($line in $lines) {
                $line.Length | Should -BeLessOrEqual 79 -Because $line
                $line.Contains([string][char]27) | Should -BeFalse
            }
        }
    }

    It 'gives a plain reason for a missing, empty, broken or foreign file' {
        InModuleScope AutoFixer -Parameters @{ Dir = $TestDrive } {
            param($Dir)
            $empty = Join-Path $Dir 'empty.json'; Set-Content -Path $empty -Value ''
            $broken = Join-Path $Dir 'broken.json'; Set-Content -Path $broken -Value '{ "schemaVersion": 1, '
            $other = Join-Path $Dir 'other.json'; Set-Content -Path $other -Value '{ "name": "x" }'
            { Read-AfReportModel -Path (Join-Path $Dir 'nope.json') } | Should -Throw 'the file is missing'
            { Read-AfReportModel -Path $empty } | Should -Throw 'the file is empty'
            { Read-AfReportModel -Path $broken } | Should -Throw 'the file is not valid JSON'
            { Read-AfReportModel -Path $other } | Should -Throw 'the file is not an Auto-Fixer results file'
        }
    }

    It 'reads an empty findings list as none, not as one empty finding' {
        InModuleScope AutoFixer -Parameters @{ Dir = $TestDrive } {
            param($Dir)
            $path = Join-Path $Dir 'clean.json'
            Set-Content -Path $path -Value '{ "schemaVersion": 1, "runId": "r", "days": 14, "redacted": true, "machine": { "isAdmin": false }, "findings": [], "steps": [] }'
            $model = Read-AfReportModel -Path $path
            @($model.findings).Count | Should -Be 0
            (Get-AfReportSummaryLines -Model $model)[0] | Should -Be 'No known problems found in the last 14 days.'
            (Get-AfReportLines -Model $model) -join "`n" | Should -Match 'Nothing matched a known problem signature'
        }
    }
}

Describe 'Finding lines' {
    It 'shows whole titles in the list, never cut, and never leaves an & that would mark a menu letter' {
        InModuleScope AutoFixer {
            $label = Get-AfFindingLabel -Finding ([pscustomobject]@{ title = 'Printer & spooler keep crashing after updates'; severity = 'Medium'; count = 120 })
            $label | Should -BeExactly '[MEDIUM] Printer + spooler keep crashing after updates (120)'
        }
    }

    It 'shows a long log message in full: line breaks kept, links whole, nothing cut' {
        InModuleScope AutoFixer {
            $url = 'https://go.microsoft.com/fwlink/?linkid=37020&name=Trojan:Win32/Example.A!ml&threatid=2147735505&enterprise=0'
            $msg = ('Microsoft Defender Antivirus has detected malware or other potentially unwanted software. ' * 6) + "`r`nFor more information please see the following:`r`n" + $url
            $lines = @(Get-AfEvidenceLines -Evidence ([pscustomobject]@{ time = '2026-10-20T12:00:00'; source = 'Defender'; provider = 'Microsoft-Windows-Windows Defender'; eventId = 1116; message = $msg; path = '' }))
            $text = $lines -join "`n"
            $text | Should -Not -Match '\.\.\.'
            @($lines | Where-Object { $_.Trim() -eq $url }).Count | Should -Be 1
            ($text -replace '\s+', ' ') | Should -Match ([regex]::Escape('unwanted software. For more information please see the following:'))
            ([regex]::Matches(($text -replace '\s+', ' '), 'potentially unwanted')).Count | Should -Be 6
        }
    }

    It 'reads the crashing app or service name from the crash messages it knows' {
        InModuleScope AutoFixer {
            $ev = { param($Source, $Message) [pscustomobject]@{ time = '2026-11-10T10:02:00'; source = $Source; eventId = 0; message = $Message } }
            Get-AfEvidenceSubject -Evidence (& $ev 'Application' "Faulting application name: chrome.exe, version: 1.2.3.4, time stamp: 0x5f`r`nFaulting module name: x.dll") | Should -BeExactly 'chrome.exe'
            Get-AfEvidenceSubject -Evidence (& $ev 'WER' 'APPCRASH: Teams.exe (faulting module KERNELBASE.dll)') | Should -BeExactly 'Teams.exe'
            Get-AfEvidenceSubject -Evidence (& $ev 'System' 'The Windows Search service terminated unexpectedly.  It has done this 2 time(s).') | Should -BeExactly 'Windows Search'
            Get-AfEvidenceSubject -Evidence (& $ev 'Application' 'The program notepad.exe version 10.0 stopped interacting with Windows.') | Should -BeExactly 'notepad.exe'
            Get-AfEvidenceSubject -Evidence (& $ev 'System' 'The A & B service terminated unexpectedly.') | Should -BeExactly 'A + B'
            Get-AfEvidenceSubject -Evidence (& $ev 'System' 'Something else happened.') | Should -BeNullOrEmpty
            Get-AfEvidenceSubject -Evidence (& $ev 'System' '') | Should -BeNullOrEmpty
        }
    }

    It 'adds names to the list lines only with -ShowNames, most entries first, within the list width' {
        InModuleScope AutoFixer {
            $ev = { param($Source, $App) [pscustomobject]@{ time = '2026-11-10T10:02:00'; source = $Source; eventId = 1000; message = "Faulting application name: $App, version: 1" } }
            $finding = [pscustomobject]@{ title = 'An app keeps crashing'; severity = 'Medium'; count = 5
                evidence = @((& $ev 'Application' 'b.exe'), (& $ev 'Application' 'a.exe'), (& $ev 'Application' 'b.exe'), (& $ev 'Application' 'c.exe'), [pscustomobject]@{ source = 'WER'; message = 'APPCRASH: b.exe' }) }
            Get-AfFindingLabel -Finding $finding | Should -BeExactly '[MEDIUM] An app keeps crashing (5)'
            Get-AfFindingLabel -Finding $finding -ShowNames | Should -BeExactly '[MEDIUM] An app keeps crashing (5): b.exe 3, a.exe 1, c.exe 1'
            Get-AfEvidenceLabel -Evidence $finding.evidence[0] | Should -BeExactly '2026-11-10 10:02  Application  event 1000'
            Get-AfEvidenceLabel -Evidence $finding.evidence[0] -ShowNames | Should -BeExactly '2026-11-10 10:02  Application  event 1000  b.exe'

            # Many or long names: the line ends with '+N more' or '...', never past the list width.
            $many = [pscustomobject]@{ title = 'An app keeps crashing'; severity = 'Medium'; count = 12
                evidence = @(1..12 | ForEach-Object { & $ev 'Application' ('SomeLongApplicationName{0}.exe' -f $_) }) }
            $label = Get-AfFindingLabel -Finding $many -ShowNames
            $label | Should -Match ', \+\d+ more$'
            $label.Length | Should -BeLessOrEqual $script:AfListLabelWidth
            $long = & $ev 'Application' ('x' * 90 + '.exe')
            $line = Get-AfEvidenceLabel -Evidence $long -ShowNames
            $line | Should -Match '\.\.\.$'
            $line.Length | Should -BeLessOrEqual $script:AfListLabelWidth
            (Get-AfFindingLabel -Finding ([pscustomobject]@{ title = 'T'; severity = 'Low'; count = 1; evidence = @($long) }) -ShowNames).Length | Should -BeLessOrEqual $script:AfListLabelWidth

            # A finding with no named entries keeps its plain line.
            Get-AfFindingLabel -Finding ([pscustomobject]@{ title = 'Disk errors'; severity = 'High'; count = 2; evidence = @() }) -ShowNames | Should -BeExactly '[HIGH] Disk errors (2)'
        }
    }

    It 'shows the names on screen only when screen redaction is off' {
        InModuleScope AutoFixer -Parameters @{ On = (New-KeyReader 'Escape'); Off = (New-KeyReader 'Escape'); InOn = (New-KeyReader 'Escape'); InOff = (New-KeyReader 'Escape') } {
            param($On, $Off, $InOn, $InOff)
            $finding = [pscustomobject]@{ title = 'An app keeps crashing'; severity = 'Medium'; count = 3; fixes = @()
                evidence = @(1..3 | ForEach-Object { [pscustomobject]@{ time = '2026-11-10T10:02:00'; source = 'Application'; eventId = 1000; message = 'Faulting application name: crashy.exe, version: 1' } }) }
            $model = [pscustomobject]@{ findings = @($finding) }
            $text = { param($Screen) (@($Screen | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | ForEach-Object { [string]$_.MessageData }) -join '' }
            $saved = $script:AfUi
            try {
                # Outside a menu session the screen counts as redacted: no names.
                $script:AfUi = $null
                & $text (Select-AfFinding -Model $model -ReadKey $On 6>&1) | Should -Not -Match 'crashy\.exe'
                & $text (Invoke-AfFindingView -Finding $finding -ReadKey $InOn 6>&1) | Should -Not -Match 'crashy\.exe'
                # Show sensitive data on screen (redaction off): names on every line.
                $script:AfUi = @{ IsAdmin = $true; ForcePlain = $false; UsedVt = $false; Facts = @{ OutputRedirected = $true; Width = 120; Height = 40 }
                    Settings = [pscustomobject]@{ Online = $false; ShowSensitive = $true; Style = 'Plain' } }
                & $text (Select-AfFinding -Model $model -ReadKey $Off 6>&1) | Should -Match ([regex]::Escape('An app keeps crashing (3): crashy.exe 3'))
                & $text (Invoke-AfFindingView -Finding $finding -ReadKey $InOff 6>&1) | Should -Match ([regex]::Escape('event 1000  crashy.exe'))
            }
            finally { $script:AfUi = $saved }
        }
    }

    It 'shows one picked log entry as separate lines that each fit 79 columns' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader '2', 'x', 'Escape') } {
            param($Keys)
            $path = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_spoolsv.exe_9a39fe1ebd4959c66898f2840ecdcf4bc403f40_e218e487_265bea86-f15a-4314-a29b-d9baaed9a090\Report.wer'
            $ev = [pscustomobject]@{ time = '2026-11-11T13:34:00'; source = 'Reliability'; provider = 'Microsoft-Windows-WindowsUpdateClient'; eventId = 20; path = $path
                message = 'Installation Failure: Windows failed to install the following update with error 0x80073D02: 9NTXGKQ8P7N0-MicrosoftWindows.CrossDevice.' }
            $lines = @(Get-AfEvidenceLines -Evidence $ev)
            foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 79 -Because $line }
            $lines[0] | Should -BeExactly '    2026-11-11 13:34  Reliability  event 20'
            $lines[1] | Should -BeExactly '      From: Microsoft-Windows-WindowsUpdateClient'
            ((@($lines | Where-Object { $_ -match '^      (File: |      )' }) | ForEach-Object { $_.Substring(12) }) -join '') | Should -BeExactly $path
            $lines -join "`n" | Should -Match '(?m)^      Installation Failure: Windows failed'
            # A short header keeps the provider on the first line.
            (Get-AfEvidenceLines -Evidence ([pscustomobject]@{ time = '2026-11-10T16:25:00'; source = 'WER'; provider = 'Windows Error Reporting'; eventId = 0; path = ''; message = 'APPCRASH: spoolsv.exe' }))[0] |
                Should -BeExactly '    2026-11-10 16:25  WER  Windows Error Reporting  event 0'

            # The viewer prints each line on its own, never glued into one long line.
            $finding = [pscustomobject]@{ title = 'Store app updates blocked'; severity = 'Low'; count = 1; fixes = @(); evidence = @($ev) }
            $screen = Invoke-AfFindingView -Finding $finding -ReadKey $Keys 6>&1
            $printed = @($screen | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            @($printed | Where-Object { $_ -match 'Installation Failure' }).Count | Should -Be 1
            @($printed | Where-Object { $_ -match 'Installation Failure' })[0] | Should -Not -Match 'event 20'
            foreach ($line in @($printed | Where-Object { $_ -match 'Installation|File:|From:' })) { $line.Length | Should -BeLessOrEqual 79 -Because $line }
        }
    }

    It 'names where a fix is in the menu, the same way report.html does' {
        InModuleScope AutoFixer {
            Get-AfFixText -Fixes @('FIX-SFC') | Should -Be 'FIX-SFC (main menu 2, Repair system files: S)'
            Get-AfFixText -Fixes @() | Should -Be 'Advice only'
            Get-AfFixText -Fixes @($null) | Should -Be 'Advice only'
        }
    }
}

Describe 'Viewer screens' {
    BeforeAll {
        $script:Many = [pscustomobject]@{
            runId = 'r'; days = 14; redacted = $true; machine = [pscustomobject]@{ isAdmin = $true }; steps = @()
            findings = @(1..12 | ForEach-Object { [pscustomobject]@{ title = "Problem $_"; severity = 'Low'; count = $_; lastSeen = '2026-10-20T12:00:00'; evidence = @(); fixes = @() } })
        }
    }

    It 'pages the findings list so it fits the box, picks by number and goes back on Esc' {
        # 8 to a page: the box has 14 rows and the list has one line above it.
        InModuleScope AutoFixer -Parameters @{ Model = $script:Many; Pick = (New-KeyReader 'n', '4'); First = (New-KeyReader '2'); Back = (New-KeyReader 'n', 'p', 'Escape') } {
            param($Model, $Pick, $First, $Back)
            (Select-AfFinding -Model $Model -ReadKey $Pick 6>$null).title | Should -Be 'Problem 12'
            (Select-AfFinding -Model $Model -ReadKey $First 6>$null).title | Should -Be 'Problem 2'
            Select-AfFinding -Model $Model -ReadKey $Back 6>$null | Should -BeNullOrEmpty
        }
    }

    It 'walks summary, findings, a finding, and what was checked, then goes back' {
        InModuleScope AutoFixer -Parameters @{ Json = $script:Json; Keys = (New-KeyReader 'f', '1', 'Escape', 'b', 'c', 'Escape', 'b') } {
            param($Json, $Keys)
            $script:AfQuitRequested = $false
            $out = Invoke-AfResultsViewer -Path $Json -ReadKey $Keys 6>&1 | Out-String
            $out | Should -Match 'HIGH 1'
            $out | Should -Match 'Disk is reporting read or write errors'
            $out | Should -Match 'Read System event log'
            $out | Should -Not -Match 'alice'
            $script:AfQuitRequested | Should -BeFalse
        }
    }

    It 'folds each log entry to one line in a finding, and shows it whole when picked' {
        # Findings > 1st finding > its 2nd item (the newest entry) > back, About > back, back, back.
        InModuleScope AutoFixer -Parameters @{ Json = $script:Json; Keys = (New-KeyReader 'f', '1', '2', 'x', 'a', 'Escape', 'b', 'b', 'b') } {
            param($Json, $Keys)
            $out = Invoke-AfResultsViewer -Path $Json -ReadKey $Keys 6>&1 | Out-String
            # The bracketed letter is written on its own, so the label reaches the output in parts.
            $out | Should -Match 'bout this problem and its fixes'
            $out | Should -Match '2026-10-18 23:00  System  event 7'
            $out | Should -Match 'System  disk  event 7'
            $out | Should -Match 'Suggested fixes'
            $out | Should -Not -Match '\.\.\.'
        }
    }

    It 'quits only after Y' {
        InModuleScope AutoFixer -Parameters @{ Json = $script:Json; Keys = (New-KeyReader 'q', 'n', 'q', 'y') } {
            param($Json, $Keys)
            $script:AfQuitRequested = $false
            $null = Invoke-AfResultsViewer -Path $Json -ReadKey $Keys 6>&1
            $script:AfQuitRequested | Should -BeTrue
            $script:AfQuitRequested = $false
        }
    }

    It 'says a broken report cannot be read and goes back without an error' {
        InModuleScope AutoFixer -Parameters @{ Dir = $TestDrive; Keys = (New-KeyReader 'x') } {
            param($Dir, $Keys)
            $broken = Join-Path $Dir 'broken2.json'; Set-Content -Path $broken -Value 'not json'
            $out = Invoke-AfResultsViewer -Path $broken -ReadKey $Keys 6>&1 | Out-String
            $out | Should -Match "This report can't be read: the file is not valid JSON"
        }
    }
}

Describe 'Reports menu' {
    BeforeEach {
        $script:Opened = [System.Collections.ArrayList]::new()
        $opened = $script:Opened
        $script:Open = { param($p) $null = $opened.Add($p) }.GetNewClosure()
    }

    It 'says there is no report yet for every choice when nothing was saved' {
        $out = InModuleScope AutoFixer -Parameters @{ Root = (Join-Path $TestDrive 'none'); Open = $script:Open; Keys = (New-KeyReader 'v', 'o', 'e', 'b') } {
            param($Root, $Open, $Keys)
            Invoke-AfReportMenu -OutputRoot $Root -OpenAction $Open -ReadKey $Keys 6>&1 | Out-String
        }
        ([regex]::Matches($out, 'No report yet. Run a scan first.')).Count | Should -Be 3
        $script:Opened.Count | Should -Be 0
    }

    It 'opens the newest report in the browser, and views an earlier scan here, old folder layout too' {
        $older = Join-Path $script:Runs '20261019-090000'
        $null = New-Item -ItemType Directory -Path $older -Force
        Copy-Item $script:Json (Join-Path $older 'results.json')
        Set-Content -Path (Join-Path $older 'report.html') -Value 'x'
        (Get-Item (Join-Path $older 'results.json')).LastWriteTime = (Get-Date).AddDays(-1)
        (Get-Item (Join-Path $older 'report.html')).LastWriteTime = (Get-Date).AddDays(-1)

        $out = InModuleScope AutoFixer -Parameters @{ Root = $script:Runs; Open = $script:Open; Keys = (New-KeyReader 'o', 'e', '2', 'b', 'b') } {
            param($Root, $Open, $Keys)
            Invoke-AfReportMenu -OutputRoot $Root -OpenAction $Open -ReadKey $Keys 6>&1 | Out-String
        }
        $script:Opened[0] | Should -Match 'AF-[A-Z2-9]{6}-20261020-120000-scan\.html$'
        $out | Should -Match 'run 20261019-090000'
        $out | Should -Match 'Scan results 20261020-120000'
    }

    It 'opens from the main menu Reports item (7), and the viewer opens with V after a scan' {
        Mock -ModuleName AutoFixer Invoke-AfResultsViewer { }
        $path = Join-Path $TestDrive 'settings.json'
        Remove-Item $path -ErrorAction SilentlyContinue
        $null = Invoke-AfMainMenu -SettingsPath $path -OutputRoot $script:Runs -ScanAction { } -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', '1', 'v', '7', 'v', 'b', '1', 'Enter', 'q', 'y') 6>&1
        Should -Invoke -ModuleName AutoFixer Invoke-AfResultsViewer -Times 2 -Exactly
    }
}

Describe 'Start-AutoFixer.ps1 -ShowLastReport' {
    It 'prints the newest scan as text and exits 0, or says there is none and exits 1' {
        $start = Join-Path $PSScriptRoot '..\Start-AutoFixer.ps1'
        $out = & $start -ShowLastReport -OutputRoot $script:Runs 6>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Auto-Fixer report 20261020-120000'
        $out | Should -Match 'HIGH 1'

        $out | Should -Match 'PC id [A-Z2-9]{6}'

        # TestDrive files made in another Describe are gone by now, so this run is made here.
        $older = Join-Path $script:Runs '20261019-090000'
        $null = New-Item -ItemType Directory -Path $older -Force
        Copy-Item $script:Json (Join-Path $older 'results.json')
        (Get-Item (Join-Path $older 'results.json')).LastWriteTime = (Get-Date).AddDays(-1)
        $picked = & $start -ShowLastReport -OutputRoot $script:Runs -RunId '20261019-090000' 6>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $picked | Should -Match 'Auto-Fixer report 20261020-120000'
        $byId = & $start -ShowLastReport -OutputRoot $script:Runs -RunId '20261020-120000' 6>&1 | Out-String
        $byId | Should -Match 'HIGH 1'
        $missing = & $start -ShowLastReport -OutputRoot $script:Runs -RunId '20991231-000000Z' 6>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $missing | Should -Match 'No saved scan has run id 20991231-000000Z'

        $none = & $start -ShowLastReport -OutputRoot (Join-Path $TestDrive 'empty-runs') 6>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $none | Should -Match 'No report yet'
        # The module is reloaded by the script; load it again for the files that follow.
        Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    }
}
