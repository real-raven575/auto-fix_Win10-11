# SFC and DISM repairs. No real SFC or DISM runs here: the batch gets a fake runner
# that records each command, and keys come from a queue. A queue that runs dry fails
# the test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    function New-FakeRunner([System.Collections.ArrayList] $Calls, [object[]] $Results = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($r in $Results) { $queue.Enqueue($r) }
        return {
            param($FilePath, $Arguments)
            $null = $Calls.Add(('{0} {1}' -f ($FilePath -replace '^.*\\', ''), $Arguments))
            if ($queue.Count -gt 0) { return $queue.Dequeue() }
            [pscustomobject]@{ Outcome = 'Completed'; ExitCode = 0; Seconds = 2; Messages = @('The operation completed successfully.') }
        }.GetNewClosure()
    }

    function New-BatchParams([string[]] $Queue, [string] $Mode = 'Standard', [bool] $Online = $false, [string[]] $Keys = @()) {
        @{
            Queue        = $Queue
            Settings     = [pscustomobject]@{ SchemaVersion = 1; Mode = $Mode; ShowSensitive = $false; SaveSensitive = $false; Online = $Online }
            OutputRoot   = $script:Runs
            ReadKey      = (New-KeyReader $Keys)
            IsAdmin      = $true
            Redactor     = (New-AfRedactor -Names 'TESTPC-01', 'alice' -Serials 'SN12345678')
            RunStep      = (New-FakeRunner $script:Calls)
            RestorePoint = $script:PointOk
            Restart      = $script:RestartCall
            IsBusy       = { $false }
        }
    }

    # Returns the run object and everything written to the screen.
    function Invoke-TestBatch([hashtable] $P) {
        $output = InModuleScope AutoFixer -Parameters @{ P = $P } { param($P) Invoke-AfRepairBatch @P 6>&1 }
        [pscustomobject]@{
            Run  = @($output | Where-Object { $_.PSObject.Properties['Steps'] })[0]
            Text = (@($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | ForEach-Object { [string]$_.MessageData }) -join "`n"
        }
    }
}

Describe 'Repair step details' {
    It 'adds /LimitAccess to RestoreHealth only while the Online switch is off' {
        InModuleScope AutoFixer {
            Get-AfRepairArgumentList -Key 'RESTORE' -Online $false | Should -Be '/Online /Cleanup-Image /RestoreHealth /LimitAccess'
            Get-AfRepairArgumentList -Key 'RESTORE' -Online $true | Should -Be '/Online /Cleanup-Image /RestoreHealth'
            Get-AfRepairArgumentList -Key 'SCAN' -Online $false | Should -Be '/Online /Cleanup-Image /ScanHealth'
        }
    }

    It 'reads SFC and DISM percentages, including a comma decimal' {
        InModuleScope AutoFixer {
            Get-AfPercent 'Verification 45% complete.' | Should -Be 45
            Get-AfPercent '[=====        12.5%       ]' | Should -Be 12.5
            Get-AfPercent '[=====        12,5%       ]' | Should -Be 12.5
            Get-AfPercent 'Beginning system scan.' | Should -BeNullOrEmpty
            Get-AfPercent 'Used 250% more' | Should -BeNullOrEmpty
        }
    }

    It 'explains the common exit codes' {
        InModuleScope AutoFixer {
            Get-AfExitText 0 | Should -Be '0 (success)'
            Get-AfExitText 3010 | Should -Be '3010 (success, restart needed)'
            Get-AfExitText 740 | Should -Match 'administrator'
            Get-AfExitText -2146498529 | Should -Be '0x800F081F (repair source files could not be found)'
            Get-AfExitText 5 | Should -Be '5 (0x00000005)'
        }
    }

    It 'marks which steps change the PC' {
        InModuleScope AutoFixer {
            @($script:AfRepairSteps.Keys | Where-Object { $script:AfRepairSteps[$_].Changes }) | Should -Be @('SFC', 'RESTORE', 'CLEANUP')
        }
    }

    It 'calls taskkill and shutdown by their full path in System32 or Sysnative' {
        InModuleScope AutoFixer {
            Get-AfSystemToolPath 'taskkill.exe' | Should -Match '^[A-Za-z]:\\.+\\(System32|Sysnative)\\taskkill\.exe$'
        }
        $source = Get-Content (Join-Path $PSScriptRoot '..\AutoFixer\Fixes\SystemFiles.ps1') -Raw
        $source | Should -Not -Match "-FilePath\s+'(taskkill|shutdown)\.exe'"
        $source | Should -Not -Match '&\s*(taskkill|shutdown)(\.exe)?\s'
        $source | Should -Match "Get-AfSystemToolPath 'taskkill\.exe'"
        $source | Should -Match "Get-AfSystemToolPath 'shutdown\.exe'"
    }
}

Describe 'Time estimates and history' {
    BeforeEach {
        Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue
        $script:History = Join-Path $TestDrive 'repair-history.csv'
    }

    It 'uses the step default when there is no history' {
        InModuleScope AutoFixer -Parameters @{ H = $script:History } {
            param($H)
            Get-AfRepairEstimate -Key 'SFC' -HistoryPath $H | Should -Be 900
        }
    }

    It 'averages the last 5 clean runs and ignores failed ones' {
        InModuleScope AutoFixer -Parameters @{ H = $script:History } {
            param($H)
            foreach ($s in 100, 200, 300, 400, 500, 600) { Add-AfRepairHistory -HistoryPath $H -Key 'SFC' -Seconds $s -ExitCode 0 }
            Add-AfRepairHistory -HistoryPath $H -Key 'SFC' -Seconds 9000 -ExitCode 5
            Add-AfRepairHistory -HistoryPath $H -Key 'SCAN' -Seconds 9000 -ExitCode 0
            Get-AfRepairEstimate -Key 'SFC' -HistoryPath $H | Should -Be 400
        }
    }

    It 'stores only the step, seconds, exit code and date' {
        InModuleScope AutoFixer -Parameters @{ H = $script:History } {
            param($H)
            Add-AfRepairHistory -HistoryPath $H -Key 'CHECK' -Seconds 42 -ExitCode 0
            (Get-Content -LiteralPath $H)[0] | Should -Be '"Step","Seconds","ExitCode","Date"'
            Get-Content -LiteralPath $H -Raw | Should -Not -Match ([regex]::Escape([Environment]::MachineName))
        }
    }
}

Describe 'Watchdog and plan questions' {
    It 'stops a stalled step only on S, and keeps waiting otherwise' {
        InModuleScope AutoFixer -Parameters @{ S = (New-KeyReader 's'); W = (New-KeyReader 'W'); Lost = (New-KeyReader 'x', 'Enter') } {
            param($S, $W, $Lost)
            Read-AfStallChoice -ReadKey $S 6>$null | Should -Be 'Stop'
            Read-AfStallChoice -ReadKey $W 6>$null | Should -Be 'Wait'
            Read-AfStallChoice -ReadKey $Lost 6>$null | Should -Be 'Wait'
        }
    }

    It 'starts a Technician plan only on Enter' {
        InModuleScope AutoFixer -Parameters @{ Go = (New-KeyReader 'Enter'); Back = (New-KeyReader 'Escape'); Retry = (New-KeyReader 'x', 'Enter'); Lost = (New-KeyReader 'x', 'y') } {
            param($Go, $Back, $Retry, $Lost)
            Confirm-AfRepairPlan -ReadKey $Go 6>$null | Should -BeTrue
            Confirm-AfRepairPlan -ReadKey $Back 6>$null | Should -BeFalse
            Confirm-AfRepairPlan -ReadKey $Retry 6>$null | Should -BeTrue
            Confirm-AfRepairPlan -ReadKey $Lost 6>$null | Should -BeFalse
        }
    }
}

Describe 'Invoke-AfRepairBatch' {
    BeforeEach {
        Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue
        $script:Runs = Join-Path $TestDrive 'Runs'
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Points = [System.Collections.ArrayList]::new()
        $script:Restarts = [System.Collections.ArrayList]::new()
        $points = $script:Points
        $restarts = $script:Restarts
        $script:PointOk = { $null = $points.Add('point'); [pscustomobject]@{ Ok = $true; Reason = $null } }.GetNewClosure()
        $script:PointFails = { $null = $points.Add('point'); [pscustomobject]@{ Ok = $false; Reason = 'System Protection is off.' } }.GetNewClosure()
        $script:RestartCall = { $null = $restarts.Add('restart') }.GetNewClosure()
    }

    It 'skips every step without administrator rights' {
        $p = New-BatchParams -Queue 'SFC', 'CHECK'
        $p.IsAdmin = $false
        $out = Invoke-TestBatch $p
        $script:Calls.Count | Should -Be 0
        @($out.Run.Steps | ForEach-Object Tag) | Should -Be @('SKIPPED', 'SKIPPED')
        $out.Text | Should -Match 'Skipped: SFC scan needs administrator rights'
    }

    It 'starts a read-only step without any question' {
        $out = Invoke-TestBatch (New-BatchParams -Queue 'CHECK')
        $script:Calls | Should -Be @('dism.exe /Online /Cleanup-Image /CheckHealth')
        $script:Points.Count | Should -Be 0
        $out.Run.Steps[0].Tag | Should -Be 'OK'
    }

    It 'asks Y/N in Standard mode before a step that changes the PC' {
        $out = Invoke-TestBatch (New-BatchParams -Queue 'SFC' -Keys 'n')
        $script:Calls.Count | Should -Be 0
        $out.Run.Stopped | Should -BeTrue
        $out.Text | Should -Match 'This changes your PC'

        $out = Invoke-TestBatch (New-BatchParams -Queue 'SFC' -Keys 'y', 'y')
        $script:Calls | Should -Be @('sfc.exe /scannow')
        $script:Points.Count | Should -Be 1
    }

    It 'asks before each changing step in Standard mode, and offers the restore point once' {
        Invoke-TestBatch (New-BatchParams -Queue 'SFC', 'CHECK', 'SFC' -Keys 'y', 'y', 'y') | Out-Null
        $script:Calls.Count | Should -Be 3
        $script:Points.Count | Should -Be 1
    }

    It 'asks whether to go on when the restore point fails' {
        $p = New-BatchParams -Queue 'SFC' -Keys 'y', 'y', 'n'
        $p.RestorePoint = $script:PointFails
        $out = Invoke-TestBatch $p
        $script:Calls.Count | Should -Be 0
        $out.Text | Should -Match 'No restore point: System Protection is off'

        $p = New-BatchParams -Queue 'SFC' -Keys 'y', 'y', 'y'
        $p.RestorePoint = $script:PointFails
        Invoke-TestBatch $p | Out-Null
        $script:Calls.Count | Should -Be 1
    }

    It 'shows one plan screen in Technician mode and runs the whole list after Enter' {
        $out = Invoke-TestBatch (New-BatchParams -Queue 'SFC', 'CHECK', 'SCAN', 'RESTORE', 'CLEANUP', 'SFC' -Mode 'Technician' -Keys 'Enter', 'n')
        $script:Calls.Count | Should -Be 6
        $out.Text | Should -Match 'These steps change this PC'
        @($out.Run.Steps | ForEach-Object Tag) | Should -Be @('OK', 'OK', 'OK', 'OK', 'OK', 'OK')
    }

    It 'starts nothing in Technician mode on Esc or a stray key' {
        Invoke-TestBatch (New-BatchParams -Queue 'RESTORE' -Mode 'Technician' -Keys 'Escape') | Out-Null
        Invoke-TestBatch (New-BatchParams -Queue 'CLEANUP' -Mode 'Technician' -Keys 'r', 'c') | Out-Null
        $script:Calls.Count | Should -Be 0
    }

    It 'keeps RestoreHealth local with the Online switch off' {
        $out = Invoke-TestBatch (New-BatchParams -Queue 'RESTORE' -Keys 'y', 'n')
        $script:Calls | Should -Be @('dism.exe /Online /Cleanup-Image /RestoreHealth /LimitAccess')
        $out.Text | Should -Not -Match 'Windows Update'
        $out.Run.Online | Should -BeFalse
    }

    It 'announces Windows Update before RestoreHealth connects, and asks in Standard mode' {
        $out = Invoke-TestBatch (New-BatchParams -Queue 'RESTORE' -Online $true -Keys 'y', 'n', 'y')
        $script:Calls | Should -Be @('dism.exe /Online /Cleanup-Image /RestoreHealth')
        $out.Text | Should -Match 'Connecting to Windows Update \(Microsoft\)'
        $out.Run.Online | Should -BeTrue
        Get-Content -LiteralPath $out.Run.LogPath -Raw | Should -Match 'Internet  : Windows Update \(Microsoft\)'

        $script:Calls.Clear()
        Invoke-TestBatch (New-BatchParams -Queue 'RESTORE' -Online $true -Keys 'y', 'n', 'n') | Out-Null
        $script:Calls | Should -Be @('dism.exe /Online /Cleanup-Image /RestoreHealth /LimitAccess')
    }

    It 'announces Windows Update in Technician mode without asking again' {
        $out = Invoke-TestBatch (New-BatchParams -Queue 'RESTORE' -Mode 'Technician' -Online $true -Keys 'Enter', 'n')
        $script:Calls | Should -Be @('dism.exe /Online /Cleanup-Image /RestoreHealth')
        $out.Text | Should -Match 'Connecting to Windows Update \(Microsoft\)'
    }

    It 'explains how to go online when RestoreHealth has no local source' {
        $p = New-BatchParams -Queue 'RESTORE' -Keys 'y', 'n'
        $p.RunStep = New-FakeRunner $script:Calls @([pscustomobject]@{ Outcome = 'Completed'; ExitCode = -2146498529; Seconds = 5; Messages = @('Error: 0x800f081f') })
        $out = Invoke-TestBatch $p
        $out.Run.Steps[0].Tag | Should -Be 'FAILED'
        $out.Text | Should -Match 'Go online when a step needs it'
    }

    It 'writes a redacted log under the run folder, named by time only' {
        $p = New-BatchParams -Queue 'CHECK'
        $p.RunStep = New-FakeRunner $script:Calls @([pscustomobject]@{ Outcome = 'Completed'; ExitCode = 0; Seconds = 5; Messages = @('Checked on TESTPC-01 by alice, serial SN12345678.', 'No component store corruption detected.') })
        $out = Invoke-TestBatch $p
        $log = $out.Run.LogPath
        $log | Should -BeLike (Join-Path $script:Runs '*')
        Split-Path (Split-Path $log -Parent) -Leaf | Should -Match '^\d{8}-\d{6}$'
        Split-Path $log -Leaf | Should -Be 'repair.log'
        $text = Get-Content -LiteralPath $log -Raw
        $text | Should -Not -Match 'TESTPC-01|alice|SN12345678'
        $text | Should -Match 'Exit code : 0 \(success\)'
        $text | Should -Match '<NAME-\d>'
        $out.Text | Should -Not -Match 'TESTPC-01|alice|SN12345678'
        Get-Content -LiteralPath (Join-Path $script:Runs 'repair-history.csv') -Raw | Should -Not -Match 'TESTPC-01|alice'
    }

    It 'skips the remaining steps after a step is stopped at the watchdog' {
        $p = New-BatchParams -Queue 'CHECK', 'SCAN'
        $p.RunStep = New-FakeRunner $script:Calls @([pscustomobject]@{ Outcome = 'Stopped'; ExitCode = $null; Seconds = 600; Messages = @() })
        $out = Invoke-TestBatch $p
        $script:Calls.Count | Should -Be 1
        @($out.Run.Steps | ForEach-Object Tag) | Should -Be @('STOPPED', 'SKIPPED')
        $out.Run.Stopped | Should -BeTrue
    }

    It 'warns when another SFC or DISM is already running' {
        $p = New-BatchParams -Queue 'CHECK'
        $p.IsBusy = { $true }
        (Invoke-TestBatch $p).Text | Should -Match 'Another SFC or DISM is already running'
    }

    It 'offers a restart only when a step needs one' {
        $restart = [pscustomobject]@{ Outcome = 'Completed'; ExitCode = 3010; Seconds = 5; Messages = @('The restore operation completed successfully.') }
        $p = New-BatchParams -Queue 'RESTORE' -Keys 'y', 'n', 'y'
        $p.RunStep = New-FakeRunner $script:Calls @($restart)
        Invoke-TestBatch $p | Out-Null
        $script:Restarts.Count | Should -Be 1

        $p = New-BatchParams -Queue 'RESTORE' -Mode 'Technician' -Keys 'Enter', 'n', 'x'
        $p.RunStep = New-FakeRunner $script:Calls @($restart)
        Invoke-TestBatch $p | Out-Null
        $script:Restarts.Count | Should -Be 1

        Invoke-TestBatch (New-BatchParams -Queue 'CHECK') | Out-Null
        $script:Restarts.Count | Should -Be 1
    }
}

Describe 'Invoke-AfRepairProcess' {
    BeforeAll { $script:Shell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe' }

    It 'reads output and percentages and returns the exit code' -Skip:(-not $script:OnWindows) {
        InModuleScope AutoFixer -Parameters @{ Shell = $script:Shell } {
            param($Shell)
            $seen = [System.Collections.ArrayList]::new()
            $r = Invoke-AfRepairProcess -FilePath $Shell -Arguments '-NoProfile -Command "Write-Output ''Verification 50% complete.''; Write-Output ''done here''; exit 3"' `
                -OnProgress { param($Percent) $null = $seen.Add($Percent) }
            $r.Outcome | Should -Be 'Completed'
            $r.ExitCode | Should -Be 3
            $r.Messages | Should -Contain 'done here'
            $r.Messages | Should -Not -Contain 'Verification 50% complete.'
        }
    }

    It 'asks at a stall, keeps waiting on W, and stops the process only on S' -Skip:(-not $script:OnWindows) {
        InModuleScope AutoFixer -Parameters @{ Shell = $script:Shell } {
            param($Shell)
            $answers = [System.Collections.Queue]::new(@('Wait', 'Stop'))
            $asked = [System.Collections.ArrayList]::new()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-AfRepairProcess -FilePath $Shell -Arguments '-NoProfile -Command "Start-Sleep -Seconds 60"' `
                -StallSeconds 2 -ProbeSeconds 1 -ActivityProbe { 'same' } -OnStall { $null = $asked.Add(1); $answers.Dequeue() }
            $r.Outcome | Should -Be 'Stopped'
            $r.ExitCode | Should -BeNullOrEmpty
            $asked.Count | Should -Be 2
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        }
    }
}

Describe 'Repair menu' {
    BeforeEach {
        $script:Batches = [System.Collections.ArrayList]::new()
        $batches = $script:Batches
        $script:Batch = { param([string[]] $Queue) $null = $batches.Add($Queue -join ',') }.GetNewClosure()
        $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false }
    }

    It 'runs one step by its letter and the full list with A' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'Runs'); B = $script:Batch; Keys = (New-KeyReader 'k', 'Enter', 'A', 'Enter', 'Down', 'Down', 'Enter', 'Enter', 'b') } {
            param($S, $Root, $B, $Keys)
            Invoke-AfRepairMenu -Settings $S -OutputRoot $Root -RunBatch $B -ReadKey $Keys 6>$null
        }
        $script:Batches | Should -Be @('CHECK', 'SFC,CHECK,SCAN,RESTORE,CLEANUP,SFC', 'SFC')
    }

    It 'opens from main menu item 4 with the saved settings' {
        $seen = [System.Collections.ArrayList]::new()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } `
            -RepairAction { param($Settings) $null = $seen.Add($Settings.Mode) }.GetNewClosure() -ReadKey (New-KeyReader 'Enter', '4', 'q') 6>$null
        $seen | Should -Be @('Standard')
    }
}

Describe 'Online switch in Settings' {
    BeforeEach { Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue }

    It 'turns on only after Y, and off without a prompt' {
        $path = Join-Path $TestDrive 'settings.json'
        $runs = Join-Path $TestDrive 'Runs'
        Invoke-AfMainMenu -SettingsPath $path -OutputRoot $runs -ScanAction { } -ReadKey (New-KeyReader 'Enter', '3', '4', 'n', 'b', 'q') 6>$null
        (Read-AfSettings -Path $path).Online | Should -BeFalse
        Invoke-AfMainMenu -SettingsPath $path -OutputRoot $runs -ScanAction { } -ReadKey (New-KeyReader '3', '4', 'y', 'b', 'q') 6>$null
        (Read-AfSettings -Path $path).Online | Should -BeTrue
        Invoke-AfMainMenu -SettingsPath $path -OutputRoot $runs -ScanAction { } -ReadKey (New-KeyReader '3', '4', 'b', 'q') 6>$null
        (Read-AfSettings -Path $path).Online | Should -BeFalse
    }
}
