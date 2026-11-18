# Office and Outlook > Online Archive (WORK-0038). No Outlook, window or scheduled task runs here:
# the pure helpers are tested directly, and the launcher gets fakes for Outlook state, the console
# user, admin rights and the two ways of opening the window. A key queue that runs dry fails the
# test, which proves no extra question was asked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }
    $script:Settings = [pscustomobject]@{ SchemaVersion = 1; Mode = 'Standard'; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
}

Describe 'Online Archive helpers' {
    It 'drops the mailbox name from a folder path' {
        InModuleScope AutoFixer { Get-AfArchiveRelPath -FolderPath '\\Pat Example\Inbox\Clients' } | Should -Be 'Inbox\Clients'
        InModuleScope AutoFixer { Get-AfArchiveRelPath -FolderPath '\\Pat Example' } | Should -Be ''
    }

    It 'labels folders without showing personal folder names' {
        InModuleScope AutoFixer { Get-AfArchiveFolderLabel -Index 2 -RelPath 'Inbox\Clients' } | Should -Be '[2] Inbox\..'
        InModuleScope AutoFixer { Get-AfArchiveFolderLabel -Index 3 -RelPath 'Pat Private' } | Should -Be '[3] Folder'
        InModuleScope AutoFixer { Get-AfArchiveFolderLabel -Index 1 -RelPath 'Sent Items' } | Should -Be '[1] Sent Items'
    }

    It 'picks mail older than the cut-off, and skips unread or flagged mail only when asked' {
        InModuleScope AutoFixer {
            $cut = [datetime]'2025-01-01'
            Test-AfArchivePick -Received ([datetime]'2024-06-01') -Cutoff $cut | Should -BeTrue
            Test-AfArchivePick -Received ([datetime]'2025-01-01') -Cutoff $cut | Should -BeFalse
            Test-AfArchivePick -Received $null -Cutoff $cut | Should -BeFalse
            Test-AfArchivePick -Received ([datetime]'2024-06-01') -Cutoff $cut -UnRead $true | Should -BeTrue
            Test-AfArchivePick -Received ([datetime]'2024-06-01') -Cutoff $cut -UnRead $true -SkipUnread $true | Should -BeFalse
            Test-AfArchivePick -Received ([datetime]'2024-06-01') -Cutoff $cut -FlagStatus 2 -SkipFlagged $true | Should -BeFalse
            Test-AfArchivePick -Received ([datetime]'2024-06-01') -Cutoff $cut -FlagStatus 1 -SkipFlagged $true | Should -BeTrue
        }
    }

    It 'makes the same hashed key for the same email and never keeps the text' {
        InModuleScope AutoFixer {
            $a = Get-AfArchiveMessageKey -MessageId ' <abc@example.com> ' -Received $null -Subject 'x'
            $b = Get-AfArchiveMessageKey -MessageId '<abc@example.com>' -Received ([datetime]'2020-01-01') -Subject 'y'
            $a | Should -Be $b
            $a | Should -Match '^M[0-9a-f]{12}$'
            $t = Get-AfArchiveMessageKey -MessageId '' -Received ([datetime]'2020-01-02 03:04:05') -Subject 'Salary review'
            $t | Should -Match '^T20200102030405[0-9a-f]{12}$'
            $t | Should -Not -Match 'Salary'
        }
    }

    It 'matches each planned email once, so a duplicate must be found twice' {
        InModuleScope AutoFixer {
            $planned = @([pscustomobject]@{ Key = 'K1'; Received = 'r1' }, [pscustomobject]@{ Key = 'K1'; Received = 'r2' }, [pscustomobject]@{ Key = 'K2'; Received = 'r3' })
            $c = Compare-AfArchiveInventory -Planned $planned -Found @('K1', 'K2', 'K9')
            $c.Planned | Should -Be 3
            $c.Found | Should -Be 2
            $c.Missing | Should -Be 1
            $c.MissingReceived | Should -Be @('r2')
        }
    }

    It 'says how far an undo got' {
        InModuleScope AutoFixer { Get-AfArchiveUndoState -Moved 9 -Back 0 } | Should -Be 'not undone'
        InModuleScope AutoFixer { Get-AfArchiveUndoState -Moved 9 -Back 9 } | Should -Be 'undone (all back)'
        InModuleScope AutoFixer { Get-AfArchiveUndoState -Moved 9 -Back 4 } | Should -Be 'partly undone (4 back)'
    }

    It 'gives every exit code a meaning' {
        foreach ($c in 0..4) { InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfArchiveExitText $C } | Should -Match ('^{0} = \w' -f $c) }
        InModuleScope AutoFixer { Get-AfArchiveExitText 9 } | Should -Be '9 = Unknown result code.'
    }
}

Describe 'Get-AfArchiveLaunchPlan' {
    It 'stops when classic Outlook is not open, and names New Outlook when that is all that runs' {
        $p = InModuleScope AutoFixer { Get-AfArchiveLaunchPlan -ConsoleUser 'PC\pat' -IsAdmin $true -ClassicRunning $false -NewRunning $true }
        $p.Action | Should -Be 'Stop'
        $p.Reason | Should -Match 'New Outlook'
    }
    It 'opens directly without admin rights' {
        (InModuleScope AutoFixer { Get-AfArchiveLaunchPlan -ConsoleUser '' -IsAdmin $false -ClassicRunning $true }).Action | Should -Be 'Direct'
    }
    It 'uses a temporary task as admin, and stops when nobody is signed in' {
        (InModuleScope AutoFixer { Get-AfArchiveLaunchPlan -ConsoleUser 'PC\pat' -IsAdmin $true -ClassicRunning $true }).Action | Should -Be 'Task'
        (InModuleScope AutoFixer { Get-AfArchiveLaunchPlan -ConsoleUser '' -IsAdmin $true -ClassicRunning $true }).Action | Should -Be 'Stop'
    }
}

Describe 'Online Archive start script' {
    It 'loads the module, opens the window, saves the result and exits with its code' {
        $text = InModuleScope AutoFixer { New-AfArchiveStartScript -ModulePath "C:\Run\O'Brien\AutoFixer\AutoFixer.psd1" -ResultPath 'C:\Run\result.json' }
        $text | Should -Match "Import-Module 'C:\\Run\\O''Brien\\AutoFixer\\AutoFixer.psd1'"
        $text | Should -Match 'Start-AfOnlineArchiveWindow'
        $text | Should -Match 'exit \$code'
        $null = [scriptblock]::Create($text)
        @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
    It 'starts PowerShell in STA with the console hidden' {
        InModuleScope AutoFixer { Get-AfArchiveTaskArgument -ScriptPath 'C:\Run\start.ps1' } | Should -Be '-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Run\start.ps1"'
    }
    It 'reads a missing or broken result as code 4' {
        $r = InModuleScope AutoFixer -Parameters @{ P = (Join-Path $TestDrive 'none.json') } { param($P) Read-AfArchiveResult -Path $P }
        $r.ExitCode | Should -Be 4
        $good = Join-Path $TestDrive 'good.json'
        @{ ExitCode = 1; Lines = @('a', 'b') } | ConvertTo-Json | Set-Content -LiteralPath $good
        $r = InModuleScope AutoFixer -Parameters @{ P = $good } { param($P) Read-AfArchiveResult -Path $P }
        $r.ExitCode | Should -Be 1
        $r.Lines | Should -Be @('a', 'b')
    }
}

Describe 'Invoke-AfOnlineArchive' {
    BeforeEach {
        $script:Runs = Join-Path $TestDrive ('runs-' + [guid]::NewGuid().ToString('N'))
        $script:Work = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N'))
        $script:Calls = [System.Collections.ArrayList]::new()
    }

    It 'stops with code 3 and asks nothing when classic Outlook is not open' {
        $code = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; W = $script:Work; K = (New-KeyReader) } {
            param($S, $R, $W, $K)
            Invoke-AfOnlineArchive -Settings $S -OutputRoot $R -WorkRoot $W -ReadKey $K -GetState { [pscustomobject]@{ ClassicRunning = $false; NewRunning = $false } } `
                -GetConsoleUser { 'PC\pat' } -IsAdmin { $true } -RunDirect { throw 'must not run' } -RunTask { throw 'must not run' } 6>$null
        }
        $code | Should -Be 3
    }

    It 'opens nothing when the answer is N' {
        $calls = $script:Calls
        $code = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; W = $script:Work; K = (New-KeyReader 'N'); C = $calls } {
            param($S, $R, $W, $K, $C)
            Invoke-AfOnlineArchive -Settings $S -OutputRoot $R -WorkRoot $W -ReadKey $K -GetState { [pscustomobject]@{ ClassicRunning = $true; NewRunning = $false } } `
                -GetConsoleUser { 'PC\pat' } -IsAdmin { $false } -RunDirect { param($P) [void]$C.Add($P) }.GetNewClosure() -RunTask { throw 'must not run' } 6>$null
        }
        $code | Should -Be 0
        $calls.Count | Should -Be 0
    }

    It 'opens directly without admin rights, shows the window result and removes its temporary folder' {
        $code = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; W = $script:Work; K = (New-KeyReader 'Y') } {
            param($S, $R, $W, $K)
            $run = {
                param($ScriptPath)
                (Get-Content -LiteralPath $ScriptPath -Raw) | Should -Match 'Start-AfOnlineArchiveWindow'
                @{ ExitCode = 0; Lines = @('Online Archive push', 'Move: moved 9  failed 0') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $ScriptPath) 'result.json')
                0
            }
            Invoke-AfOnlineArchive -Settings $S -OutputRoot $R -WorkRoot $W -ReadKey $K -GetState { [pscustomobject]@{ ClassicRunning = $true; NewRunning = $false } } `
                -GetConsoleUser { '' } -IsAdmin { $false } -RunDirect $run -RunTask { throw 'must not run' } 6>$null
        }
        $code | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Work -ErrorAction SilentlyContinue).Count | Should -Be 0
        $log = Get-ChildItem -LiteralPath $script:Runs -Recurse -Filter '*-archive.log' | Select-Object -First 1
        $text = Get-Content -LiteralPath $log.FullName -Raw
        $text | Should -Match 'moved 9'
        $text | Should -Match 'Result: 0 = Done'
    }

    It 'as admin, runs the task as the signed-in user from a copy and reports the window''s code' {
        $calls = $script:Calls
        $code = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; W = $script:Work; K = (New-KeyReader 'Y'); C = $calls } {
            param($S, $R, $W, $K, $C)
            Mock icacls.exe { }
            $task = {
                param($ScriptPath, $User, $TaskName)
                [void]$C.Add(@($User, $TaskName))
                Test-Path -LiteralPath (Join-Path (Split-Path $ScriptPath) 'AutoFixer\AutoFixer.psd1') | Should -BeTrue
                @{ ExitCode = 2; Lines = @('STOPPED by the user') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $ScriptPath) 'result.json')
                0
            }.GetNewClosure()
            Invoke-AfOnlineArchive -Settings $S -OutputRoot $R -WorkRoot $W -ReadKey $K -GetState { [pscustomobject]@{ ClassicRunning = $true; NewRunning = $false } } `
                -GetConsoleUser { 'PC\pat' } -IsAdmin { $true } -RunDirect { throw 'must not run' } -RunTask $task 6>$null
        }
        $code | Should -Be 2
        $calls[0][0] | Should -Be 'PC\pat'
        $calls[0][1] | Should -Match '^AutoFixer-OnlineArchive-\d{8}-\d{6}Z$'
        @(Get-ChildItem -LiteralPath $script:Work -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'reports code 4 when the window sends no result' {
        $code = InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $script:Runs; W = $script:Work; K = (New-KeyReader 'Y') } {
            param($S, $R, $W, $K)
            Invoke-AfOnlineArchive -Settings $S -OutputRoot $R -WorkRoot $W -ReadKey $K -GetState { [pscustomobject]@{ ClassicRunning = $true; NewRunning = $false } } `
                -GetConsoleUser { '' } -IsAdmin { $false } -RunDirect { 1 } -RunTask { throw 'must not run' } 6>$null
        }
        $code | Should -Be 4
    }
}

Describe 'Office and Outlook menu' {
    It 'has Online Archive as item A' {
        $called = [System.Collections.ArrayList]::new()
        InModuleScope AutoFixer -Parameters @{ S = $script:Settings; R = $TestDrive; K = (New-KeyReader 'A', ' ', 'B'); C = $called } {
            param($S, $R, $K, $C)
            Mock Select-AfMenuItem { $script:MenuPick = @('A', 'B')[[int]$script:MenuN++]; $script:MenuPick }
            $script:MenuN = 0
            Invoke-AfOutlookMenu -Settings $S -OutputRoot $R -ReadKey $K -Archive { param($X) [void]$C.Add('A') }.GetNewClosure() -Inventory { throw 'no' } -MailDates { throw 'no' } 6>$null
        }
        $called | Should -Be @('A')
    }
}
