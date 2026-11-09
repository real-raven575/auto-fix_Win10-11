# Outlook data files (WORK-0033 step 1). No real Outlook runs here: profiles live in Pester's
# test registry, files in TestDrive, and the Outlook reader is a fake. A key queue that runs
# dry fails the test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }

    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    $script:Closed = { [pscustomobject]@{ ClassicInstalled = $true; ClassicRunning = $false; NewRunning = $false } }
}

Describe 'Get-AfOutlookPathFromText' {
    It 'finds drive and network paths, lower-case and once each' {
        $text = "x`0C:\Users\Alice\AppData\Local\Microsoft\Outlook\alice@example.com.ost`0\\nas01\mail\Archive 2019.PST`0C:\USERS\ALICE\APPDATA\LOCAL\MICROSOFT\OUTLOOK\ALICE@EXAMPLE.COM.OST"
        $paths = @(InModuleScope AutoFixer -Parameters @{ T = $text } { param($T) Get-AfOutlookPathFromText -Text $T })
        $paths.Count | Should -Be 2
        $paths | Should -Contain 'c:\users\alice\appdata\local\microsoft\outlook\alice@example.com.ost'
        $paths | Should -Contain '\\nas01\mail\archive 2019.pst'
    }

    It 'returns nothing for empty text or other files' {
        @(InModuleScope AutoFixer { Get-AfOutlookPathFromText -Text '' }).Count | Should -Be 0
        @(InModuleScope AutoFixer { Get-AfOutlookPathFromText -Text 'C:\Temp\notes.txt' }).Count | Should -Be 0
    }
}

Describe 'Get-AfOutlookFileStatus' {
    It 'is ACTIVE when attached and changed in the last 14 days' {
        InModuleScope AutoFixer { Get-AfOutlookFileStatus -Attached $true -DaysOld 14 } | Should -Be 'ACTIVE'
    }
    It 'is idle when attached but older, and NOT attached when no profile uses it' {
        InModuleScope AutoFixer { Get-AfOutlookFileStatus -Attached $true -DaysOld 15 } | Should -Be 'ATTACHED, idle'
        InModuleScope AutoFixer { Get-AfOutlookFileStatus -Attached $false -DaysOld 0 } | Should -Be 'NOT attached'
    }
}

Describe 'Get-AfOutlookProfileData' {
    BeforeAll {
        $office = 'TestRegistry:\Office'
        $outlook = New-Item -Path "$office\16.0\Outlook" -Force
        New-ItemProperty -Path $outlook.PSPath -Name 'DefaultProfile' -Value 'Alice Work' | Out-Null
        $acct = New-Item -Path "$office\16.0\Outlook\Profiles\Alice Work\9375CFF0413111d3B88A00104B2A6676\00000001" -Force
        New-ItemProperty -Path $acct.PSPath -Name 'IMAP Server' -Value 'imap.example.com' | Out-Null
        $store = New-Item -Path "$office\16.0\Outlook\Profiles\Alice Work\abcdef" -Force
        $bytes = [Text.Encoding]::Unicode.GetBytes("C:\Users\Alice\Documents\Outlook Files\old.pst`0")
        New-ItemProperty -Path $store.PSPath -Name '001f6700' -Value $bytes -PropertyType Binary | Out-Null
        $script:Office = $office
    }

    It 'reads the default profile, account kinds and the files each profile points to' {
        $data = InModuleScope AutoFixer -Parameters @{ O = $script:Office } { param($O) Get-AfOutlookProfileData -OfficeKey $O }
        $data.Defaults | Should -Be @('Alice Work (Office 16.0)')
        $data.Accounts['Alice Work : IMAP'] | Should -Be 1
        @($data.Paths['c:\users\alice\documents\outlook files\old.pst']) | Should -Be @('Alice Work')
    }

    It 'never returns a server or account name' {
        $data = InModuleScope AutoFixer -Parameters @{ O = $script:Office } { param($O) Get-AfOutlookProfileData -OfficeKey $O }
        ($data | ConvertTo-Json -Depth 5) | Should -Not -Match 'imap\.example\.com'
    }

    It 'returns empty results when Outlook was never set up' {
        $data = InModuleScope AutoFixer { Get-AfOutlookProfileData -OfficeKey 'TestRegistry:\NoOffice' }
        $data.Defaults.Count | Should -Be 0
        $data.Accounts.Count | Should -Be 0
        $data.Paths.Count | Should -Be 0
    }
}

Describe 'Get-AfOutlookInventory' {
    BeforeAll {
        $home1 = Join-Path $TestDrive 'Users\Alice'
        $outlookDir = New-Item -ItemType Directory -Path (Join-Path $home1 'AppData\Local\Microsoft\Outlook') -Force
        $docs = New-Item -ItemType Directory -Path (Join-Path $home1 'Documents\Outlook Files') -Force
        $script:Ost = Join-Path $outlookDir.FullName 'mail.ost'
        $script:Pst = Join-Path $docs.FullName 'old.pst'
        Set-Content -Path $script:Ost -Value 'ost'
        Set-Content -Path $script:Pst -Value 'pst'
        Set-Content -Path (Join-Path $docs.FullName 'notes.txt') -Value 'not mail'
        $script:Now = Get-Date
        (Get-Item $script:Ost).LastWriteTime = $script:Now.AddDays(-1)
        (Get-Item $script:Pst).LastWriteTime = $script:Now.AddDays(-400)
        $paths = @{}
        $paths[$script:Ost.ToLowerInvariant()] = @('Work')
        $script:Data = [pscustomobject]@{ Defaults = @('Work (Office 16.0)'); Accounts = [ordered]@{}; Paths = $paths }
        $script:Home1 = $home1
    }

    It 'lists every OST and PST with its status, and only those' {
        $rows = @(InModuleScope AutoFixer -Parameters @{ H = $script:Home1; D = $script:Data; N = $script:Now } {
                param($H, $D, $N) Get-AfOutlookInventory -UserProfile $H -ProfileData $D -Now $N -InUse { param($Path) $Path -like '*.ost' }
            })
        $rows.Count | Should -Be 2
        $ost = $rows | Where-Object Type -EQ 'OST'
        $ost.Status | Should -Be 'ACTIVE'
        $ost.Profiles | Should -Be @('Work')
        $ost.Open | Should -BeTrue
        $pst = $rows | Where-Object Type -EQ 'PST'
        $pst.Status | Should -Be 'NOT attached'
        $pst.DaysOld | Should -Be 400
        $pst.Open | Should -BeFalse
    }

    It 'changes nothing on disk' {
        $before = @(Get-ChildItem $script:Home1 -Recurse -File | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks })
        $null = InModuleScope AutoFixer -Parameters @{ H = $script:Home1; D = $script:Data } { param($H, $D) Get-AfOutlookInventory -UserProfile $H -ProfileData $D }
        $after = @(Get-ChildItem $script:Home1 -Recurse -File | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks })
        $after | Should -Be $before
    }
}

Describe 'Invoke-AfOutlookInventory' {
    It 'shows the files, says nothing changed, and hides profile names in the log' {
        $runs = Join-Path $TestDrive 'Runs-inv'
        $data = [pscustomobject]@{ Defaults = @('Alice Contoso (Office 16.0)'); Accounts = [ordered]@{ 'Alice Contoso : IMAP' = 1 }; Paths = @{} }
        $row = [pscustomobject]@{ Status = 'ACTIVE'; Type = 'OST'; SizeBytes = 50GB; LastWrite = (Get-Date); DaysOld = 0; Open = $false; Profiles = @('Alice Contoso'); Path = 'C:\Users\alice\AppData\Local\Microsoft\Outlook\alice@example.com.ost' }
        $out = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $runs; D = $data; W = $row; G = $script:Closed } {
            param($S, $R, $D, $W, $G)
            Invoke-AfOutlookInventory -Settings $S -OutputRoot $R -GetState $G -GetProfileData { $D }.GetNewClosure() -GetInventory { $W }.GetNewClosure() 6>&1
        }
        $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
        $text | Should -Match 'Nothing was changed'
        $text | Should -Match 'Near the limit'
        $log = Get-ChildItem $runs -Recurse -Filter '*-outlook.log' | Select-Object -First 1
        $log | Should -Not -BeNullOrEmpty
        $logText = Get-Content $log.FullName -Raw
        $logText | Should -Match 'Classic Outlook'
        $logText | Should -Not -Match 'Alice Contoso'
        $logText | Should -Not -Match 'alice@example\.com'
        $logText | Should -Not -Match '(?i)Users\\alice'
    }
}

Describe 'Test-AfTempSpace' {
    It 'allows copies up to 80% of the free space' {
        InModuleScope AutoFixer { Test-AfTempSpace -NeedBytes 80 -FreeBytes 100 } | Should -BeTrue
        InModuleScope AutoFixer { Test-AfTempSpace -NeedBytes 81 -FreeBytes 100 } | Should -BeFalse
    }
}

Describe 'Invoke-AfPstMailDates' {
    BeforeEach {
        $script:Src = Join-Path $TestDrive 'src'
        Remove-Item $script:Src -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path $script:Src -Force
        Set-Content -Path (Join-Path $script:Src 'archive.pst') -Value 'pst one'
        Set-Content -Path (Join-Path $script:Src 'old.pst') -Value 'pst two'
        $script:Temp = Join-Path $TestDrive 'pst-temp'
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
        $script:Runs = Join-Path $TestDrive 'Runs-dates'
        $src = $script:Src
        $script:Psts = { Get-ChildItem -Path $src -Filter '*.pst' }.GetNewClosure()
        $script:Hash = { @(Get-ChildItem $src -File | ForEach-Object { (Get-FileHash $_.FullName).Hash }) }.GetNewClosure()
    }

    It 'stops before copying when Outlook is open' {
        $open = { [pscustomobject]@{ ClassicInstalled = $true; ClassicRunning = $true; NewRunning = $false } }
        $rows = @(InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; T = $script:Temp; G = $open; P = $script:Psts } {
                param($S, $R, $T, $G, $P)
                Invoke-AfPstMailDates -Settings $S -OutputRoot $R -TempRoot $T -GetState $G -GetPst $P -ReadKey { throw 'no question expected' } -ReadCopies { throw 'Outlook must not be used' } 6>$null
            })
        $rows.Count | Should -Be 0
        Test-Path $script:Temp | Should -BeFalse
    }

    It 'stops when classic Outlook is not installed' {
        $none = { [pscustomobject]@{ ClassicInstalled = $false; ClassicRunning = $false; NewRunning = $true } }
        $rows = @(InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; T = $script:Temp; G = $none; P = $script:Psts } {
                param($S, $R, $T, $G, $P)
                Invoke-AfPstMailDates -Settings $S -OutputRoot $R -TempRoot $T -GetState $G -GetPst $P -ReadKey { throw 'no question expected' } -ReadCopies { throw 'Outlook must not be used' } 6>$null
            })
        $rows.Count | Should -Be 0
    }

    It 'stops when there is not enough free space for the copies' {
        $rows = @(InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; T = $script:Temp; G = $script:Closed; P = $script:Psts } {
                param($S, $R, $T, $G, $P)
                Invoke-AfPstMailDates -Settings $S -OutputRoot $R -TempRoot $T -GetState $G -GetPst $P -GetFreeBytes { 1 } -ReadKey { throw 'no question expected' } -ReadCopies { throw 'Outlook must not be used' } 6>$null
            })
        $rows.Count | Should -Be 0
        Test-Path $script:Temp | Should -BeFalse
    }

    It 'copies nothing when the answer is N' {
        $rows = @(InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; T = $script:Temp; G = $script:Closed; P = $script:Psts; K = (New-KeyReader 'n') } {
                param($S, $R, $T, $G, $P, $K)
                Invoke-AfPstMailDates -Settings $S -OutputRoot $R -TempRoot $T -GetState $G -GetPst $P -ReadKey $K -ReadCopies { throw 'Outlook must not be used' } 6>$null
            })
        $rows.Count | Should -Be 0
        Test-Path $script:Temp | Should -BeFalse
    }

    It 'reads only the temp copies, reports the dates and deletes the copies' {
        $before = & $script:Hash
        $seen = [System.Collections.ArrayList]::new()
        $reader = {
            param($Copies)
            foreach ($c in $Copies) {
                $null = $seen.Add($c.Copy)
                [pscustomobject]@{ Copy = $c.Copy; Mail = 12; Old = [datetime]'2015-03-01'; New = [datetime]'2019-12-31'; Note = 'read from copy' }
            }
        }.GetNewClosure()
        $rows = @(InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; T = $script:Temp; G = $script:Closed; P = $script:Psts; K = (New-KeyReader 'y'); C = $reader } {
                param($S, $R, $T, $G, $P, $K, $C)
                Invoke-AfPstMailDates -Settings $S -OutputRoot $R -TempRoot $T -GetState $G -GetPst $P -ReadKey $K -ReadCopies $C 6>$null
            })
        $rows.Count | Should -Be 2
        $rows[0].Mail | Should -Be 12
        $rows[0].Oldest | Should -Be '2015-03-01'
        $rows[0].Newest | Should -Be '2019-12-31'
        $seen.Count | Should -Be 2
        foreach ($s in $seen) { $s | Should -BeLike (Join-Path $script:Temp '*') }
        Test-Path $script:Temp | Should -BeFalse
        (& $script:Hash) | Should -Be $before
        Get-ChildItem $script:Runs -Recurse -Filter '*-outlook.log' | Should -Not -BeNullOrEmpty
    }

    It 'says so when Outlook cannot read the copies, and still deletes them' {
        $rows = @(InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; T = $script:Temp; G = $script:Closed; P = $script:Psts; K = (New-KeyReader 'y') } {
                param($S, $R, $T, $G, $P, $K)
                Invoke-AfPstMailDates -Settings $S -OutputRoot $R -TempRoot $T -GetState $G -GetPst $P -ReadKey $K -ReadCopies { throw 'Outlook is not registered' } 6>$null
            })
        $rows.Count | Should -Be 2
        @($rows | Where-Object Note -EQ 'not read').Count | Should -Be 2
        Test-Path $script:Temp | Should -BeFalse
    }
}

Describe 'Office and Outlook menu' {
    It 'opens from the main menu with O, and runs each tool from its menu' {
        $calls = [System.Collections.ArrayList]::new()
        $path = Join-Path $TestDrive 'settings-office.json'
        $office = { param($S) $null = $calls.Add('office') }.GetNewClosure()
        Invoke-AfMainMenu -SettingsPath $path -OutputRoot (Join-Path $TestDrive 'Runs-menu') -ScanAction { } -OfficeAction $office -ReadKey (New-KeyReader 'Enter', 'o', '5', 'q', 'y') 6>$null
        $calls | Should -Be @('office', 'office')

        $calls.Clear()
        $inv = { param($S) $null = $calls.Add('inventory') }.GetNewClosure()
        $dates = { param($S) $null = $calls.Add('dates') }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; I = $inv; D = $dates; K = (New-KeyReader 'i', 'x1', 'd', 'x2', 'b') } {
            param($S, $I, $D, $K)
            Invoke-AfOutlookMenu -Settings $S -OutputRoot $TestDrive -Inventory $I -MailDates $D -ReadKey $K 6>$null
        }
        $calls | Should -Be @('inventory', 'dates')
    }
}
