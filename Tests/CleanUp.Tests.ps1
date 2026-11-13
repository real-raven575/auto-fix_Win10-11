# Clean up: the tick-box screen, Optimize drives and Disk Cleanup. Nothing real runs
# here: defrag, cleanmgr, fsutil and the registry are fakes that record each call, and
# keys come from a queue. A queue that runs dry fails the test, which proves no extra
# question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    # A registry in a hashtable: 'path|name' = value. Calls records each Set and Remove.
    function New-FakeRegistry([hashtable] $Store, [System.Collections.ArrayList] $Calls) {
        return @{
            Get    = { param($Path, $Name) $Store[('{0}|{1}' -f $Path, $Name)] }.GetNewClosure()
            Set    = { param($Path, $Name, $Value) $Store[('{0}|{1}' -f $Path, $Name)] = $Value; $null = $Calls.Add(('set {0} {1}' -f ($Path -split '\\')[-1], $Name)) }.GetNewClosure()
            Remove = { param($Path, $Name) $Store.Remove(('{0}|{1}' -f $Path, $Name)); $null = $Calls.Add(('remove {0} {1}' -f ($Path -split '\\')[-1], $Name)) }.GetNewClosure()
        }
    }

    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Tech = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Technician'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Cache = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
}

Describe 'Format-AfSize' {
    It 'shows bytes in the largest unit that fits' {
        InModuleScope AutoFixer {
            Format-AfSize 0 | Should -Be '0 B'
            Format-AfSize 1536 | Should -Be '1.5 KB'
            Format-AfSize (3.4 * 1GB) | Should -Be '3.4 GB'
            Format-AfSize (250 * 1MB) | Should -Be '250 MB'
            Format-AfSize $null | Should -Be 'size not known'
            # Rounds down like Explorer: a 498,948,108,288-byte drive is 464.68 GB, shown as 464 GB.
            Format-AfSize 498948108288 | Should -Be '464 GB'
            Format-AfSize 344479309824 | Should -Be '320 GB'
            Format-AfSize (22.69 * 1GB) | Should -Be '22.6 GB'
            Format-AfSize 1023 | Should -Be '1023 B'
        }
    }
}

Describe 'Select-AfCheckList' {
    BeforeEach {
        $script:Items = @(
            @{ Key = 'a'; Label = 'Temporary files'; Size = 100; Checked = $true; Warn = 0 }
            @{ Key = 'b'; Label = 'Recycle Bin'; Size = 50; Checked = $false; Warn = 2; Note = 'Deleted for good.' }
            @{ Key = 'c'; Label = 'Error reports'; Size = $null; Checked = $false; Warn = 0; Locked = 'Locked: the scan reads these.' }
            @{ Key = 'd'; Label = 'Shader cache'; Size = $null; Checked = $false; Warn = 0 }
        )
    }

    It 'ticks with numbers and Space, and returns only the ticked items' {
        $r = InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader '1', '2', 'Down', ' ', 'Enter') } {
            param($Items, $Keys) Select-AfCheckList -Title 't' -Items $Items -ReadKey $Keys 6>$null
        }
        $r.Action | Should -Be 'Continue'
        @($r.Items | ForEach-Object { $_.Key }) | Should -Be @('b')
    }

    It 'never ticks a locked item, and A skips items with a warning' {
        $r = InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader '3', 'n', 'a', 'Enter') } {
            param($Items, $Keys) Select-AfCheckList -Title 't' -Items $Items -ReadKey $Keys 6>$null
        }
        @($r.Items | ForEach-Object { $_.Key }) | Should -Be @('a', 'd')
    }

    It 'will not go on with nothing ticked, and Esc goes back' {
        $r = InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader 'n', 'Enter', 'Escape') } {
            param($Items, $Keys) Select-AfCheckList -Title 't' -Items $Items -ReadKey $Keys 6>$null
        }
        $r.Action | Should -Be 'Back'
    }

    It 'quits only after Y' {
        $r = InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader 'q', 'n', 'q', 'y') } {
            param($Items, $Keys) Select-AfCheckList -Title 't' -Items $Items -ReadKey $Keys 6>$null
        }
        $r.Action | Should -Be 'Quit'
    }

    It 'adds up known sizes and counts the unknown ones' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items } {
            param($Items)
            $Items[3].Checked = $true
            $t = Get-AfCheckListTotal -Items $Items
            $t.Bytes | Should -Be 100
            $t.Unknown | Should -Be 1
        }
    }

    It 'scrolls a long list and keeps every line inside 80 columns' {
        $long = @(for ($i = 0; $i -lt 25; $i++) { @{ Key = "k$i"; Label = ('Item {0} with a very long name that must be cut short here' -f $i); Size = 1GB; Checked = $false; Warn = 2 } })
        $out = InModuleScope AutoFixer -Parameters @{ Items = $long; Keys = (New-KeyReader (@('Down') * 20 + @(' ', 'Enter'))) } {
            param($Items, $Keys) Select-AfCheckList -Title 't' -Items $Items -ReadKey $Keys 6>&1
        }
        # Write-Host records carry NoNewLine; rebuild the screen lines from them.
        $text = -join @($out | ForEach-Object { [string]$_.MessageData; if (-not $_.MessageData.NoNewLine) { "`n" } })
        $lines = @($text -split "`n" | Where-Object { $_ -match '\[[ x-]\]|Ticked|Space/number|more (above|below)' })
        $lines.Count | Should -BeGreaterThan 8
        foreach ($line in $lines) { $line.TrimEnd().Length | Should -BeLessOrEqual 79 -Because $line }
        $text | Should -Match 'more above'
    }

    It 'picks items 10 and up with two digits, and a single digit then Space' {
        $twelve = @(for ($i = 0; $i -lt 12; $i++) { @{ Key = "k$i"; Label = "Item $i"; Size = 1KB; Checked = $false; Warn = 0 } })
        $r = InModuleScope AutoFixer -Parameters @{ Items = $twelve; Keys = (New-KeyReader '1', '2', '1', ' ', '5', 'Enter') } {
            param($Items, $Keys) Select-AfCheckList -Title 't' -Items $Items -ReadKey $Keys 6>$null
        }
        # 1 2 = item 12; 1 Space = item 1; 5 = item 5 at once (50 is past the end).
        @($r.Items | ForEach-Object { $_.Key }) | Should -Be @('k0', 'k4', 'k11')
    }

    It 'draws the Branded list as one grid per key, never clearing the screen' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader 'Down', 'Down', 'Escape') } {
            param($Items, $Keys)
            Mock Get-AfDisplay { [pscustomobject]@{ Style = 'Branded'; Color = 'Vt'; Tile = $true } }
            Mock Write-AfScreen { }
            Mock Clear-AfScreen { }
            $null = Select-AfCheckList -Title 'Disk Cleanup' -Items $Items -ReadKey $Keys 6>$null
            Should -Invoke Write-AfScreen -Times 3 -Exactly
            Should -Invoke Clear-AfScreen -Times 0 -Exactly
        }
    }

    It 'fits the Branded list in the frame with a number on every row' {
        $long = @(for ($i = 0; $i -lt 14; $i++) {
                $group = 'Your files'
                if ($i -ge 7) { $group = 'System files' }
                @{ Key = "k$i"; Label = ('Item {0} with a very long name that must be cut short here' -f $i); Size = 1GB; Checked = $false; Warn = 2; Group = $group; Note = ('A note long enough to need two lines on the screen, so it wraps under the list and the total stays put. {0}' -f $i) }
            })
        InModuleScope AutoFixer -Parameters @{ Items = $long } {
            param($Items)
            $d = [pscustomobject]@{ Style = 'Branded'; Color = 'Vt'; Tile = $true }
            $lines = @(Get-AfCheckListLine -Items $Items)
            $top = Get-AfCheckListWindow -Lines $lines -Index 12 -Top 0 -Height 8
            $screen = New-AfCheckListScreen -Display $d -Title 'Disk Cleanup' -Items $Items -Index 12 -Top $top -Info @('Tick what to remove.')
            $rows = @(for ($r = 1; $r -le 24; $r++) { -join $screen.Ch[$r][1..79] })
            for ($r = 1; $r -le 25; $r++) { $screen.Ch[$r][1] | Should -Be ' '; $screen.Ch[$r][80] | Should -Be ' ' }
            ($rows -join "`n") | Should -Match ([regex]::Escape(([string]$script:AfGlyph.Pointer) + ' 13 [ ] Item 12'))
            $rows[7] | Should -Match 'more above'
            $rows[19] | Should -Match 'Ticked: 0 B'
            $rows[22] | Should -Match '\[Space\]Tick'
            $rows[23] | Should -Match 'Number = tick'
        }
    }
}

Describe 'Optimize drives' {
    It 'drops the volume label defrag prints, keeping the letter' {
        InModuleScope AutoFixer {
            Format-AfDefragLine -Text 'Invoking retrim on GAMES 1TB (G:)...' | Should -Be 'Invoking retrim on (G:)...'
            Format-AfDefragLine -Text 'Invoking defragmentation on (C:)...' | Should -Be 'Invoking defragmentation on (C:)...'
            Format-AfDefragLine -Text 'Total space trimmed = 98.72 GB' | Should -Be 'Total space trimmed = 98.72 GB'
        }
    }

    It 'never offers a defrag to an SSD or a drive of unknown type' {
        InModuleScope AutoFixer {
            Get-AfDriveAction -Media 'SSD' | Should -Be 'TRIM'
            Get-AfDriveAction -Media 'Unknown' | Should -Be 'TRIM'
            Get-AfDriveAction -Media 'HDD' | Should -Be 'DEFRAG'
        }
    }

    It 'lists only fixed NTFS and ReFS drives with a letter' {
        $volumes = @(
            [pscustomobject]@{ DriveLetter = 'C'; DriveType = 'Fixed'; FileSystem = 'NTFS'; Size = 100GB; SizeRemaining = 40GB }
            [pscustomobject]@{ DriveLetter = 'E'; DriveType = 'Removable'; FileSystem = 'FAT32'; Size = 8GB; SizeRemaining = 1GB }
            [pscustomobject]@{ DriveLetter = $null; DriveType = 'Fixed'; FileSystem = 'NTFS'; Size = 1GB; SizeRemaining = 1GB }
            [pscustomobject]@{ DriveLetter = 'D'; DriveType = 'Fixed'; FileSystem = 'ReFS'; Size = 2TB; SizeRemaining = 1TB }
        )
        $drives = @(InModuleScope AutoFixer -Parameters @{ V = $volumes } {
                param($V) Get-AfDriveList -GetVolumes { $V }.GetNewClosure() -GetMedia { param($Letter) if ($Letter -eq 'C') { 'SSD' } else { 'HDD' } }
            })
        @($drives | ForEach-Object Letter) | Should -Be @('C', 'D')
        $drives[0].Media | Should -Be 'SSD'
    }

    It 'reads whether TRIM is on from fsutil' {
        InModuleScope AutoFixer {
            Get-AfTrimEnabled -RunTool { [pscustomobject]@{ ExitCode = 0; Lines = @('NTFS DisableDeleteNotify = 0  (Allows TRIM operations to be sent to the storage device)', 'ReFS DisableDeleteNotify = 0') } } | Should -BeTrue
            Get-AfTrimEnabled -RunTool { [pscustomobject]@{ ExitCode = 0; Lines = @('NTFS DisableDeleteNotify = 1') } } | Should -BeFalse
            Get-AfTrimEnabled -RunTool { [pscustomobject]@{ ExitCode = 1; Lines = @('Error') } } | Should -BeNullOrEmpty
        }
    }

    It 'runs defrag /L for an SSD only after Y, and nothing on N' {
        $calls = [System.Collections.ArrayList]::new()
        $run = { param($FilePath, $Arguments, $EstimatedSeconds, $OnProgress, $OnMessage, $OnStall) $null = $calls.Add(('{0} {1}' -f (Split-Path $FilePath -Leaf), $Arguments)); & $OnProgress 50 $true 1 1 0; [pscustomobject]@{ Outcome = 'Completed'; ExitCode = 0; Seconds = 3; Messages = @() } }.GetNewClosure()
        $ssd = [pscustomobject]@{ Letter = 'C'; Media = 'SSD'; Size = 100GB; Free = 40GB }
        InModuleScope AutoFixer -Parameters @{ D = $ssd; S = $script:Settings; Run = $run; Root = (Join-Path $TestDrive 'Runs'); Keys = (New-KeyReader 'n', 'y') } {
            param($D, $S, $Run, $Root, $Keys)
            (Invoke-AfDriveOptimize -Drive $D -Settings $S -OutputRoot $Root -ReadKey $Keys -RunStep $Run -OnBattery $false 6>$null).Tag | Should -Be 'CANCELLED'
            (Invoke-AfDriveOptimize -Drive $D -Settings $S -OutputRoot $Root -ReadKey $Keys -RunStep $Run -OnBattery $false 6>$null).Tag | Should -Be 'OK'
        }
        $calls | Should -Be @('defrag.exe C: /L /U /V')
        $log = Get-ChildItem (Join-Path $TestDrive 'Runs') -Recurse -Filter '*-cleanup.log' | Select-Object -First 1
        (Get-Content $log.FullName -Raw) | Should -Match 'defrag.exe C: /L'
    }

    It 'runs defrag /D for a hard drive and warns on battery' {
        $calls = [System.Collections.ArrayList]::new()
        $run = { param($FilePath, $Arguments) $null = $calls.Add($Arguments); [pscustomobject]@{ Outcome = 'Completed'; ExitCode = 0; Seconds = 3; Messages = @() } }.GetNewClosure()
        $hdd = [pscustomobject]@{ Letter = 'D'; Media = 'HDD'; Size = 2TB; Free = 1TB }
        $out = InModuleScope AutoFixer -Parameters @{ D = $hdd; S = $script:Settings; Run = $run; Root = (Join-Path $TestDrive 'Runs'); Keys = (New-KeyReader 'y') } {
            param($D, $S, $Run, $Root, $Keys)
            Invoke-AfDriveOptimize -Drive $D -Settings $S -OutputRoot $Root -ReadKey $Keys -RunStep $Run -OnBattery $true 6>&1
        }
        $calls | Should -Be @('D: /D /U /V')
        (($out | ForEach-Object { [string]$_.MessageData }) -join ' ') | Should -Match 'on battery'
    }

    It 'shows the Technician items only in Technician mode, and asks for admin rights before a run' {
        $drives = { @([pscustomobject]@{ Letter = 'C'; Media = 'SSD'; Size = 100GB; Free = 40GB }) }
        $ran = [System.Collections.ArrayList]::new()
        $optimize = { param($Drive) $null = $ran.Add($Drive.Letter) }.GetNewClosure()
        $enable = { $null = $ran.Add('trim on') }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; T = $script:Tech; G = $drives; O = $optimize; E = $enable; Root = $TestDrive; K1 = (New-KeyReader 'e', 'b'); K2 = (New-KeyReader 'e', 'x', '1', 'x', 'b'); K3 = (New-KeyReader '1', 'b') } {
            param($S, $T, $G, $O, $E, $Root, $K1, $K2, $K3)
            # Standard: E is not an item, so it is an unknown key.
            Invoke-AfOptimizeMenu -Settings $S -OutputRoot $Root -ReadKey $K1 -GetDrives $G -GetTrim { $false } -GetTaskState { 'Ready' } -IsAdmin $true -Optimize $O -EnableTrim $E 6>$null
            Invoke-AfOptimizeMenu -Settings $T -OutputRoot $Root -ReadKey $K2 -GetDrives $G -GetTrim { $false } -GetTaskState { 'Ready' } -IsAdmin $true -Optimize $O -EnableTrim $E 6>$null
            Invoke-AfOptimizeMenu -Settings $S -OutputRoot $Root -ReadKey $K3 -GetDrives $G -GetTrim { $true } -GetTaskState { 'Ready' } -IsAdmin $false -Optimize $O -EnableTrim $E 6>$null
        }
        $ran | Should -Be @('trim on', 'C')
    }
}

Describe 'Disk Cleanup' {
    BeforeEach {
        Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue
        $script:Store = @{}
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Registry = New-FakeRegistry -Store $script:Store -Calls $script:Calls
        $script:Handlers = { @('Temporary Files', 'Recycle Bin', 'Windows Error Reporting Files', 'Thumbnail Cache', 'Some New Handler') }
        $script:Measure = { param($Key) if ($Key -eq 'Some New Handler') { $null } else { 10MB } }
        $calls = $script:Calls
        $script:Run = { param($FilePath, $Arguments) $null = $calls.Add(('run {0} {1}' -f (Split-Path $FilePath -Leaf), $Arguments)); [pscustomobject]@{ Outcome = 'Completed'; ExitCode = 0; Seconds = 5; Messages = @() } }.GetNewClosure()
        $script:Marker = Join-Path $TestDrive 'AutoFixer\cleanmgr-slot.txt'
    }

    It 'reports each item before measuring it, so the screen can show progress' {
        $seen = [System.Collections.ArrayList]::new()
        $on = { param($Number, $Count, $Name) $null = $seen.Add(('{0}/{1}' -f $Number, $Count)) }.GetNewClosure()
        $h = @(& $script:Handlers)
        $null = InModuleScope AutoFixer -Parameters @{ H = $h; M = $script:Measure; O = $on } { param($H, $M, $O) Get-AfCleanItem -Handlers $H -Measure $M -OnItem $O }
        $seen.Count | Should -Be $h.Count
        $seen[0] | Should -Be ('1/{0}' -f $h.Count)
        $seen[-1] | Should -Be ('{0}/{0}' -f $h.Count)
    }

    It 'ticks only items that lose nothing, locks the logs the scan reads, and never ticks unknown items' {
        $items = @(InModuleScope AutoFixer -Parameters @{ H = (& $script:Handlers); M = $script:Measure } { param($H, $M) Get-AfCleanItem -Handlers $H -Measure $M })
        $byKey = @{}
        foreach ($i in $items) { $byKey[$i.Key] = $i }
        $byKey['Temporary Files'].Checked | Should -BeTrue
        $byKey['Thumbnail Cache'].Checked | Should -BeTrue
        $byKey['Recycle Bin'].Checked | Should -BeFalse
        $byKey['Recycle Bin'].Warn | Should -Be 2
        $byKey['Windows Error Reporting Files'].Locked | Should -Not -BeNullOrEmpty
        $byKey['Windows Error Reporting Files'].Size | Should -BeNullOrEmpty
        $byKey['Some New Handler'].Checked | Should -BeFalse
        $byKey['Some New Handler'].Group | Should -Be 'Other Windows items'
    }

    It 'locks every error report, dump and setup log item' {
        InModuleScope AutoFixer {
            foreach ($key in $script:AfCleanRules.Keys) {
                if ($key -match 'Error Reporting|dump|Setup Log|Upgrade Log|Reset Log') { $script:AfCleanRules[$key].Locked | Should -Not -BeNullOrEmpty -Because $key }
                if ($script:AfCleanRules[$key].Default) { [int]$script:AfCleanRules[$key].Warn | Should -Be 0 -Because $key }
            }
        }
    }

    It 'writes our slot only on the ticked items, runs cleanmgr, then empties the slot' {
        # Enter at the list keeps the defaults; Y runs.
        $r = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'Runs'); Keys = (New-KeyReader 'Enter', 'y'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $script:Run; Marker = $script:Marker } {
            param($S, $Root, $Keys, $H, $M, $R, $Run, $Marker)
            Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $Keys -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -GetFree { 1GB } -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>$null
        }
        $r.Tag | Should -Be 'OK'
        @($script:Calls | Where-Object { $_ -like 'set *' }) | Should -Be @('set Temporary Files StateFlags0042', 'set Thumbnail Cache StateFlags0042')
        $script:Calls | Should -Contain 'run cleanmgr.exe /sagerun:42'
        @($script:Store.Keys | Where-Object { $_ -like '*StateFlags0042' }).Count | Should -Be 0
        Test-Path $script:Marker | Should -BeFalse
    }

    It 'never uses a slot the user saved, and empties ours even when cleanmgr fails to start' {
        $script:Store[('{0}\Recycle Bin|StateFlags0042' -f $script:Cache)] = 2
        $boom = { throw 'cleanmgr is missing' }
        { InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'Runs'); Keys = (New-KeyReader 'Enter', 'y'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $boom; Marker = $script:Marker } {
                param($S, $Root, $Keys, $H, $M, $R, $Run, $Marker)
                Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $Keys -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -GetFree { 1GB } -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>$null
            } } | Should -Throw '*cleanmgr is missing*'
        @($script:Calls | Where-Object { $_ -like 'set *' }) | Should -Be @('set Temporary Files StateFlags0043', 'set Thumbnail Cache StateFlags0043')
        @($script:Store.Keys | Where-Object { $_ -like '*StateFlags0043' }).Count | Should -Be 0
        # The user's own value is still there.
        $script:Store[('{0}\Recycle Bin|StateFlags0042' -f $script:Cache)] | Should -Be 2
        Test-Path $script:Marker | Should -BeFalse
    }

    It 'shows used and free space on the Windows drive before and after, on screen and in the log' {
        $free = [System.Collections.Queue]::new(@([long]10GB, [long]12GB))
        $root = Join-Path $TestDrive 'RunsSpace'
        $out = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = $root; Keys = (New-KeyReader 'Enter', 'y'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $script:Run; Marker = $script:Marker; F = { $free.Dequeue() }.GetNewClosure() } {
            param($S, $Root, $Keys, $H, $M, $R, $Run, $Marker, $F)
            Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $Keys -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -GetFree $F -GetSize { 100GB } -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>&1
        }
        # Write-Host lines come back as InformationRecords (every object passes -is [pscustomobject], so match the type).
        $screen = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n"
        $screen | Should -Match 'Before\s+90\.0 GB\s+10\.0 GB'
        $screen | Should -Match 'After\s+88\.0 GB\s+12\.0 GB'
        $screen | Should -Match 'Change\s+-2\.0 GB\s+\+2\.0 GB'
        $screen | Should -Match 'Freed: 2\.0 GB\.'
        $screen | Should -Not -Match 'Less than the estimate'
        $log = Get-Content -LiteralPath (@(Get-ChildItem -Path $root -Recurse -Filter '*-cleanup.log')[0].FullName) -Raw
        $log | Should -Match 'Space     : Before\s+90\.0 GB'
        $log | Should -Match 'Exact     : free before 10,737,418,240 bytes, after 12,884,901,888 bytes, size 107,374,182,400 bytes'
    }

    It 'says why when much less was freed than the estimate' {
        $out = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'RunsNone'); Keys = (New-KeyReader 'Enter', 'y'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $script:Run; Marker = $script:Marker } {
            param($S, $Root, $Keys, $H, $M, $R, $Run, $Marker)
            Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $Keys -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -GetFree { 10GB } -GetSize { 100GB } -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>&1
        }
        $screen = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n"
        $screen | Should -Match 'Freed: 0 B\.'
        $screen | Should -Match 'Less than the estimate'
    }

    It 'asks again for a !! item by name, and No leaves only that item out' {
        # 1 = Recycle Bin (Your files sort as Recycle Bin, Temporary files, Thumbnails); tick it, Enter, N to it, Y to the run.
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'Runs'); Keys = (New-KeyReader '1', 'Enter', 'n', 'y'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $script:Run; Marker = $script:Marker } {
            param($S, $Root, $Keys, $H, $M, $R, $Run, $Marker)
            $null = Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $Keys -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -GetFree { 1GB } -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>$null
        }
        @($script:Calls | Where-Object { $_ -like 'set *' }) | Should -Not -Contain 'set Recycle Bin StateFlags0042'
        @($script:Calls | Where-Object { $_ -like 'set *' }).Count | Should -Be 2
    }

    It 'changes nothing on N, without admin rights, or on Esc' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'Runs'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $script:Run; Marker = $script:Marker; K1 = (New-KeyReader 'Enter', 'n'); K2 = (New-KeyReader 'Escape') } {
            param($S, $Root, $H, $M, $R, $Run, $Marker, $K1, $K2)
            (Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $K1 -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -GetFree { 1GB } -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>$null).Tag | Should -Be 'CANCELLED'
            (Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey { throw 'no key expected' } -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -MarkerPath $Marker -IsAdmin $false -ClearScreen { } 6>$null).Tag | Should -Be 'CANCELLED'
            (Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $K2 -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>$null).Tag | Should -Be 'CANCELLED'
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'empties a slot left by a run that was closed part-way' {
        $null = New-Item -ItemType Directory -Path (Split-Path $script:Marker) -Force
        Set-Content -Path $script:Marker -Value '44'
        $script:Store[('{0}\Temporary Files|StateFlags0044' -f $script:Cache)] = 2
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = (Join-Path $TestDrive 'Runs'); Keys = (New-KeyReader 'Escape'); H = $script:Handlers; M = $script:Measure; R = $script:Registry; Run = $script:Run; Marker = $script:Marker } {
            param($S, $Root, $Keys, $H, $M, $R, $Run, $Marker)
            $null = Invoke-AfDiskCleanup -Settings $S -OutputRoot $Root -ReadKey $Keys -GetHandlers $H -Measure $M -Registry $R -RunStep $Run -MarkerPath $Marker -IsAdmin $true -ClearScreen { } 6>$null
        }
        @($script:Store.Keys | Where-Object { $_ -like '*StateFlags0044' }).Count | Should -Be 0
        Test-Path $script:Marker | Should -BeFalse
    }

    It 'measures a folder, skipping files newer than the cut-off' {
        $dir = Join-Path $TestDrive 'temp'
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force
        Set-Content -Path (Join-Path $dir 'old.tmp') -Value ('x' * 100) -NoNewline
        Set-Content -Path (Join-Path $dir 'sub\new.tmp') -Value ('x' * 50) -NoNewline
        (Get-Item (Join-Path $dir 'old.tmp')).LastWriteTime = (Get-Date).AddDays(-30)
        InModuleScope AutoFixer -Parameters @{ Dir = $dir } {
            param($Dir)
            Measure-AfFolder -Path $Dir | Should -Be 150
            Measure-AfFolder -Path $Dir -OlderThanDays 7 | Should -Be 100
            Measure-AfFolder -Path (Join-Path $Dir 'missing') | Should -Be 0
        }
    }
}

Describe 'Clean up menu' {
    It 'opens from the main menu with C and with 4' {
        $opened = [System.Collections.ArrayList]::new()
        $cleanup = { param($S) $null = $S; $null = $opened.Add('cleanup') }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath (Join-Path $TestDrive 'settings.json') -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -CleanupAction $cleanup `
            -ReadKey (New-KeyReader 'Enter', 'c', '4', 'q', 'y') 6>$null
        $opened.Count | Should -Be 2
    }

    It 'opens Disk Cleanup and Optimize drives, and goes back on Esc' {
        $seen = [System.Collections.ArrayList]::new()
        $disk = { param($S) $null = $seen.Add('disk ' + $S.Mode) }.GetNewClosure()
        $opt = { param($S) $null = $seen.Add('optimize ' + $S.Mode) }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = $TestDrive; D = $disk; O = $opt; Keys = (New-KeyReader 'd', 'x', 'o', 'Escape') } {
            param($S, $Root, $D, $O, $Keys)
            Invoke-AfCleanupMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -DiskCleanup $D -Optimize $O 6>$null
        }
        $seen | Should -Be @('disk Standard', 'optimize Standard')
    }

    It 'opens Disk space with S and with 1, and reads the drives again each time the menu shows' {
        $seen = [System.Collections.ArrayList]::new()
        $reads = [System.Collections.ArrayList]::new()
        $space = { param($S) $null = $seen.Add('space ' + $S.Mode) }.GetNewClosure()
        $get = { $null = $reads.Add(1); [pscustomobject]@{ Letter = 'C'; IsSystem = $true; Size = 100GB; Free = 40GB; UsedPercent = 60; Low = $false } }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = $TestDrive; P = $space; G = $get; Keys = (New-KeyReader 's', 'x', '1', 'x', 'Escape') } {
            param($S, $Root, $P, $G, $Keys)
            Invoke-AfCleanupMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -DiskSpace $P -DiskCleanup { throw 'not this one' } -Optimize { throw 'not this one' } -GetSpace $G 6>$null
        }
        $seen | Should -Be @('space Standard', 'space Standard')
        $reads.Count | Should -Be 3
    }

    It 'still opens when the drives cannot be read' {
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; Root = $TestDrive; Keys = (New-KeyReader 'Escape') } {
            param($S, $Root, $Keys)
            { Invoke-AfCleanupMenu -Settings $S -OutputRoot $Root -ReadKey $Keys -GetSpace { throw 'no access' } 6>$null } | Should -Not -Throw
        }
    }
}
