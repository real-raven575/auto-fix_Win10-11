# The About screen and docs/CREDITS.md. Keys are fed from a queue, as in Menu.Tests.ps1.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    $script:Root = Join-Path $PSScriptRoot '..'
    function New-KeyReader([string[]] $Keys) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }
}

Describe 'Credits' {
    It 'uses the credits line exactly as raven575 set it' {
        InModuleScope AutoFixer {
            $script:AfCreditsLine | Should -BeExactly 'raven575, Wrench of TEAM Auto-Fixer & Inkwell of TEAM Creative "Herd of Helpers"'
        }
    }

    It 'credits every Windows program the code runs' {
        # A new .exe in the code without a credit fails here. Comments are skipped.
        $files = @(Get-ChildItem (Join-Path $script:Root 'AutoFixer') -Recurse -Filter '*.ps1') +
            @(Get-Item (Join-Path $script:Root 'Start-AutoFixer.ps1'), (Join-Path $script:Root 'AutoFix.bat'))
        $called = @(foreach ($file in $files) {
                foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                    if ($line -match '^\s*(#|rem\b)') { continue }
                    [regex]::Matches($line, '(?<![\w$.])[a-z0-9]+\.exe\b') | ForEach-Object { $_.Value }
                }
            }) | Sort-Object -Unique
        $called | Should -Contain 'sfc.exe'
        $credited = @(InModuleScope AutoFixer { Get-AfCredits | ForEach-Object Program })
        foreach ($exe in $called) { $credited | Should -Contain $exe -Because "$exe is run by the code" }
    }

    It 'lists the same names and credits line in docs/CREDITS.md' {
        $doc = Get-Content -LiteralPath (Join-Path $script:Root 'docs\CREDITS.md') -Raw
        $line = InModuleScope AutoFixer { $script:AfCreditsLine }
        $doc.Contains($line) | Should -BeTrue
        foreach ($credit in @(InModuleScope AutoFixer { Get-AfCredits })) {
            $doc.Contains($credit.Name) | Should -BeTrue -Because "$($credit.Name) is on the About screen"
            if ($credit.Program) { $doc.Contains($credit.Program) | Should -BeTrue -Because "$($credit.Program) is on the About screen" }
        }
    }

    It 'fits every About and credits line in an 80-column console' {
        InModuleScope AutoFixer {
            foreach ($line in @(Get-AfAboutLines) + @(Get-AfCreditLines)) { $line.Length | Should -BeLessOrEqual 79 -Because $line }
        }
    }

    It 'wraps the credits line at spaces without changing a word' {
        InModuleScope AutoFixer {
            $parts = @(Split-AfText -Text $script:AfCreditsLine -Width 62)
            $parts.Count | Should -BeGreaterThan 1
            ($parts -join ' ') | Should -BeExactly $script:AfCreditsLine
        }
    }

    It 'shows the LICENSE file as it is, and says where to find it when it is missing' {
        $license = Get-Content -LiteralPath (Join-Path $script:Root 'LICENSE')
        $shown = @(InModuleScope AutoFixer { Get-AfLicenseLines })
        ($shown -join "`n") | Should -BeExactly ($license -join "`n")
        $missing = @(InModuleScope AutoFixer -Parameters @{ Path = (Join-Path $TestDrive 'none') } { param($Path) Get-AfLicenseLines -Path $Path })
        ($missing -join ' ') | Should -Match 'MIT License'
    }
}

Describe 'Invoke-AfAboutMenu' {
    It 'opens the tools list and the license, and goes back on B and Esc' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader 'w', 'Escape', 'l', 'Escape', 'b'); Esc = (New-KeyReader 'Escape') } {
            param($Keys, $Esc)
            $script:AfQuitRequested = $false
            Invoke-AfAboutMenu -ReadKey $Keys 6>$null
            Invoke-AfAboutMenu -ReadKey $Esc 6>$null
            $script:AfQuitRequested | Should -BeFalse
        }
    }

    It 'pages through the tools list one screen at a time' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader 'x', 'x', 'x') } {
            param($Keys)
            $script:Pages = 0
            Show-AfPagedLines -Lines @(1..45 | ForEach-Object { "line $_" }) -PageSize 18 -Header { $script:Pages++ } -ReadKey $Keys 6>$null
            $script:Pages | Should -Be 3
        }
    }

    It 'quits only after Y' {
        InModuleScope AutoFixer -Parameters @{ No = (New-KeyReader 'q', 'n', 'b'); Yes = (New-KeyReader 'q', 'y') } {
            param($No, $Yes)
            $script:AfQuitRequested = $false
            Invoke-AfAboutMenu -ReadKey $No 6>$null
            $script:AfQuitRequested | Should -BeFalse
            Invoke-AfAboutMenu -ReadKey $Yes 6>$null
            $script:AfQuitRequested | Should -BeTrue
        }
    }

    It 'opens from the main menu with A and with 5, and Quit is now 6' {
        Mock Invoke-AfAboutMenu -ModuleName AutoFixer -MockWith { }
        $path = Join-Path $TestDrive 'settings.json'
        Invoke-AfMainMenu -SettingsPath $path -OutputRoot (Join-Path $TestDrive 'Runs') -ScanAction { } -ReadKey (New-KeyReader 'Enter', 'a', '5', '6') 6>$null
        Should -Invoke Invoke-AfAboutMenu -ModuleName AutoFixer -Times 2 -Exactly
    }
}
