# Printers (raven575 2026-11-10). No real spooler, printer or driver is touched here:
# the check reads fake sources and every fix gets fake operations that only record
# what they were asked to do. A key queue that runs dry fails the test, which proves
# no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    function New-TestSettings([string] $Mode = 'Standard') {
        [pscustomobject]@{ SchemaVersion = 1; Mode = $Mode; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Plain' }
    }

    function New-Check {
        [pscustomobject]@{
            SpoolerState = 'Running'; StartMode = 'Auto'; Crashes = 0; PrintErrors = 0
            Printers = @(
                [pscustomobject]@{ Name = 'Office HP'; Status = 'Ready'; Offline = $false; Default = $true; PortKind = 'Network'; Driver = 'HP Universal'; Jobs = 2; OldestMinutes = 45; ErrorJobs = 0 }
                [pscustomobject]@{ Name = 'Label printer'; Status = 'Offline (set)'; Offline = $true; Default = $false; PortKind = 'USB'; Driver = 'Zebra'; Jobs = 0; OldestMinutes = $null; ErrorJobs = 0 }
            )
            JobCount = 2; SpoolReadable = $true; SpoolFileCount = 4; SpoolBytes = 2048; WindowsManagesDefault = $true
            OtherProcessors = @(); RecoveryRestarts = $false; RecoveryLines = @('FAILURE_ACTIONS :')
        }
    }

    # Fake operations. Calls lists everything they were asked to do, in order.
    function New-FakeOps([string[]] $States = @('Stopped', 'Running'), [int] $StopCode = 0, [int] $StartCode = 0, [bool] $Admin = $true,
        [string[]] $InUse = @('HP Universal', 'Zebra'), [bool] $Domain = $true, [bool] $InUseFails = $false) {
        $calls = [System.Collections.ArrayList]::new()
        $stateQueue = [System.Collections.Queue]::new()
        foreach ($s in $States) { $stateQueue.Enqueue($s) }
        return @{
            Calls          = $calls
            IsAdmin        = { $Admin }.GetNewClosure()
            Sc             = {
                param([string[]] $Arguments)
                [void]$calls.Add('sc ' + ($Arguments -join ' '))
                $code = 0
                if ($Arguments[0] -eq 'stop') { $code = $StopCode }
                elseif ($Arguments[0] -eq 'start') { $code = $StartCode }
                [pscustomobject]@{ ExitCode = $code; Lines = @() }
            }.GetNewClosure()
            GetState       = { if ($stateQueue.Count -gt 1) { $stateQueue.Dequeue() } else { $stateQueue.Peek() } }.GetNewClosure()
            Sleep          = { [void]$calls.Add('sleep') }.GetNewClosure()
            ListSpoolFiles = { @([pscustomobject]@{ FullName = 'C:\spool\00001.SPL' }, [pscustomobject]@{ FullName = 'C:\spool\00001.SHD' }) }
            RemoveFile     = { param($Path) [void]$calls.Add('del ' + $Path) }.GetNewClosure()
            RemoveJobs     = { param($Name) [void]$calls.Add('jobs ' + $Name); [pscustomobject]@{ Found = 2; Left = 0 } }.GetNewClosure()
            SetOffline     = { param($Name, $Value) [void]$calls.Add(('offline {0} {1}' -f $Name, $Value)) }.GetNewClosure()
            SetDefault     = { param($Name) [void]$calls.Add('default ' + $Name); 0 }.GetNewClosure()
            TestPage       = { param($Name) [void]$calls.Add('testpage ' + $Name); 0 }.GetNewClosure()
            GetLegacy      = { $null }
            SetLegacy      = { param($Value) [void]$calls.Add('legacy ' + $Value) }.GetNewClosure()
            RemovePrinter  = { param($Name) [void]$calls.Add('remove printer ' + $Name) }.GetNewClosure()
            GetDrivers     = {
                @('HP Universal', 'Microsoft Print To PDF', 'Old Driver', 'Zebra', 'Universal Print Class Driver',
                    [pscustomobject]@{ Name = 'Inbox Laser'; Inf = 'C:\Windows\System32\DriverStore\FileRepository\ntprint4.inf_amd64_1\ntprint4.inf' })
            }
            RemoveDriver   = { param($Name) [void]$calls.Add('remove driver ' + $Name) }.GetNewClosure()
            RestorePoint   = { [void]$calls.Add('restore point'); [pscustomobject]@{ Ok = $true; Reason = $null } }.GetNewClosure()
            DriversInUse   = { if ($InUseFails) { throw 'Print Spooler not answering' }; $InUse }.GetNewClosure()
            IsDomain       = { $Domain }.GetNewClosure()
            FindShared     = { @([pscustomobject]@{ Path = '\\printsrv\Floor2-Color'; Name = 'Floor2-Color'; Location = 'Floor 2'; Driver = 'HP Universal' }) }
            AddConnection  = { param($Path) [void]$calls.Add('connect ' + $Path) }.GetNewClosure()
            OpenWizard     = { [void]$calls.Add('wizard'); 'proc' }.GetNewClosure()
            HasExited      = { param($Process) $null = $Process; $true }
        }
    }

    function Invoke-Fix([string] $Key, [hashtable] $Ops, [string[]] $Keys = @(), [string] $Mode = 'Standard', $Check = (New-Check), [string] $Text = '') {
        $read = { param($Prompt) $null = $Prompt; $Text }.GetNewClosure()
        $p = @{ K = $Key; O = $Ops; R = (New-KeyReader $Keys); S = (New-TestSettings $Mode); C = $Check; T = $read }
        InModuleScope AutoFixer -Parameters $p { param($K, $O, $R, $S, $C, $T) Invoke-AfPrinterFix -Key $K -Check $C -Settings $S -ReadKey $R -Ops $O -ReadText $T } 6>$null
    }

    # A check with the same printer installed twice (default + '(Copy 1)') on the same network address.
    function New-DuplicateCheck {
        $c = New-Check
        $c.Printers = @(
            [pscustomobject]@{ Name = 'Office HP'; Status = 'Ready'; Offline = $false; Default = $true; PortKind = 'Network'; Driver = 'HP Universal'; Connection = 'aa11'; Jobs = 0; OldestMinutes = $null; ErrorJobs = 0 }
            [pscustomobject]@{ Name = 'Office HP (Copy 1)'; Status = 'Ready'; Offline = $false; Default = $false; PortKind = 'Network'; Driver = 'HP Universal'; Connection = 'aa11'; Jobs = 1; OldestMinutes = 3; ErrorJobs = 0 }
        )
        $c | Add-Member -NotePropertyName Duplicates -NotePropertyValue @([pscustomobject]@{ Names = @('Office HP', 'Office HP (Copy 1)'); Keep = 'Office HP'; Driver = 'HP Universal'; PortKind = 'Network' })
        $c
    }

    # A fake source for the read-only check. The jobs carry a document name and an
    # owner on purpose: the check must never pass them on.
    function New-FakeSource {
        $now = [datetime]'2026-11-10T15:00:00'
        @{
            Service       = { [pscustomobject]@{ State = 'Running'; StartMode = 'Manual' } }
            Printers      = {
                @(
                    [pscustomobject]@{ Name = 'Office HP'; PrinterStatus = 3; WorkOffline = $false; Default = $true; PortName = '192.168.50.30'; DriverName = 'HP Universal' }
                    [pscustomobject]@{ Name = 'Label printer'; PrinterStatus = 3; WorkOffline = $true; Default = $false; PortName = 'USB001'; DriverName = 'Zebra' }
                )
            }
            Jobs          = {
                @(
                    [pscustomobject]@{ Name = 'Office HP, 4'; TimeSubmitted = $now.AddMinutes(-50); StatusMask = 0; Document = 'payroll-2026.xlsx'; Owner = 'jdoe' }
                    [pscustomobject]@{ Name = 'Office HP, 5'; TimeSubmitted = $now.AddMinutes(-5); StatusMask = 2; Document = 'payroll-2026.xlsx'; Owner = 'jdoe' }
                )
            }.GetNewClosure()
            SpoolFiles    = { @([pscustomobject]@{ Length = 1000 }, [pscustomobject]@{ Length = 24 }) }
            Events        = { [pscustomobject]@{ Crashes = 3; PrintErrors = 1; Days = 7 } }
            LegacyDefault = { 1 }
            Processors    = { @('winprint', 'HPZPP6', 'winprint') }
            Recovery      = { @('FAILURE_ACTIONS              : RESTART -- Delay = 60000 milliseconds.') }
        }
    }
}

Describe 'Printer helpers' {
    It 'says what each sc.exe code means and always shows the number' {
        InModuleScope AutoFixer {
            Get-AfSpoolerExitText -Code 0 | Should -Be '0 (done)'
            Get-AfSpoolerExitText -Code 1058 | Should -Match '^1058 .*disabled'
            Get-AfSpoolerExitText -Code 5 | Should -Match 'administrator'
            Get-AfSpoolerExitText -Code 4242 | Should -Match 'net helpmsg 4242'
        }
    }

    It 'names the port kind without showing the port' {
        InModuleScope AutoFixer {
            Get-AfPrinterPortKind -Port 'USB001' | Should -Be 'USB'
            Get-AfPrinterPortKind -Port 'WSD-1b2c' | Should -Be 'WSD'
            Get-AfPrinterPortKind -Port '192.168.1.20' | Should -Be 'Network'
            Get-AfPrinterPortKind -Port 'IP_10.0.0.5' | Should -Be 'Network'
            Get-AfPrinterPortKind -Port '\\server\printer' | Should -Be 'Shared'
            Get-AfPrinterPortKind -Port 'PORTPROMPT:' | Should -Be 'File'
            Get-AfPrinterPortKind -Port 'LPT1:' | Should -Be 'Local'
            Get-AfPrinterPortKind -Port 'TS001' | Should -Be 'Remote'
            Get-AfPrinterPortKind -Port '' | Should -Be 'None'
        }
    }

    It 'finds the printer name in a job name, even when the name has a comma' {
        InModuleScope AutoFixer {
            Get-AfJobPrinterName -Name 'HP LaserJet, 12' | Should -Be 'HP LaserJet'
            Get-AfJobPrinterName -Name 'Office, 2nd floor, 7' | Should -Be 'Office, 2nd floor'
        }
    }

    It 'reports a printer set to Use printer offline before its own state' {
        InModuleScope AutoFixer {
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $true; PrinterStatus = 3 }) | Should -Be 'Offline (set)'
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $false; PrinterStatus = 7 }) | Should -Be 'Offline'
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $false; PrinterStatus = 3 }) | Should -Be 'Ready'
        }
    }

    It 'reports a paused queue as Paused, not Unknown (seen on a real PC 2026-11-12)' {
        InModuleScope AutoFixer {
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $false; PrinterStatus = 2; PrinterState = 1; ExtendedPrinterStatus = 2 }) | Should -Be 'Paused'
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $false; PrinterStatus = 1; PrinterState = 0; ExtendedPrinterStatus = 8 }) | Should -Be 'Paused'
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $true; PrinterStatus = 2; PrinterState = 1 }) | Should -Be 'Offline (set)'
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $false; PrinterStatus = 1; PrinterState = 0; ExtendedPrinterStatus = 9 }) | Should -Be 'Error'
            Get-AfPrinterStatusText -Printer ([pscustomobject]@{ WorkOffline = $false; PrinterStatus = 2 }) | Should -Be 'Unknown'
        }
    }

    It 'tells how to resume a paused printer' {
        $c = New-Check
        $c.Printers[0].Status = 'Paused'
        $s = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C -Mode 'Standard' })
        @($s | Where-Object { $_.Key -eq '-' -and $_.Text -match 'is paused' }).Count | Should -Be 1
    }

    It 'links the scan finding FIX-SPOOLER to Printers in the report' {
        InModuleScope AutoFixer { Get-AfFixText -Fixes @('FIX-SPOOLER') } | Should -Be 'FIX-SPOOLER (main menu 6, Printers: R)'
    }
}

Describe 'Get-AfPrinterCheck' {
    It 'reads the spooler, printers, jobs, spool folder, events and processors' {
        $source = New-FakeSource
        $steps = [System.Collections.ArrayList]::new()
        $onStep = { param($Number, $Count, $Text) $null = $Count, $Text; [void]$steps.Add($Number) }.GetNewClosure()
        $c = InModuleScope AutoFixer -Parameters @{ S = $source; O = $onStep } { param($S, $O) Get-AfPrinterCheck -Source $S -Now ([datetime]'2026-11-10T15:00:00') -OnStep $O }
        $c.SpoolerState | Should -Be 'Running'
        $c.StartMode | Should -Be 'Manual'
        $c.Printers.Count | Should -Be 2
        $hp = $c.Printers | Where-Object Name -eq 'Office HP'
        $hp.Jobs | Should -Be 2
        $hp.OldestMinutes | Should -Be 50
        $hp.ErrorJobs | Should -Be 1
        $hp.PortKind | Should -Be 'Network'
        ($c.Printers | Where-Object Name -eq 'Label printer').Offline | Should -BeTrue
        $c.SpoolFileCount | Should -Be 2
        $c.SpoolBytes | Should -Be 1024
        $c.Crashes | Should -Be 3
        $c.WindowsManagesDefault | Should -BeFalse
        $c.OtherProcessors | Should -Be @('HPZPP6')
        $c.RecoveryRestarts | Should -BeTrue
        $steps | Should -Be @(1, 2, 3, 4, 5, 6)
    }

    It 'never passes on a job''s document name, owner or the port address' {
        $c = InModuleScope AutoFixer -Parameters @{ S = (New-FakeSource) } { param($S) Get-AfPrinterCheck -Source $S }
        $json = $c | ConvertTo-Json -Depth 6
        $json | Should -Not -Match 'payroll'
        $json | Should -Not -Match 'jdoe'
        $json | Should -Not -Match '192\.168\.50\.30'
    }

    It 'says the spool folder could not be checked instead of 0 when it cannot be read' {
        $source = New-FakeSource
        $source.SpoolFiles = { throw 'Access to the path is denied.' }
        $c = InModuleScope AutoFixer -Parameters @{ S = $source } { param($S) Get-AfPrinterCheck -Source $S }
        $c.SpoolReadable | Should -BeFalse
        $c.SpoolFileCount | Should -Be 0
        $text = InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Show-AfPrinterCheck -Check $C -Suggestions @() 6>&1 | Out-String }
        $text | Should -Match 'could not check \(needs administrator\)'
        $text | Should -Not -Match 'Spool folder\s+: 0 file'
    }

    It 'says Not installed when there is no Print Spooler service' {
        $source = New-FakeSource
        $source.Service = { $null }
        $c = InModuleScope AutoFixer -Parameters @{ S = $source } { param($S) Get-AfPrinterCheck -Source $S }
        $c.SpoolerState | Should -Be 'Not installed'
    }
}

Describe 'Get-AfPrinterSuggestion' {
    It 'suggests S and R when the spooler is stopped and starts Manual' {
        $c = New-Check
        $c.SpoolerState = 'Stopped'; $c.StartMode = 'Manual'
        $keys = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C } | ForEach-Object Key)
        $keys | Should -Contain 'S'
        $keys | Should -Contain 'R'
    }

    It 'suggests O for an offline printer, J for old jobs and C for leftover files' {
        $c = New-Check
        $keys = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C } | ForEach-Object Key)
        $keys | Should -Contain 'O'
        $keys | Should -Contain 'J'
        $keys | Should -Not -Contain 'C'
        $c.JobCount = 0
        $keys = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C } | ForEach-Object Key)
        $keys | Should -Contain 'C'
    }

    It 'offers V after crashes only in Technician mode' {
        $c = New-Check
        $c.Crashes = 2
        @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C -Mode 'Standard' } | ForEach-Object Key) | Should -Not -Contain 'V'
        @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C -Mode 'Technician' } | ForEach-Object Key) | Should -Contain 'V'
    }

    It 'says no problems were found on a healthy PC' {
        $c = New-Check
        $c.Printers = @($c.Printers[0])
        $c.Printers[0].Jobs = 0
        $c.SpoolFileCount = 0
        $s = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C })
        $s.Count | Should -Be 1
        $s[0].Text | Should -Be 'No printer problems found.'
    }

    It 'only points to Repair Windows files when the spooler is missing' {
        $c = New-Check
        $c.SpoolerState = 'Not installed'
        $s = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C })
        $s.Count | Should -Be 1
        $s[0].Key | Should -Be '-'
        $s[0].Text | Should -Match 'Repair Windows files'
    }
}

Describe 'Remove-AfPrinterJob' {
    It 'cancels only the jobs of the chosen printer' {
        $removed = [System.Collections.ArrayList]::new()
        $jobs = { @([pscustomobject]@{ Name = 'Office HP, 4' }, [pscustomobject]@{ Name = 'Label printer, 9' }, [pscustomobject]@{ Name = 'Office HP, 5' }) }
        $remove = { param($Job) [void]$removed.Add($Job.Name) }.GetNewClosure()
        $r = InModuleScope AutoFixer -Parameters @{ G = $jobs; R = $remove } { param($G, $R) Remove-AfPrinterJob -PrinterName 'Office HP' -GetJobs $G -RemoveJob $R }
        $r.Found | Should -Be 2
        $r.Left | Should -Be 0
        $removed | Should -Be @('Office HP, 4', 'Office HP, 5')
    }
}

Describe 'Invoke-AfPrinterFix' {
    It 'R changes nothing on N' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'R' -Ops $ops -Keys 'n').Tag | Should -Be 'CANCELLED'
        $ops.Calls.Count | Should -Be 0
    }

    It 'R stops and starts the spooler after Y' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'R' -Ops $ops -Keys 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('sc stop Spooler', 'sc start Spooler')
    }

    It 'R reports a failed stop with its exit code and does not start' {
        $ops = New-FakeOps -StopCode 5
        $r = Invoke-Fix -Key 'R' -Ops $ops -Keys 'y'
        $r.Tag | Should -Be 'FAILED'
        $r.Detail | Should -Match '5 \(access denied'
        $ops.Calls | Should -Be @('sc stop Spooler')
    }

    It 'R reports a disabled spooler honestly when it will not start' {
        $ops = New-FakeOps -StartCode 1058
        $r = Invoke-Fix -Key 'R' -Ops $ops -Keys 'y'
        $r.Tag | Should -Be 'FAILED'
        $r.Detail | Should -Match '1058 \(the service is disabled\)'
    }

    It 'C asks twice and deletes nothing when the second answer is N' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'C' -Ops $ops -Keys 'y', 'n').Tag | Should -Be 'CANCELLED'
        $ops.Calls.Count | Should -Be 0
    }

    It 'C deletes the spool files only while the spooler is stopped' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'C' -Ops $ops -Keys 'y', 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('sc stop Spooler', 'del C:\spool\00001.SPL', 'del C:\spool\00001.SHD', 'sc start Spooler')
    }

    It 'C deletes nothing and never starts it again when the spooler will not stop' {
        $ops = New-FakeOps -States 'Running'
        $r = Invoke-Fix -Key 'C' -Ops $ops -Keys 'y', 'y'
        $r.Tag | Should -Be 'FAILED'
        $r.Detail | Should -Match '30 seconds'
        @($ops.Calls | Where-Object { $_ -like 'del *' }).Count | Should -Be 0
        $ops.Calls | Should -Not -Contain 'sc start Spooler'
        @($ops.Calls | Where-Object { $_ -eq 'sleep' }).Count | Should -Be 30
    }

    It 'needs administrator rights for the spooler fixes and asks nothing without them' {
        $ops = New-FakeOps -Admin $false
        foreach ($key in 'R', 'C', 'J', 'S') { (Invoke-Fix -Key $key -Ops $ops).Tag | Should -Be 'CANCELLED' }
        $ops.Calls.Count | Should -Be 0
    }

    It 'keeps V, M and U for Technician mode' {
        $ops = New-FakeOps
        foreach ($key in 'V', 'M', 'U') { (Invoke-Fix -Key $key -Ops $ops -Mode 'Standard').Detail | Should -Be 'Technician mode only.' }
        $ops.Calls.Count | Should -Be 0
    }

    It 'J cancels the jobs of the printer picked' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'J' -Ops $ops -Keys '1', 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('jobs Office HP')
    }

    It 'O turns Use printer offline off for the printer picked' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'O' -Ops $ops -Keys '1', 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('offline Label printer False')
    }

    It 'D sets the default printer and, only after a second Y, stops Windows from changing it' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'D' -Ops $ops -Keys '2', 'y', 'n').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('default Label printer')
        $ops = New-FakeOps
        (Invoke-Fix -Key 'D' -Ops $ops -Keys '2', 'y', 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('default Label printer', 'legacy 1')
    }

    It 'T sends a test page after Y' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'T' -Ops $ops -Keys '1', 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('testpage Office HP')
    }

    It 'S does nothing when the spooler already starts Automatic, and sets it when it is Manual' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'S' -Ops $ops).Tag | Should -Be 'CANCELLED'
        $ops.Calls.Count | Should -Be 0
        $c = New-Check
        $c.StartMode = 'Manual'
        (Invoke-Fix -Key 'S' -Ops $ops -Keys 'y' -Check $c).Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('sc config Spooler start= auto')
    }

    It 'V sets restart-on-failure in Technician mode' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'V' -Ops $ops -Keys 'y' -Mode 'Technician').Tag | Should -Be 'OK'
        # It reads the setting back afterwards so the log shows the new value.
        $ops.Calls | Should -Be @('sc failure Spooler reset= 86400 actions= restart/60000/restart/60000//', 'sc qfailure Spooler')
    }

    It 'M removes the printer picked in Technician mode' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'M' -Ops $ops -Keys '2', 'y' -Mode 'Technician').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('remove printer Label printer')
    }

    It 'U offers only drivers no printer uses and that are not built into Windows' {
        $ops = New-FakeOps
        # One driver is left (Old Driver): Universal Print Class Driver (name) and Inbox Laser (ntprint4.inf) are
        # built into Windows. 1 picks it, N skips the restore point, Y removes it.
        (Invoke-Fix -Key 'U' -Ops $ops -Keys '1', 'n', 'y' -Mode 'Technician').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('remove driver Old Driver')
        $ops = New-FakeOps
        (Invoke-Fix -Key 'U' -Ops $ops -Keys '1', 'y', 'y' -Mode 'Technician').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('restore point', 'remove driver Old Driver')
    }

    It 'U asks Windows again and never offers a driver a printer uses, even one the check missed' {
        # Seen on a real PC: the check listed 5 printers, Windows had 7, and Old Driver was in use.
        $ops = New-FakeOps -InUse @('HP Universal', 'Zebra', 'Old Driver')
        (Invoke-Fix -Key 'U' -Ops $ops -Mode 'Technician').Tag | Should -Be 'CANCELLED'
        $ops.Calls.Count | Should -Be 0
    }

    It 'U removes nothing when Windows cannot say which drivers are in use' {
        $ops = New-FakeOps -InUseFails $true
        $r = Invoke-Fix -Key 'U' -Ops $ops -Mode 'Technician'
        $r.Tag | Should -Be 'CANCELLED'
        $r.Detail | Should -Match 'Nothing was removed'
        $ops.Calls.Count | Should -Be 0
    }

    It 'P keeps the suggested copy and removes the extra one after its own Y' {
        $ops = New-FakeOps
        # 1 keeps the suggested copy (listed first), Y removes the other.
        $r = Invoke-Fix -Key 'P' -Ops $ops -Keys '1', 'y' -Mode 'Technician' -Check (New-DuplicateCheck)
        $r.Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('remove printer Office HP (Copy 1)')
    }

    It 'P removes nothing on N, and is Technician only' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'P' -Ops $ops -Keys '1', 'n' -Mode 'Technician' -Check (New-DuplicateCheck)).Tag | Should -Be 'CANCELLED'
        (Invoke-Fix -Key 'P' -Ops $ops -Mode 'Standard' -Check (New-DuplicateCheck)).Detail | Should -Be 'Technician mode only.'
        (Invoke-Fix -Key 'P' -Ops $ops -Mode 'Technician').Detail | Should -Be 'No duplicate printers.'
        $ops.Calls.Count | Should -Be 0
    }

    It 'Find in the domain lists shared printers and connects the one picked' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'F' -Ops $ops -Keys '1', 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('connect \\printsrv\Floor2-Color')
        $ops = New-FakeOps -Domain $false
        (Invoke-Fix -Key 'F' -Ops $ops).Detail | Should -Be 'Not in a domain.'
        $ops.Calls.Count | Should -Be 0
    }

    It 'Connect by name takes only a \\server\printer path' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'N' -Ops $ops -Keys 'y' -Text '\\printsrv\Front Desk').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('connect \\printsrv\Front Desk')
        $ops = New-FakeOps
        (Invoke-Fix -Key 'N' -Ops $ops -Text 'http://printsrv/x').Tag | Should -Be 'CANCELLED'
        (Invoke-Fix -Key 'N' -Ops $ops -Text '').Tag | Should -Be 'CANCELLED'
        $ops.Calls.Count | Should -Be 0
    }

    It 'Add a printer wizard opens only after a Y and waits for it to close' {
        $ops = New-FakeOps
        (Invoke-Fix -Key 'W' -Ops $ops -Keys 'n').Tag | Should -Be 'CANCELLED'
        $ops.Calls.Count | Should -Be 0
        (Invoke-Fix -Key 'W' -Ops $ops -Keys 'y').Tag | Should -Be 'OK'
        $ops.Calls | Should -Be @('wizard')
    }
}

Describe 'Duplicate printers' {
    It 'matches network copies by address and USB or WSD copies by name, never different addresses' {
        InModuleScope AutoFixer {
            $p = { param($Name, $Kind, $Driver, $Conn, $Default) [pscustomobject]@{ Name = $Name; PortKind = $Kind; Driver = $Driver; Connection = $Conn; Default = $Default } }
            $list = @(
                (& $p 'Office HP' 'Network' 'HP Universal' 'aa11' $false)
                (& $p 'HP upstairs' 'Network' 'HP Universal' 'aa11' $true)
                (& $p 'Office HP (Copy 1)' 'Network' 'HP Universal' 'bb22' $false)
                (& $p 'Brother PC-FAX v.3.2' 'Other' 'Brother PC-FAX v.3.2' '' $false)
                (& $p 'Brother PC-FAX v.3.2 (Copy 1)' 'Other' 'Brother PC-FAX v.3.2' '' $false)
                (& $p 'Label (redirected 2)' 'Remote' 'Zebra' '' $false)
                (& $p 'Label (redirected 3)' 'Remote' 'Zebra' '' $false)
            )
            $groups = @(Get-AfPrinterDuplicate -Printers $list)
            $groups.Count | Should -Be 2
            $net = @($groups | Where-Object { $_.PortKind -eq 'Network' })[0]
            $net.Names | Should -Be @('HP upstairs', 'Office HP')
            $net.Keep | Should -Be 'HP upstairs'
            $fax = @($groups | Where-Object { $_.PortKind -eq 'Other' })[0]
            $fax.Keep | Should -Be 'Brother PC-FAX v.3.2'
        }
    }

    It 'flags same-name copies at different addresses as possible duplicates only' {
        InModuleScope AutoFixer {
            $p = { param($Name, $Kind, $Driver, $Conn) [pscustomobject]@{ Name = $Name; PortKind = $Kind; Driver = $Driver; Connection = $Conn; Default = $false } }
            $list = @(
                (& $p 'Brother PC-FAX v.3.2' 'Network' 'Brother PC-FAX v.3.2' 'aa11')
                (& $p 'Brother PC-FAX v.3.2 (Copy 1)' 'Network' 'Brother PC-FAX v.3.2' 'bb22')
                (& $p 'Office HP' 'Network' 'HP Universal' 'cc33')
                (& $p 'Office HP (Copy 1)' 'Network' 'HP Universal' 'cc33')
                (& $p 'Shop HP' 'Network' 'HP Universal' 'dd44')
                (& $p 'Lab Canon' 'Network' 'Canon' 'ee55')
                (& $p 'Lab Canon' 'Network' 'Canon' 'ff66')
            )
            $sure = @(Get-AfPrinterDuplicate -Printers $list)
            $sure.Count | Should -Be 1
            $maybe = @(Get-AfPrinterPossibleDuplicate -Printers $list -Sure $sure)
            # Same addresses are sure (not here); no '(Copy n)' or other names are left out.
            $maybe.Count | Should -Be 1
            $maybe[0].Names | Should -Be @('Brother PC-FAX v.3.2', 'Brother PC-FAX v.3.2 (Copy 1)')
            $maybe[0].PSObject.Properties.Name | Should -Not -Contain 'Keep'
        }
    }

    It 'gives advice only for possible duplicates, and P does not touch them' {
        $c = New-Check
        $c | Add-Member -NotePropertyName Duplicates -NotePropertyValue @()
        $c | Add-Member -NotePropertyName PossibleDuplicates -NotePropertyValue @([pscustomobject]@{ Names = @('Fax', 'Fax (Copy 1)'); Driver = 'Fax'; PortKind = 'Network' })
        foreach ($mode in 'Technician', 'Standard') {
            $s = @(InModuleScope AutoFixer -Parameters @{ C = $c; M = $mode } { param($C, $M) Get-AfPrinterSuggestion -Check $C -Mode $M })
            $hit = @($s | Where-Object { $_.Text -match 'different addresses' })
            $hit.Count | Should -Be 1
            $hit[0].Key | Should -Be '-'
        }
        $ops = New-FakeOps
        (Invoke-Fix -Key 'P' -Ops $ops -Mode 'Technician' -Check $c).Detail | Should -Be 'No duplicate printers.'
        $ops.Calls.Count | Should -Be 0
    }

    It 'fingerprints an address without keeping it' {
        InModuleScope AutoFixer {
            $a = Get-AfPrinterConnectionId -Name 'HP' -Port 'IP_10.0.0.5'
            $a | Should -Be (Get-AfPrinterConnectionId -Name 'HP (Copy 1)' -Port '10.0.0.5_1')
            $a | Should -Not -Match '10\.0\.0\.5'
            Get-AfPrinterConnectionId -Name 'Label' -Port 'USB001' | Should -Be ''
            Get-AfPrinterConnectionId -Name '\\srv\HP' -Port 'Ne01:' | Should -Be (Get-AfPrinterConnectionId -Name '\\SRV\hp' -Port 'Ne02:')
        }
    }

    It 'suggests A in Technician mode and gives advice only in Standard' {
        $c = New-DuplicateCheck
        @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C -Mode 'Technician' } | ForEach-Object Key) | Should -Contain 'A'
        $std = @(InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfPrinterSuggestion -Check $C -Mode 'Standard' })
        @($std | ForEach-Object Key) | Should -Not -Contain 'A'
        @($std | Where-Object { $_.Text -match 'installed 2 times' }).Count | Should -Be 1
    }
}

Describe 'Printers menu' {
    BeforeEach { Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue }

    It 'hides the Technician fixes in Standard mode' {
        $check = New-Check
        $get = { param($OnStep) $null = $OnStep; $check }.GetNewClosure()
        $seen = [System.Collections.ArrayList]::new()
        $run = { param($Key, $Check, $Log, $ScreenRedactor) $null = $Check, $Log, $ScreenRedactor; [void]$seen.Add($Key); [pscustomobject]@{ Tag = 'OK'; Detail = 'done' } }.GetNewClosure()
        # Any key after the check, V (unknown here), then Back.
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Standard'); O = (Join-Path $TestDrive 'Runs'); G = $get; F = $run; R = (New-KeyReader 'Enter', 'v', 'b') } {
            param($S, $O, $G, $F, $R)
            Invoke-AfPrinterMenu -Settings $S -OutputRoot $O -GetCheck $G -RunFix $F -ReadKey $R -ClearScreen { }
        } 6>$null
        $seen.Count | Should -Be 0
    }

    It 'runs a Technician fix, checks again and writes a printer log without names' {
        $check = New-Check
        $get = { param($OnStep) $null = $OnStep; $check }.GetNewClosure()
        $seen = [System.Collections.ArrayList]::new()
        $run = { param($Key, $Check, $Log, $ScreenRedactor) $null = $Check, $Log, $ScreenRedactor; [void]$seen.Add($Key); [pscustomobject]@{ Tag = 'OK'; Detail = 'done' } }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician'); O = (Join-Path $TestDrive 'Runs'); G = $get; F = $run; R = (New-KeyReader 'Enter', 'v', 'Enter', 'b') } {
            param($S, $O, $G, $F, $R)
            Invoke-AfPrinterMenu -Settings $S -OutputRoot $O -GetCheck $G -RunFix $F -ReadKey $R -ClearScreen { }
        } 6>$null
        $seen | Should -Be @('V')
        $log = @(Get-ChildItem (Join-Path $TestDrive 'Runs') -Recurse -Filter '*-printer.log')
        $log.Count | Should -Be 1
        $text = Get-Content -LiteralPath $log[0].FullName -Raw
        $text | Should -Match 'OK     V: done'
        $text | Should -Match 'Now: Print Spooler Running'
        $text | Should -Not -Match 'Office HP'
        $text | Should -Not -Match 'Label printer'
    }

    It 'keeps remove tools out of Add or remove printers in Standard mode' {
        $check = New-Check
        $get = { param($OnStep) $null = $OnStep; $check }.GetNewClosure()
        $seen = [System.Collections.ArrayList]::new()
        $run = { param($Key, $Check, $Log, $ScreenRedactor) $null = $Check, $Log, $ScreenRedactor; [void]$seen.Add($Key); [pscustomobject]@{ Tag = 'OK'; Detail = 'done' } }.GetNewClosure()
        # Any key after the check, A, P and M (unknown here), Back to Printers, Back.
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Standard'); O = (Join-Path $TestDrive 'Runs'); G = $get; F = $run; R = (New-KeyReader 'Enter', 'a', 'p', 'm', 'b', 'b') } {
            param($S, $O, $G, $F, $R)
            Invoke-AfPrinterMenu -Settings $S -OutputRoot $O -GetCheck $G -RunFix $F -ReadKey $R -ClearScreen { }
        } 6>$null
        $seen.Count | Should -Be 0
    }

    It 'runs Remove duplicate copies from Add or remove printers, then comes back to that menu' {
        $check = New-DuplicateCheck
        $get = { param($OnStep) $null = $OnStep; $check }.GetNewClosure()
        $seen = [System.Collections.ArrayList]::new()
        $run = { param($Key, $Check, $Log, $ScreenRedactor) $null = $Check, $Log, $ScreenRedactor; [void]$seen.Add($Key); [pscustomobject]@{ Tag = 'OK'; Detail = 'done' } }.GetNewClosure()
        # P runs, any key, P again (only known in Add or remove printers), any key, Back to Printers, Back.
        $out = InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician'); O = (Join-Path $TestDrive 'Runs'); G = $get; F = $run; R = (New-KeyReader 'Enter', 'a', 'p', 'Enter', 'p', 'Enter', 'b', 'b') } {
            param($S, $O, $G, $F, $R)
            Invoke-AfPrinterMenu -Settings $S -OutputRoot $O -GetCheck $G -RunFix $F -ReadKey $R -ClearScreen { }
        } 6>&1 | Out-String
        $seen | Should -Be @('P', 'P')
        $out | Should -Match 'Press any key to return to Add or remove printers\.'
    }

    It 'opens from the main menu with I and with 6' {
        $seen = [System.Collections.ArrayList]::new()
        $printers = { param($Settings) [void]$seen.Add($Settings.Mode) }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } `
            -PrinterAction $printers -ReadKey (New-KeyReader 'Enter', 'i', '6', 'q', 'y') 6>$null
        $seen | Should -Be @('Standard', 'Standard')
    }
}
