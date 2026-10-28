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
    $script:Json = Join-Path (Export-AutoFixerReport -Result $script:Result -OutputRoot $script:Runs).FullName 'results.json'
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

            $open = Join-Path (Export-AutoFixerReport -Result $Result -OutputRoot $Root -IncludeSensitive).FullName 'results.json'
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
    It 'cuts long titles to fit the list and never leaves an & that would mark a menu letter' {
        InModuleScope AutoFixer {
            $label = Get-AfFindingLabel -Finding ([pscustomobject]@{ title = 'Printer & spooler keep crashing after every single Windows update'; severity = 'Medium'; count = 120 })
            $label.Length | Should -BeLessOrEqual 38
            $label | Should -Match '^\[MEDIUM\] Printer \+ spooler'
            $label | Should -Match '\.\.\. \(120\)$'
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

    It 'pages the findings list 9 at a time, picks by number and goes back on Esc' {
        InModuleScope AutoFixer -Parameters @{ Model = $script:Many; Pick = (New-KeyReader 'n', '3'); First = (New-KeyReader '2'); Back = (New-KeyReader 'n', 'p', 'Escape') } {
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

    It 'opens the newest report.html in the browser, and views an earlier scan here' {
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
        $script:Opened[0] | Should -Match '20261020-120000'
        $out | Should -Match 'run 20261019-090000'
        $out | Should -Match 'Scan results 20261020-120000'
    }

    It 'opens from main menu item 4, and the viewer opens with V after a scan' {
        Mock -ModuleName AutoFixer Invoke-AfResultsViewer { }
        $path = Join-Path $TestDrive 'settings.json'
        Remove-Item $path -ErrorAction SilentlyContinue
        $null = Invoke-AfMainMenu -SettingsPath $path -OutputRoot $script:Runs -ScanAction { } -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', '1', 'v', '4', 'v', 'b', '1', 'Enter', 'q', 'y') 6>&1
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

        $older = & $start -ShowLastReport -OutputRoot $script:Runs -RunId '20261019-090000' 6>&1 | Out-String
        $older | Should -Match 'Auto-Fixer report 20261020-120000'

        $none = & $start -ShowLastReport -OutputRoot (Join-Path $TestDrive 'empty-runs') 6>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $none | Should -Match 'No report yet'
        # The module is reloaded by the script; load it again for the files that follow.
        Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    }
}
