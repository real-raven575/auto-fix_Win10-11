# Keys are fed from a queue: 'Up', 'Down', 'Enter', 'Escape' or one character.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    function New-KeyReader([string[]] $Keys) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }
}

Describe 'Select-AfMenuItem' {
    BeforeAll { $script:Items = @(@{ Key = '1'; Label = 'One' }, @{ Key = '2'; Label = 'Two' }, @{ Key = 'Q'; Label = 'Quit' }) }

    It 'picks an item by its key, in either case' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader '2'); Q = (New-KeyReader 'q') } {
            param($Items, $Keys, $Q)
            Select-AfMenuItem -Title 'T' -Items $Items -ReadKey $Keys | Should -Be '2'
            Select-AfMenuItem -Title 'T' -Items $Items -ReadKey $Q | Should -Be 'Q'
        }
    }

    It 'moves with the arrow keys, wraps around, and picks with Enter' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items; A = (New-KeyReader 'Down', 'Down', 'Enter'); B = (New-KeyReader 'Up', 'Enter') } {
            param($Items, $A, $B)
            Select-AfMenuItem -Title 'T' -Items $Items -ReadKey $A | Should -Be 'Q'
            Select-AfMenuItem -Title 'T' -Items $Items -ReadKey $B | Should -Be 'Q'
        }
    }

    It 'redraws the header with every key, so the screen never shows stale lines' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader 'Down', 'x', 'Enter') } {
            param($Items, $Keys)
            $script:Draws = 0
            Select-AfMenuItem -Title 'T' -Items $Items -Header { $script:Draws++ } -ReadKey $Keys | Should -Be '2'
            $script:Draws | Should -Be 3
        }
    }

    It 'picks an item by its number too, and shows its letter in brackets' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader '2'); Letter = (New-KeyReader 't') } {
            param($Keys, $Letter)
            $items = @(@{ Key = 'S'; Label = '&Scan' }, @{ Key = 'T'; Label = 'Se&ttings' }, @{ Key = 'Q'; Label = '&Quit' })
            $screen = Select-AfMenuItem -Title 'T' -Items $items -ReadKey $Keys 6>&1
            @($screen | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }) | Should -Be @('T')
            (@($screen | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | ForEach-Object { [string]$_.MessageData }) -join '' | Should -Match '2  Se\(t\)tings'
            Select-AfMenuItem -Title 'T' -Items $items -ReadKey $Letter 6>$null | Should -Be 'T'
        }
    }

    It 'picks the Back item on Esc when the menu has one' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader 'Down', 'Escape') } {
            param($Items, $Keys)
            Select-AfMenuItem -Title 'T' -Items $Items -EscapeKey 'Q' -ReadKey $Keys | Should -Be 'Q'
        }
    }

    It 'ignores unknown keys and keeps waiting' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items; Keys = (New-KeyReader 'x', 'Escape', '1') } {
            param($Items, $Keys)
            Select-AfMenuItem -Title 'T' -Items $Items -ReadKey $Keys | Should -Be '1'
        }
    }
}

Describe 'Select-AfMode' {
    It 'is Standard on Enter' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader 'Enter') } {
            param($Keys)
            Select-AfMode -ReadKey $Keys | Should -Be 'Standard'
        }
    }

    It 'is Technician only after the warning is answered with Y' {
        InModuleScope AutoFixer -Parameters @{ Yes = (New-KeyReader '2', 'y'); No = (New-KeyReader '2', 'n'); Lost = (New-KeyReader '2', 'x', 'z') } {
            param($Yes, $No, $Lost)
            Select-AfMode -ReadKey $Yes | Should -Be 'Technician'
            Select-AfMode -ReadKey $No | Should -Be 'Standard'
            Select-AfMode -ReadKey $Lost | Should -Be 'Standard'
        }
    }
}

Describe 'Invoke-AfMainMenu' {
    BeforeEach {
        Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue
        $script:Path = Join-Path $TestDrive 'settings.json'
        $script:Runs = Join-Path $TestDrive 'Runs'
        $script:Calls = [System.Collections.ArrayList]::new()
        $calls = $script:Calls
        $script:Scan = { param($show, $save) $null = $calls.Add("scan show=$show save=$save") }.GetNewClosure()
        $script:Open = { param($p) $null = $calls.Add("open $p") }.GetNewClosure()
    }

    It 'asks for the mode on first launch and saves it' {
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader 'Enter', 'q')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Standard'
        $script:Calls.Count | Should -Be 0
    }

    It 'does not ask for the mode again once it is saved' {
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader '2', 'y', 'q')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Technician'
        # Second start: the first key goes straight to the main menu.
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader '1', 'Enter', 'q')
        $script:Calls | Should -Be @('scan show=False save=False')
    }

    It 'says so when there is no report yet, and opens the newest one when there is' {
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader 'Enter', '3', 'q')
        $script:Calls.Count | Should -Be 0

        foreach ($run in '20261024-010000', '20261024-020000') {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:Runs $run) -Force
            Set-Content -Path (Join-Path $script:Runs "$run\report.html") -Value 'x'
        }
        (Get-Item (Join-Path $script:Runs '20261024-010000\report.html')).LastWriteTime = (Get-Date).AddHours(-1)
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader '3', 'q')
        $script:Calls[0] | Should -Match '20261024-020000'
    }

    It 'asks Y/N before every unredacted save, even with the setting on' {
        # Settings (4) > 3 (save unredacted) > Y > Back, then scan twice: Y, then N. Each scan waits for a key.
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', '4', '3', 'y', 'b', '1', 'y', 'Enter', '1', 'n', 'Enter', 'q')
        (Read-AfSettings -Path $script:Path).SaveSensitive | Should -BeTrue
        $script:Calls | Should -Be @('scan show=False save=True', 'scan show=False save=False')
    }

    It 'turns the on-screen switch on without a prompt' {
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', '4', '2', 'b', '1', 'Enter', 'q')
        $script:Calls | Should -Be @('scan show=True save=False')
    }

    It 'leaves Technician mode without a prompt, but enters it only after Y' {
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', '4', '1', 'n', 'b', 'q')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Standard'
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader '4', '1', 'y', 'b', 'q')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Technician'
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader '4', '1', 'b', 'q')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Standard'
    }

    It 'goes back from Settings and quits from the main menu on Esc' {
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', '4', 'Escape', 'Escape')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Standard'
        $script:Calls.Count | Should -Be 0
    }

    It 'quits from Settings and the first-launch screen only after Y, and from the main menu at once' {
        # Settings > Quit > N stays; Settings > Quit > Y ends the whole program.
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open `
            -ReadKey (New-KeyReader 'Enter', 't', 'q', 'n', 'q', 'y')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Standard'
        Remove-Item $script:Path
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader 'q', 'y')
        Test-Path $script:Path | Should -BeFalse
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -OpenAction $script:Open -ReadKey (New-KeyReader 'Enter', 'q')
        $script:Calls.Count | Should -Be 0
    }

    It 'returns to the menu when a scan fails' {
        $boom = { throw 'disk unreadable' }
        Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $boom -OpenAction $script:Open -ReadKey (New-KeyReader 'Enter', '1', 'Enter', 'q')
        (Read-AfSettings -Path $script:Path).Mode | Should -Be 'Standard'
    }
}
