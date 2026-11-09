# Online add-ons switch, Back up PSTs and Purview PST Import. Nothing goes online here: the
# Exchange and AzCopy steps are never reached, and a key queue that runs dry fails the test,
# which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }
    function New-TestSettings([string] $Mode = 'Technician', [bool] $Online = $false, [bool] $Addons = $false) {
        [pscustomobject]@{ SchemaVersion = 1; Mode = $Mode; ShowSensitive = $false; SaveSensitive = $false; Online = $Online; OnlineAddons = $Addons; Style = 'Branded' }
    }
}

Describe 'Test-AfSasUrl' {
    It 'accepts a Purview network upload link' {
        InModuleScope AutoFixer { Test-AfSasUrl -Url 'https://abc123def.blob.core.windows.net/ingestiondata?skoid=x&sv=2020&sig=AbC%2Fd' } | Should -BeTrue
    }

    It 'refuses other links, plain http, a missing signature and empty text' {
        foreach ($u in 'http://abc.blob.core.windows.net/ingestiondata?sig=x', 'https://abc.blob.core.windows.net/other?sig=x',
            'https://abc.blob.core.windows.net/ingestiondata?sv=2020', 'https://evil.example.com/ingestiondata?sig=x', '') {
            InModuleScope AutoFixer -Parameters @{ U = $u } { param($U) Test-AfSasUrl -Url $U } | Should -BeFalse -Because $u
        }
    }
}

Describe 'New-AfPstMappingCsv' {
    It 'writes one archive row per PST, each into its own Imported folder' {
        $lines = @(InModuleScope AutoFixer { New-AfPstMappingCsv -FolderName 'PSTBackup-20261109' -FileName 'archive.pst', 'old mail.pst' -Mailbox 'user@example.com' })
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^Workload,FilePath,Name,Mailbox,IsArchive,TargetRootFolder,'
        $lines[1] | Should -Be 'Exchange,PSTBackup-20261109,archive.pst,user@example.com,TRUE,/Imported-archive,,,,'
        $lines[2] | Should -Be 'Exchange,PSTBackup-20261109,old mail.pst,user@example.com,TRUE,/Imported-old mail,,,,'
    }

    It 'refuses a file name with a comma or semicolon' {
        { InModuleScope AutoFixer { New-AfPstMappingCsv -FolderName 'F' -FileName 'a,b.pst' -Mailbox 'u@example.com' } } | Should -Throw '*comma or semicolon*'
        { InModuleScope AutoFixer { New-AfPstMappingCsv -FolderName 'F' -FileName 'a;b.pst' -Mailbox 'u@example.com' } } | Should -Throw '*comma or semicolon*'
    }
}

Describe 'Get-AfUniquePst' {
    It 'keeps the first file of each hash and lists the duplicates' {
        $files = @(
            [pscustomobject]@{ Name = 'b.pst'; Hash = 'H1' }
            [pscustomobject]@{ Name = 'a.pst'; Hash = 'H1' }
            [pscustomobject]@{ Name = 'c.pst'; Hash = 'H2' }
        )
        $r = InModuleScope AutoFixer -Parameters @{ F = $files } { param($F) Get-AfUniquePst -Files $F -GetHash { param($File) $File.Hash } }
        @($r.Keep.Name) | Should -Be @('a.pst', 'c.pst')
        @($r.Duplicates.Name) | Should -Be @('b.pst')
    }
}

Describe 'Read-AfPstHashList and Get-AfMailboxKey' {
    It 'reads the hash list Back up PSTs writes' {
        $p = Join-Path $TestDrive 'hashes-sha256.txt'
        Set-Content -LiteralPath $p -Value @(('a' * 64) + '  one.pst', 'not a hash line', ('B' * 64) + '  two words.pst')
        $m = InModuleScope AutoFixer -Parameters @{ P = $p } { param($P) Read-AfPstHashList -Path $P }
        $m.Count | Should -Be 2
        $m['one.pst'] | Should -Be ('A' * 64)
        $m['two words.pst'] | Should -Be ('B' * 64)
    }

    It 'gives the same key for the same mailbox in any case, and never contains the address' {
        $k1 = InModuleScope AutoFixer { Get-AfMailboxKey -Mailbox 'User@Example.com' }
        $k2 = InModuleScope AutoFixer { Get-AfMailboxKey -Mailbox ' user@example.com ' }
        $k1 | Should -Be $k2
        $k1 | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Online add-ons switch' {
    It 'counts only in Technician mode with Online on' {
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician' $true $true) } { param($S) Test-AfOnlineAddonsOn -Settings $S } | Should -BeTrue
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Standard' $true $true) } { param($S) Test-AfOnlineAddonsOn -Settings $S } | Should -BeFalse
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician' $false $true) } { param($S) Test-AfOnlineAddonsOn -Settings $S } | Should -BeFalse
    }

    It 'turns on only after Y, turns Online on with it, and is saved' {
        $path = Join-Path $TestDrive 'settings-addons.json'
        $s = New-TestSettings 'Technician'
        InModuleScope AutoFixer -Parameters @{ S = $s; P = $path; K = (New-KeyReader 'a', 'n', 'a', 'y', 'b') } { param($S, $P, $K) $null = Invoke-AfSettingsMenu -Settings $S -Path $P -ReadKey $K 6>$null }
        $s.OnlineAddons | Should -BeTrue
        $s.Online | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).onlineAddons | Should -BeTrue
    }

    It 'turns off when Online goes off or the mode goes back to Standard, with no question' {
        $s = New-TestSettings 'Technician' $true $true
        InModuleScope AutoFixer -Parameters @{ S = $s; P = (Join-Path $TestDrive 's1.json'); K = (New-KeyReader 'g', 'b') } { param($S, $P, $K) $null = Invoke-AfSettingsMenu -Settings $S -Path $P -ReadKey $K 6>$null }
        $s.OnlineAddons | Should -BeFalse
        $s = New-TestSettings 'Technician' $true $true
        InModuleScope AutoFixer -Parameters @{ S = $s; P = (Join-Path $TestDrive 's2.json'); K = (New-KeyReader 'm', 'b') } { param($S, $P, $K) $null = Invoke-AfSettingsMenu -Settings $S -Path $P -ReadKey $K 6>$null }
        $s.Mode | Should -Be 'Standard'
        $s.OnlineAddons | Should -BeFalse
    }

    It 'is not offered in Standard mode' {
        $s = New-TestSettings 'Standard'
        # 'a' is not an item in Standard, so the menu ignores it and B leaves.
        InModuleScope AutoFixer -Parameters @{ S = $s; P = (Join-Path $TestDrive 's3.json'); K = (New-KeyReader 'a', 'b') } { param($S, $P, $K) $null = Invoke-AfSettingsMenu -Settings $S -Path $P -ReadKey $K 6>$null }
        $s.OnlineAddons | Should -BeFalse
    }
}

Describe 'Purview PST Import menu' {
    It 'is only in the Office and Outlook menu in Technician mode' {
        $calls = [System.Collections.ArrayList]::new()
        $pv = { param($S) $null = $calls.Add('purview') }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Standard'); V = $pv; K = (New-KeyReader 'p', 'b') } {
            param($S, $V, $K) Invoke-AfOutlookMenu -Settings $S -OutputRoot $TestDrive -Purview $V -ReadKey $K 6>$null
        }
        $calls.Count | Should -Be 0
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician'); V = $pv; K = (New-KeyReader 'p', 'b') } {
            param($S, $V, $K) Invoke-AfOutlookMenu -Settings $S -OutputRoot $TestDrive -Purview $V -ReadKey $K 6>$null
        }
        $calls | Should -Be @('purview')
    }

    It 'shows a note instead of an add-on step while the switch is off, and runs the stock-Windows steps' {
        $calls = [System.Collections.ArrayList]::new()
        $mk = { param($Name) { $null = $calls.Add($Name) }.GetNewClosure() }
        # U: note, no Settings offered (none given), key to return. M: runs. Any key, then B.
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician'); K = (New-KeyReader 'u', 'x1', 'm', 'x2', 'b'); U = (& $mk 'upload'); M = (& $mk 'mapping') } {
            param($S, $K, $U, $M) Invoke-AfPurviewMenu -Settings $S -OutputRoot $TestDrive -Upload $U -Prepare $M -ReadKey $K 6>$null
        }
        $calls | Should -Be @('mapping')
    }

    It 'opens Settings from the note, and runs the step once the add-ons are on' {
        $calls = [System.Collections.ArrayList]::new()
        $up = { param($S) $null = $calls.Add('upload') }.GetNewClosure()
        $open = { param($S) $S.Online = $true; $S.OnlineAddons = $true }
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician'); K = (New-KeyReader 'u', 'y', 'x1', 'b'); U = $up; O = $open } {
            param($S, $K, $U, $O) Invoke-AfPurviewMenu -Settings $S -OutputRoot $TestDrive -Upload $U -OpenSettings $O -ReadKey $K 6>$null
        }
        $calls | Should -Be @('upload')
    }

    It 'runs the add-on steps with no note when the switch is on' {
        $calls = [System.Collections.ArrayList]::new()
        $pre = { param($S) $null = $calls.Add('precheck') }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician' $true $true); K = (New-KeyReader 'c', 'x1', 'b'); C = $pre } {
            param($S, $K, $C) Invoke-AfPurviewMenu -Settings $S -OutputRoot $TestDrive -Precheck $C -ReadKey $K 6>$null
        }
        $calls | Should -Be @('precheck')
    }

    It 'undo part 1 refuses to sign in while the switch is off' {
        InModuleScope AutoFixer -Parameters @{ T = { param($P) '1' } } {
            param($T)
            Mock Connect-AfExchange { $true }
            Invoke-AfPurviewUndo -OutputRoot $TestDrive -ReadText $T -AddonsOn $false 6>$null
            Should -Invoke Connect-AfExchange -Times 0
        }
    }
}

Describe 'Mapping file (no download)' {
    It 'skips duplicates by hash and writes the mapping file for the newest backup' {
        $backup = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'PSTBackup-20261109') -Force
        Set-Content -LiteralPath (Join-Path $backup 'a.pst') -Value 'same'
        Set-Content -LiteralPath (Join-Path $backup 'b.pst') -Value 'same'
        Set-Content -LiteralPath (Join-Path $backup 'c.pst') -Value 'other'
        Set-Content -LiteralPath (Join-Path $backup 'notes.txt') -Value 'x'
        $work = Join-Path $TestDrive 'PSTImport'
        $r = InModuleScope AutoFixer -Parameters @{ B = $backup; W = $work; R = (Join-Path $TestDrive 'Runs') } {
            param($B, $W, $R)
            Invoke-AfPurviewPrepare -OutputRoot $R -Mailbox 'user@example.com' -GetBackup { $B }.GetNewClosure() -WorkFolder $W 6>$null
        }
        @($r.Keep.Name) | Should -Be @('a.pst', 'c.pst')
        @($r.Duplicates.Name) | Should -Be @('b.pst')
        $csv = @(Get-Content -LiteralPath (Join-Path $work 'pst-mapping.csv'))
        $csv.Count | Should -Be 3
        $csv[1] | Should -Match '^Exchange,PSTBackup-20261109,a\.pst,'
        # The log is redacted: the address is not in it.
        (Get-ChildItem (Join-Path $TestDrive 'Runs') -Recurse -Filter '*.log' | Get-Content -Raw) | Should -Not -Match 'user@example\.com'
    }

    It 'stops with nothing written when there is no backup folder' {
        $work = Join-Path $TestDrive 'PSTImport-none'
        InModuleScope AutoFixer -Parameters @{ W = $work } { param($W) Invoke-AfPurviewPrepare -OutputRoot $TestDrive -Mailbox 'u@example.com' -GetBackup { $null } -WorkFolder $W 6>$null } | Should -BeNullOrEmpty
        Test-Path $work | Should -BeFalse
    }
}

Describe 'Invoke-AfPstBackup' {
    BeforeAll {
        $script:Closed = { [pscustomobject]@{ ClassicInstalled = $true; ClassicRunning = $false; NewRunning = $false } }
        $script:Src = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Users\Alice\Documents\Outlook Files') -Force
        Set-Content -LiteralPath (Join-Path $script:Src 'archive.pst') -Value 'mail one'
        $sub = New-Item -ItemType Directory -Path (Join-Path $script:Src 'old') -Force
        Set-Content -LiteralPath (Join-Path $sub 'archive.pst') -Value 'mail two'
    }

    It 'finds PSTs per Windows user, skipping Public and Default' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Users\Public\Documents') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $TestDrive 'Users\Public\Documents\x.pst') -Value 'p'
        $rows = @(InModuleScope AutoFixer -Parameters @{ R = (Join-Path $TestDrive 'Users') } { param($R) Get-AfPstBackupSource -UsersRoot $R })
        $rows.Count | Should -Be 1
        $rows[0].Folder | Should -Match 'Alice$'
        $rows[0].Files.Count | Should -Be 2
    }

    It 'copies every PST, checks SHA-256, keeps both same-named files and writes the hash list' {
        $dest = Join-Path $TestDrive 'Backup1'
        $rows = @(InModuleScope AutoFixer -Parameters @{ D = $dest; G = $script:Closed; U = (Join-Path $TestDrive 'Users'); R = (Join-Path $TestDrive 'Runs-b'); K = (New-KeyReader 'y'); T = { param($P) '' } } {
                param($D, $G, $U, $R, $K, $T)
                $settings = [pscustomobject]@{ Mode = 'Standard'; ShowSensitive = $false }
                Invoke-AfPstBackup -Settings $settings -OutputRoot $R -ReadKey $K -ReadText $T -GetState $G -GetSources { Get-AfPstBackupSource -UsersRoot $U }.GetNewClosure() `
                    -DefaultDestination $D -GetFreeBytes { 100GB } 6>$null
            })
        $rows.Count | Should -Be 2
        @($rows | Where-Object Status -EQ 'OK').Count | Should -Be 2
        @(Get-ChildItem $dest -Filter '*.pst').Name | Sort-Object | Should -Be @('archive-2.pst', 'archive.pst')
        @(Get-Content (Join-Path $dest 'hashes-sha256.txt')).Count | Should -Be 2
        # The user's folder name is hidden in the log.
        (Get-ChildItem (Join-Path $TestDrive 'Runs-b') -Recurse -Filter '*.log' | Get-Content -Raw) | Should -Not -Match 'Alice'
    }

    It 'stops before copying when there is not enough space, and says how much is needed' {
        $dest = Join-Path $TestDrive 'Backup2'
        $out = InModuleScope AutoFixer -Parameters @{ D = $dest; G = $script:Closed; U = (Join-Path $TestDrive 'Users'); T = { param($P) '' } } {
            param($D, $G, $U, $T)
            $settings = [pscustomobject]@{ Mode = 'Standard'; ShowSensitive = $false }
            Invoke-AfPstBackup -Settings $settings -OutputRoot $TestDrive -ReadKey { throw 'no question expected' } -ReadText $T -GetState $G `
                -GetSources { Get-AfPstBackupSource -UsersRoot $U }.GetNewClosure() -DefaultDestination $D -GetFreeBytes { 1 } 6>&1
        }
        ($out | Out-String) | Should -Match 'Not enough free space'
        Test-Path $dest | Should -BeFalse
    }

    It 'stops while Outlook is open, and on N, with nothing copied' {
        $dest = Join-Path $TestDrive 'Backup3'
        InModuleScope AutoFixer -Parameters @{ D = $dest } {
            param($D)
            $settings = [pscustomobject]@{ Mode = 'Standard'; ShowSensitive = $false }
            Invoke-AfPstBackup -Settings $settings -OutputRoot $TestDrive -ReadKey { throw 'no question expected' } -GetState { [pscustomobject]@{ ClassicRunning = $true } } `
                -GetSources { throw 'not reached' } -DefaultDestination $D 6>$null
        } | Should -BeNullOrEmpty
        InModuleScope AutoFixer -Parameters @{ D = $dest; G = $script:Closed; U = (Join-Path $TestDrive 'Users'); K = (New-KeyReader 'n'); T = { param($P) '' } } {
            param($D, $G, $U, $K, $T)
            $settings = [pscustomobject]@{ Mode = 'Standard'; ShowSensitive = $false }
            Invoke-AfPstBackup -Settings $settings -OutputRoot $TestDrive -ReadKey $K -ReadText $T -GetState $G -GetSources { Get-AfPstBackupSource -UsersRoot $U }.GetNewClosure() `
                -DefaultDestination $D -GetFreeBytes { 100GB } 6>$null
        } | Should -BeNullOrEmpty
        Test-Path $dest | Should -BeFalse
    }
}
