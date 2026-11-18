# The window's change tasks (GUI part 2): the plans behind the "Are you sure?" dialog, the
# answers handed to the engine, and the Activity lines read back from it. None of this
# needs WPF, so it runs on any machine.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Repair plan' {
    It 'asks about every changing step, the restore point and Windows Update in one dialog (Online on)' {
        InModuleScope AutoFixer {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-guitask-{0}' -f [guid]::NewGuid())
            $plan = Get-AfGuiRepairPlan -Queue $script:AfRunAll -Settings ([pscustomobject]@{ Mode = 'Standard'; Online = $true }) -OutputRoot $root
            $plan.Changes | Should -BeTrue
            $plan.Admin | Should -BeTrue
            $plan.RestorePoint | Should -BeTrue
            $plan.Internet | Should -Match 'Windows Update \(Microsoft\)'
            $plan.Answers['Start SFC scan?'] | Should -BeTrue
            $plan.Answers['Start DISM RestoreHealth?'] | Should -BeTrue
            $plan.Answers['Connect to Windows Update?'] | Should -BeTrue
            $plan.Answers['Plan'] | Should -BeTrue
            # Anything the dialog did not ask stops the run instead of guessing.
            $plan.Answers['Continue without a restore point?'] | Should -BeFalse
            $plan.Answers['Run the remaining steps anyway?'] | Should -BeFalse
            $plan.Answers['Restart now?'] | Should -BeFalse
            # SFC runs twice but is described once.
            @($plan.What | Where-Object { $_ -like 'SFC scan*' }).Count | Should -Be 1
            $plan.Arguments.Queue.Count | Should -Be 6
        }
    }

    It 'never answers Windows Update when the Online switch is off' {
        InModuleScope AutoFixer {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-guitask-{0}' -f [guid]::NewGuid())
            $plan = Get-AfGuiRepairPlan -Queue @('RESTORE') -Settings ([pscustomobject]@{ Mode = 'Standard'; Online = $false }) -OutputRoot $root
            $plan.Answers.ContainsKey('Connect to Windows Update?') | Should -BeFalse
            $plan.Internet | Should -Match '^Never'
            $plan.Title | Should -Be 'DISM RestoreHealth'
        }
    }

    It 'treats a read-only step as no change, with no restore point' {
        InModuleScope AutoFixer {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-guitask-{0}' -f [guid]::NewGuid())
            $plan = Get-AfGuiRepairPlan -Queue @('CHECK') -Settings ([pscustomobject]@{ Mode = 'Standard'; Online = $true }) -OutputRoot $root
            $plan.Changes | Should -BeFalse
            $plan.RestorePoint | Should -BeFalse
            (Get-AfGuiConfirmLines -Plan $plan) -join "`n" | Should -Match 'Changes this PC: No'
        }
    }

    It 'shows what, change, administrator, internet and time in the dialog' {
        InModuleScope AutoFixer {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-guitask-{0}' -f [guid]::NewGuid())
            $lines = (Get-AfGuiConfirmLines -Plan (Get-AfGuiRepairPlan -Queue @('SFC') -Settings ([pscustomobject]@{ Mode = 'Standard'; Online = $false }) -OutputRoot $root)) -join "`n"
            $lines | Should -Match 'What it does:'
            $lines | Should -Match 'Changes this PC: Yes'
            $lines | Should -Match 'Needs administrator rights: Yes'
            $lines | Should -Match 'Internet: Never'
            $lines | Should -Match 'Time: ~\d+ min'
        }
    }
}

Describe 'Clean up plans' {
    It 'removes only ticked, unlocked items and names the ones that lose something' {
        InModuleScope AutoFixer {
            $items = @(
                @{ Key = 'Temporary Files'; Label = 'Temporary files'; Size = 1048576; Warn = 0; Checked = $true; Locked = $null }
                @{ Key = 'Recycle Bin'; Label = 'Recycle Bin'; Size = 2048; Warn = 2; Note = 'Files in the Recycle Bin are deleted for good.'; Checked = $true; Locked = $null }
                @{ Key = 'Thumbnail Cache'; Label = 'Thumbnails'; Size = 10; Warn = 0; Checked = $false; Locked = $null }
                @{ Key = 'Setup Log Files'; Label = 'Windows setup log files'; Size = $null; Warn = 0; Checked = $true; Locked = 'Locked' }
            )
            $plan = Get-AfGuiCleanPlan -Items $items -Settings ([pscustomobject]@{ Mode = 'Standard' }) -OutputRoot 'C:\x'
            $plan.Arguments['Chosen'] | Should -Be @('Temporary Files', 'Recycle Bin')
            $plan.Answers['Remove Recycle Bin anyway?'] | Should -BeTrue
            $plan.Answers['Run Disk Cleanup now?'] | Should -BeTrue
            ($plan.What -join "`n") | Should -Match 'deleted for good'
            $plan.Warning | Should -Match 'cannot be put back'
            $plan.Changes | Should -BeTrue
            $plan.RestorePoint | Should -BeFalse
        }
    }

    It 'measures without a dialog, since it only reads' {
        InModuleScope AutoFixer { (Get-AfGuiMeasurePlan).Changes | Should -BeFalse }
    }

    It 'TRIMs an SSD and defrags a hard drive' {
        InModuleScope AutoFixer {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-guitask-{0}' -f [guid]::NewGuid())
            $s = [pscustomobject]@{ Mode = 'Standard' }
            (Get-AfGuiOptimizePlan -Drive ([pscustomobject]@{ Letter = 'C'; Media = 'SSD' }) -Settings $s -OutputRoot $root).What[0] | Should -Match '^TRIM drive C'
            (Get-AfGuiOptimizePlan -Drive ([pscustomobject]@{ Letter = 'D'; Media = 'HDD' }) -Settings $s -OutputRoot $root).What[0] | Should -Match '^Defrag drive D'
        }
    }
}

Describe 'Answers from the window' {
    AfterEach { InModuleScope AutoFixer { $script:AfGuiRun = $null } }

    It 'answers a known prompt without reading a key, and leaves others to -ReadKey' {
        InModuleScope AutoFixer {
            $script:AfGuiRun = @{ Answers = @{ 'Start SFC scan?' = $true; 'Plan' = $true } }
            Read-AfYesNo -Prompt 'Start SFC scan?' -ReadKey { throw 'should not read a key' } 6>$null | Should -BeTrue
            Read-AfYesNo -Prompt 'Something else?' -ReadKey { 'N' } 6>$null | Should -BeFalse
            Confirm-AfRepairPlan -ReadKey { throw 'should not read a key' } 6>$null | Should -BeTrue
        }
    }

    It 'never draws a console panel during a window run' {
        InModuleScope AutoFixer {
            $script:AfGuiRun = @{ Answers = @{} }
            (Open-AfProgressView -Title 'x' -Mode 'Standard').Kind | Should -Be 'Lines'
        }
    }

    It 'runs a task in a background runspace inside the module, with the answers' {
        InModuleScope AutoFixer {
            $sync = [hashtable]::Synchronized(@{ Done = $false; Error = $null; Result = $null })
            $ps = [powershell]::Create()
            try {
                [void]$ps.AddScript($script:AfGuiTaskScript.ToString())
                [void]$ps.AddArgument((Join-Path $script:AfModuleRoot 'AutoFixer.psd1'))
                [void]$ps.AddArgument('param($A) Write-Host ''  Working'' -ForegroundColor Green; [pscustomobject]@{ Said = (Read-AfYesNo -Prompt $A.Prompt -ReadKey { ''N'' }); Steps = $script:AfRepairSteps.Count }')
                [void]$ps.AddArgument(@{ Prompt = 'Start SFC scan?' })
                [void]$ps.AddArgument(@{ 'Start SFC scan?' = $true })
                [void]$ps.AddArgument($sync)
                [void]$ps.Invoke()
                $sync.Done | Should -BeTrue
                $sync.Error | Should -BeNullOrEmpty
                @($sync.Result)[-1].Said | Should -BeTrue
                # Private module data is in reach, so the engine functions run as they do in the console.
                @($sync.Result)[-1].Steps | Should -BeGreaterThan 0
                $lines = @(ConvertFrom-AfGuiHostLine -Records @($ps.Streams.Information | ForEach-Object { $_.MessageData }) -Pending @{ Text = ''; Color = $null })
                $lines[0].Text | Should -Be 'Working'
                $lines[0].Tag | Should -Be 'OK'
                ($lines.Text -join "`n") | Should -Match 'answered in the window'
            }
            finally { $ps.Dispose() }
        }
    }

    It 'copies results into plain arrays without @()' {
        InModuleScope AutoFixer {
            (ConvertTo-AfGuiArray $null).Count | Should -Be 0
            (ConvertTo-AfGuiArray 'one line').Count | Should -Be 1
            (ConvertTo-AfGuiArray @{ A = 1; B = 2 }).Count | Should -Be 1
            (ConvertTo-AfGuiArray ([pscustomobject]@{ Tag = 'OK' }))[0].Tag | Should -Be 'OK'
            (ConvertTo-AfGuiArray @(1, 2, 3)).Count | Should -Be 3
            $list = New-Object System.Collections.Generic.List[object]
            $list.Add('a'); $list.Add('b')
            $copy = ConvertTo-AfGuiArray $list
            $copy.GetType().Name | Should -Be 'Object[]'
            $copy[1] | Should -Be 'b'
        }
    }

    It 'reads a repair result made in the task runspace, as after DISM CheckHealth' {
        InModuleScope AutoFixer {
            # Found in a hand test: the window closed after a repair with "Argument types do not
            # match" from @() on the runspace's result. The result is shaped like Invoke-AfRepairQueue's.
            $sync = [hashtable]::Synchronized(@{ Done = $false; Error = $null; Result = $null })
            $ps = [powershell]::Create()
            try {
                [void]$ps.AddScript($script:AfGuiTaskScript.ToString())
                [void]$ps.AddArgument((Join-Path $script:AfModuleRoot 'AutoFixer.psd1'))
                [void]$ps.AddArgument('param($A) $steps = New-Object System.Collections.Generic.List[object]; $steps.Add([pscustomobject]@{ Key = ''C''; Name = ''Check''; Tag = ''ISSUES''; Seconds = 0; ExitCode = 0; Result = ''repairable'' }); [pscustomobject]@{ Steps = $steps; LogPath = $null; RestartNeeded = $false; Stopped = $false; Online = $false }')
                [void]$ps.AddArgument(@{})
                [void]$ps.AddArgument(@{})
                [void]$ps.AddArgument($sync)
                [void]$ps.Invoke()
                $sync.Error | Should -BeNullOrEmpty
                $sync.Result.GetType().Name | Should -Be 'Object[]'
                $all = ConvertTo-AfGuiArray $sync.Result
                $outcome = Get-AfGuiTaskOutcome -Kind 'repair' -Result $all[$all.Length - 1]
                $outcome.Tag | Should -Be 'FAIL'
                $outcome.Text | Should -Match '^0 of 1 step\(s\) OK, 1 with problems'
            }
            finally { $ps.Dispose() }
        }
    }
}

Describe 'Printer plans and fixes' {
    BeforeAll {
        InModuleScope AutoFixer {
            $script:PrnCheck = [pscustomobject]@{
                SpoolerState = 'Running'; StartMode = 'Manual'; JobCount = 3; SpoolFileCount = 2; WindowsManagesDefault = $true
                Printers = @(
                    [pscustomobject]@{ Name = 'Office Laser'; Jobs = 3; Offline = $true; Default = $false; Driver = 'HP Universal' }
                    [pscustomobject]@{ Name = 'Office Laser (Copy 1)'; Jobs = 0; Offline = $false; Default = $false; Driver = 'HP Universal' }
                    [pscustomobject]@{ Name = 'Label Printer'; Jobs = 0; Offline = $false; Default = $true; Driver = 'Zebra' }
                )
                Duplicates = @([pscustomobject]@{ Names = @('Office Laser', 'Office Laser (Copy 1)'); Keep = 'Office Laser'; PortKind = 'Network' })
            }
            $script:PrnSettings = [pscustomobject]@{ Mode = 'Technician'; Online = $false }
        }
    }
    AfterEach { InModuleScope AutoFixer { $script:AfGuiRun = $null } }

    It 'marks the same keys administrator-only as the console, and asks before a test page' {
        InModuleScope AutoFixer {
            $root = [IO.Path]::GetTempPath()
            foreach ($key in 'T', 'O', 'J', 'C', 'R', 'D', 'S', 'V', 'M', 'W') {
                $plan = Get-AfGuiPrinterFixPlan -Key $key -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Printer $script:PrnCheck.Printers[0]
                $plan.Admin | Should -Be ($key -in 'R', 'C', 'J', 'S', 'V', 'M') -Because "key $key"
                $plan.Kind | Should -Be 'printfix'
                $plan.Arguments.Picks | Should -Be @('Office Laser')
            }
            $t = Get-AfGuiPrinterFixPlan -Key 'T' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Printer $script:PrnCheck.Printers[0]
            $t.Changes | Should -BeFalse
            $t.Ask | Should -BeTrue
            $t.Answers['Print the test page?'] | Should -BeTrue
        }
    }

    It 'puts the typed address in the Connect title, so a typo shows before it runs' {
        InModuleScope AutoFixer {
            $plan = Get-AfGuiPrinterFixPlan -Key 'N' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot ([IO.Path]::GetTempPath()) -Path '\\server01\printerfake'
            $plan.Title | Should -Be 'Connect \\server01\printerfake'
        }
    }

    It 'asks twice before clearing every print job' {
        InModuleScope AutoFixer {
            $plan = Get-AfGuiPrinterFixPlan -Key 'C' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot ([IO.Path]::GetTempPath())
            $plan.SecondAsk | Should -Match 'cannot be brought back'
            $plan.Answers['Clear all print jobs?'] | Should -BeTrue
            $plan.Answers['Are you sure? Waiting jobs cannot be brought back.'] | Should -BeTrue
            $plan.What[0] | Should -Match '3 job\(s\), 2 file\(s\)'
        }
    }

    It 'offers the default-printer setting only when Windows manages it, and a restore point before removing a driver' {
        InModuleScope AutoFixer {
            $root = [IO.Path]::GetTempPath()
            (Get-AfGuiPrinterFixPlan -Key 'D' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Printer $script:PrnCheck.Printers[2]).OptionPrompt | Should -Be 'Turn that setting off?'
            $own = [pscustomobject]@{ WindowsManagesDefault = $false; Printers = @() }
            (Get-AfGuiPrinterFixPlan -Key 'D' -Check $own -Settings $script:PrnSettings -OutputRoot $root -Printer $script:PrnCheck.Printers[2]).OptionPrompt | Should -BeNullOrEmpty
            $u = Get-AfGuiPrinterFixPlan -Key 'U' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Driver 'Old Driver'
            $u.OptionPrompt | Should -Be 'Make a restore point first?'
            $u.Arguments.Picks | Should -Be @('Old Driver')
            $u.Admin | Should -BeTrue
        }
    }

    It 'keeps the picked copy and answers Yes only for the others' {
        InModuleScope AutoFixer {
            $g = $script:PrnCheck.Duplicates[0]
            $plan = Get-AfGuiPrinterFixPlan -Key 'P' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot ([IO.Path]::GetTempPath()) -Group $g -Keep 'Office Laser (Copy 1)'
            $plan.Answers.Keys | Should -Be @('Remove the extra copy Office Laser?')
            $plan.Arguments.Picks | Should -Be @('Office Laser = Office Laser (Copy 1)', 'Office Laser (Copy 1)')
        }
    }

    It 'shows names through -Show in the dialog' {
        InModuleScope AutoFixer {
            $plan = Get-AfGuiPrinterFixPlan -Key 'O' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot ([IO.Path]::GetTempPath()) -Printer $script:PrnCheck.Printers[0] -Show { param($Text) '<PRINTER>' }
            $plan.What[0] | Should -Be 'Turns off Use printer offline for <PRINTER>.'
            # The engine still gets the real name to pick.
            $plan.Arguments.Picks | Should -Be @('Office Laser')
        }
    }

    It 'runs the console fix on the clicked printer only, and logs the outcome' {
        InModuleScope AutoFixer {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-guiprn-{0}' -f [guid]::NewGuid())
            $null = New-Item -ItemType Directory -Path $root
            try {
                $calls = New-Object System.Collections.ArrayList
                $ops = @{ IsAdmin = { $true }; SetOffline = { param($Name, $Value) [void]$calls.Add("$Name=$Value") }.GetNewClosure() }
                $plan = Get-AfGuiPrinterFixPlan -Key 'O' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Printer $script:PrnCheck.Printers[0]
                $script:AfGuiRun = @{ Answers = $plan.Answers }
                $r = Invoke-AfGuiPrinterFix -Key 'O' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Picks $plan.Arguments.Picks -Ops $ops 6>$null
                $r.Tag | Should -Be 'OK'
                @($calls) | Should -Be @('Office Laser=False')
                $log = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*printer.log')
                $log.Count | Should -Be 1
                Get-Content -LiteralPath $log[0].FullName -Raw | Should -Match 'OK     O: Use printer offline is off.'
                # A printer that is gone since the check: nothing is changed.
                $calls.Clear()
                $r = Invoke-AfGuiPrinterFix -Key 'O' -Check $script:PrnCheck -Settings $script:PrnSettings -OutputRoot $root -Picks @('Gone Printer') -Ops $ops 6>$null
                $r.Tag | Should -Be 'CANCELLED'
                $calls.Count | Should -Be 0
            }
            finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'lists only unused drivers that are not built into Windows' {
        InModuleScope AutoFixer {
            $ops = @{
                DriversInUse = { @('Zebra') }
                GetDrivers   = { @(
                        [pscustomobject]@{ Name = 'HP Universal'; Inf = 'oem12.inf' }
                        [pscustomobject]@{ Name = 'Zebra'; Inf = 'oem3.inf' }
                        [pscustomobject]@{ Name = 'Old Canon'; Inf = 'oem9.inf' }
                        [pscustomobject]@{ Name = 'Microsoft Print To PDF'; Inf = 'ntprint.inf' }
                        [pscustomobject]@{ Name = 'Some Class Driver'; Inf = 'C:\Windows\INF\prnms009.inf' }
                    ) }
            }
            @(Get-AfUnusedPrinterDriver -Check $script:PrnCheck -Ops $ops) | Should -Be @('Old Canon')
        }
    }

    It 'shows a .NET error without its wrapper or line breaks' {
        InModuleScope AutoFixer {
            $raw = "Exception calling `"FindAll`" with `"0`" argument(s): `"The specified domain either does not exist or could not be contacted.`r`n`""
            (Get-AfGuiTaskOutcome -Kind 'printdomain' -ErrorText $raw).Text | Should -Be 'Failed: The specified domain either does not exist or could not be contacted.'
            (Get-AfGuiTaskOutcome -Kind 'printdomain' -ErrorText 'Plain error.').Text | Should -Be 'Failed: Plain error.'
        }
    }

    It 'says Finished once when the tool detail is the same word' {
        InModuleScope AutoFixer {
            (Get-AfGuiTaskOutcome -Kind 'optimize' -Result ([pscustomobject]@{ Tag = 'OK'; Detail = 'Finished.' })).Text | Should -Be 'Finished.'
            (Get-AfGuiTaskOutcome -Kind 'optimize' -Result ([pscustomobject]@{ Tag = 'STOPPED'; Detail = 'Stopped with the Stop button.' })).Text | Should -Be 'Stopped part-way. Stopped with the Stop button.'
        }
    }

    It 'sums up a printer check and the lists in one line' {
        InModuleScope AutoFixer {
            (Get-AfGuiTaskOutcome -Kind 'printcheck' -Result $script:PrnCheck).Text | Should -Be 'Printer check done: 3 printer(s), Print Spooler Running.'
            (Get-AfGuiTaskOutcome -Kind 'printdrivers' -Result @('A', 'B')).Text | Should -Match '^2 unused printer driver'
            (Get-AfGuiTaskOutcome -Kind 'printdomain' -Result $null).Text | Should -Match '^0 shared printer'
            (Get-AfGuiPrinterCheckPlan).Changes | Should -BeFalse
            (Get-AfGuiPrinterListPlan -List 'Drivers' -Check $script:PrnCheck).Kind | Should -Be 'printdrivers'
            (Get-AfGuiPrinterListPlan -List 'Domain').Kind | Should -Be 'printdomain'
        }
    }
}

Describe 'Activity lines and progress' {
    It 'joins -NoNewline pieces, tags by colour and drops console codes and rules' {
        InModuleScope AutoFixer {
            $pending = @{ Text = ''; Color = $null }
            $records = @(
                [pscustomobject]@{ Message = '  Start SFC scan? [Y/N] '; NoNewLine = $true; ForegroundColor = $null }
                [pscustomobject]@{ Message = 'Y'; NoNewLine = $false; ForegroundColor = $null }
                [pscustomobject]@{ Message = "$([char]27)[2K  Restore point created."; NoNewLine = $false; ForegroundColor = 'Green' }
                [pscustomobject]@{ Message = '------------'; NoNewLine = $false; ForegroundColor = $null }
                [pscustomobject]@{ Message = ''; NoNewLine = $false; ForegroundColor = $null }
                [pscustomobject]@{ Message = '  No restore point: off'; NoNewLine = $false; ForegroundColor = 'Yellow' }
                [pscustomobject]@{ Message = '  half'; NoNewLine = $true; ForegroundColor = 'Red' }
            )
            $lines = @(ConvertFrom-AfGuiHostLine -Records $records -Pending $pending)
            $lines.Count | Should -Be 3
            $lines[0].Text | Should -Be 'Start SFC scan? [Y/N] Y'
            $lines[0].Tag | Should -Be 'INFO'
            $lines[1].Text | Should -Be 'Restore point created.'
            $lines[1].Tag | Should -Be 'OK'
            $lines[2].Tag | Should -Be 'WARN'
            # The unfinished piece waits for the rest of its line.
            $pending.Text | Should -Be '  half'
            $done = @(ConvertFrom-AfGuiHostLine -Records @([pscustomobject]@{ Message = ' line'; NoNewLine = $false; ForegroundColor = $null }) -Pending $pending)
            $done[0].Text | Should -Be 'half line'
            $done[0].Tag | Should -Be 'FAIL'
        }
    }

    It 'never shows 100% by time, and says when a step runs long' {
        InModuleScope AutoFixer {
            (Get-AfGuiTimeProgress -Elapsed 30 -Estimate 60).Percent | Should -Be 50
            $late = Get-AfGuiTimeProgress -Elapsed 600 -Estimate 60
            $late.Percent | Should -Be 99
            $late.Text | Should -Match 'longer than expected'
        }
    }

    It 'sums up a repair, a clean-up and an error in one line' {
        InModuleScope AutoFixer {
            $run = [pscustomobject]@{ Steps = @([pscustomobject]@{ Tag = 'OK' }, [pscustomobject]@{ Tag = 'FAILED' }, [pscustomobject]@{ Tag = 'SKIPPED' }); RestartNeeded = $true; Stopped = $false }
            $o = Get-AfGuiTaskOutcome -Kind 'repair' -Result $run
            $o.Tag | Should -Be 'FAIL'
            $o.Text | Should -Match '1 of 3 step\(s\) OK, 1 with problems, 1 not run'
            $o.Text | Should -Match 'needs a restart'
            (Get-AfGuiTaskOutcome -Kind 'clean' -Result ([pscustomobject]@{ Tag = 'OK'; Freed = 1048576 })).Text | Should -Match 'Freed 1(\.0)? MB'
            (Get-AfGuiTaskOutcome -Kind 'optimize' -Result ([pscustomobject]@{ Tag = 'CANCELLED'; Detail = '' })).Tag | Should -Be 'WARN'
            # A step stopped with the Stop button is a warning, not a problem.
            $stop = Get-AfGuiTaskOutcome -Kind 'repair' -Result ([pscustomobject]@{ Steps = @([pscustomobject]@{ Tag = 'STOPPED' }); RestartNeeded = $false; Stopped = $true })
            $stop.Tag | Should -Be 'WARN'
            $stop.Text | Should -Match '^0 of 1 step\(s\) OK, 1 stopped\.'
            (Get-AfGuiTaskOutcome -Kind 'repair' -Result $null -ErrorText 'boom').Tag | Should -Be 'FAIL'
        }
    }
}

Describe 'Last results and Recommended next' {
    It 'reads a saved repair log back, with its steps and Next step lines' {
        InModuleScope AutoFixer {
            $dir = Join-Path $TestDrive 'runs\PC-ABCDEF'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            @(
                'Auto-Fixer 1.3.3 repair log', 'Plan      : 1 step(s), expected 00:15:00', ('-' * 60), 'Restore point: created',
                '[1/1] sfc.exe /scannow', '  Expected  : 00:15:00', '  Actual    : 00:01:53', '  Exit code : 0 (finished)', '  Outcome   : ISSUES',
                '  Result    : Windows Resource Protection found corrupt files but was unable to fix some of them.', '', ('-' * 60),
                'Run end   : 2026-11-18 16:54:32 UTC', 'Next step : SFC could not fix every damaged file. Next: R (DISM RestoreHealth), then S (SFC) again.'
            ) | Set-Content -LiteralPath (Join-Path $dir 'AF-ABCDEF-20261118-165238Z-repair.log') -Encoding UTF8
            $run = Get-AfLastRepairRun -OutputRoot (Join-Path $TestDrive 'runs')
            $run.Finished | Should -BeTrue
            $run.Steps.Count | Should -Be 1
            $run.Steps[0].Key | Should -Be 'SFC'
            $run.Steps[0].Tag | Should -Be 'ISSUES'
            $run.Hints[0] | Should -Match '^SFC could not fix'
            $next = Get-AfGuiNextStep -Steps $run.Steps -Hints $run.Hints
            $next.Count | Should -Be 1
            ($next[0].Queue -join ',') | Should -Be 'RESTORE,SFC'
            Get-AfGuiNextButton -Queue $next[0].Queue | Should -Be 'Run DISM RestoreHealth, then SFC scan'
        }
    }

    It 'turns each hint into the steps it names, or advice only' {
        InModuleScope AutoFixer {
            ((Get-AfGuiNextStep -Steps @() -Hints @('DISM found damage it can repair. Next: R (DISM RestoreHealth), then S (SFC).'))[0].Queue -join ',') | Should -Be 'RESTORE,SFC'
            ((Get-AfGuiNextStep -Steps @() -Hints @('SFC could not run. Restart Windows and try S again.'))[0].Queue -join ',') | Should -Be 'SFC'
            @((Get-AfGuiNextStep -Steps @() -Hints @('An in-place repair install of Windows is the usual next step.'))[0].Queue).Count | Should -Be 0
        }
    }

    It 'adds a double-check when every step went well' {
        InModuleScope AutoFixer {
            $restore = @([pscustomobject]@{ Key = 'RESTORE'; Tag = 'OK'; Result = 'The restore operation completed successfully.' })
            ((Get-AfGuiNextStep -Steps $restore -Hints @())[0].Queue -join ',') | Should -Be 'SFC'
            $fixed = @([pscustomobject]@{ Key = 'SFC'; Tag = 'OK'; Result = 'Windows Resource Protection found corrupt files and successfully repaired them.' })
            (Get-AfGuiNextStep -Steps $fixed -Hints @())[0].Text | Should -Match 'once more'
            $clean = @([pscustomobject]@{ Key = 'SFC'; Tag = 'OK'; Result = 'Windows Resource Protection did not find any integrity violations.' })
            @((Get-AfGuiNextStep -Steps $clean -Hints @())[0].Queue).Count | Should -Be 0
            # A step with problems and no hint suggests nothing rather than guessing.
            (Get-AfGuiNextStep -Steps @([pscustomobject]@{ Key = 'SFC'; Tag = 'FAILED' }) -Hints @()).Count | Should -Be 0
        }
    }

    It 'labels a saved scan with what it covered and found' {
        InModuleScope AutoFixer {
            $model = [pscustomobject]@{ days = 14; machine = [pscustomobject]@{ isAdmin = $true }; findings = @(
                    [pscustomobject]@{ severity = 'Medium' }, [pscustomobject]@{ severity = 'Medium' }, [pscustomobject]@{ severity = 'Low' }, [pscustomobject]@{ severity = 'Low' }) }
            Get-AfReportRunLabel -Run ([pscustomobject]@{ Written = [datetime]'2026-11-18 11:36' }) -Model $model |
                Should -Be '2026-11-18 11:36  Scan, last 14 days, as admin: 4 problem(s) (2 medium, 2 low)'
            $none = [pscustomobject]@{ days = 7; machine = [pscustomobject]@{ isAdmin = $false }; findings = @() }
            Get-AfReportRunLabel -Run ([pscustomobject]@{ Written = [datetime]'2026-11-12 08:58' }) -Model $none |
                Should -Be '2026-11-12 08:58  Scan, last 7 days, not admin: no problems'
            Get-AfReportRunLabel -Run ([pscustomobject]@{ Written = [datetime]'2026-11-12 08:58' }) -Model $null | Should -Match 'cannot be read'
        }
    }
}
