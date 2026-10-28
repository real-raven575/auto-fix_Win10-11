# The Branded and Plain screens are built as an 80x25 grid before they are written,
# so these tests read the grid cell by cell. No console is needed.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
    function New-KeyReader([string[]] $Keys) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }
    # A console that can do everything: 80x25, VT on, nothing redirected.
    $script:Good = @{ NoColor = ''; Term = ''; SupportsVt = $true; OutputRedirected = $false; Width = 80; Height = 25 }
}

Describe 'Get-AfDisplayStyle' {
    It 'is Branded by default on a console that can draw it' {
        $d = InModuleScope AutoFixer { Get-AfDisplayStyle -SupportsVt $true -Width 80 -Height 25 }
        $d.Style | Should -Be 'Branded'
        $d.Color | Should -Be 'Vt'
        $d.Tile | Should -BeTrue
    }

    It 'is Plain, with the tile, when Settings says Plain or -Plain is given' {
        InModuleScope AutoFixer {
            $saved = Get-AfDisplayStyle -Preferred 'Plain' -SupportsVt $true -Width 80 -Height 25
            $switch = Get-AfDisplayStyle -Preferred 'Branded' -ForcePlain -SupportsVt $true -Width 120 -Height 30
            foreach ($d in $saved, $switch) {
                $d.Style | Should -Be 'Plain'
                $d.Color | Should -Be 'Vt'
                $d.Tile | Should -BeTrue
            }
        }
    }

    It 'falls back to Plain with the tile off for NO_COLOR and for consoles without VT' {
        InModuleScope AutoFixer {
            $noColor = Get-AfDisplayStyle -NoColor '1' -SupportsVt $true -Width 80 -Height 25
            $noColor.Style | Should -Be 'Plain'
            $noColor.Color | Should -Be 'None'
            $noColor.Tile | Should -BeFalse
            $noVt = Get-AfDisplayStyle -SupportsVt $false -Width 80 -Height 25
            $noVt.Style | Should -Be 'Plain'
            $noVt.Color | Should -Be 'Console'
            $noVt.Tile | Should -BeFalse
        }
    }

    It 'falls back to the Ascii screens for redirected output, TERM=dumb and small windows' {
        InModuleScope AutoFixer {
            (Get-AfDisplayStyle -OutputRedirected $true -SupportsVt $true -Width 80 -Height 25).Style | Should -Be 'Ascii'
            (Get-AfDisplayStyle -Term 'dumb' -SupportsVt $true -Width 80 -Height 25).Style | Should -Be 'Ascii'
            (Get-AfDisplayStyle -SupportsVt $true -Width 79 -Height 25).Style | Should -Be 'Ascii'
            (Get-AfDisplayStyle -SupportsVt $true -Width 80 -Height 24).Style | Should -Be 'Ascii'
        }
    }

    It 'is Ascii outside a menu session, so scripts and -NoMenu keep the plain text output' {
        InModuleScope AutoFixer { $script:AfUi = $null; (Get-AfDisplay).Style | Should -Be 'Ascii' }
    }
}

Describe 'The screen grid' {
    BeforeAll {
        $script:Items = @(
            @{ Key = 'S'; Label = 'Run a &scan (read-only)' }
            @{ Key = 'R'; Label = '&Repair Windows files'; Tags = '[ADMIN] [CHG]' }
            @{ Key = 'N'; Label = '&Network and domain'; Tags = '[CHG]' }
            @{ Key = 'P'; Label = 'Open the last re&port'; Divider = $true }
            @{ Key = 'T'; Label = 'Se&ttings' }
            @{ Key = 'A'; Label = '&About and credits' }
            @{ Key = 'Q'; Label = '&Quit' }
        )
    }

    It 'never writes in column 1 or 80 or on row 25, in any screen' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items } {
            param($Items)
            $script:AfUi = @{ IsAdmin = $true; Settings = (Get-AfDefaultSettings) }
            $screens = foreach ($style in 'Branded', 'Plain') {
                $d = Get-AfDisplayStyle -Preferred $style -SupportsVt $true -Width 80 -Height 25
                foreach ($mode in 'Standard', 'Technician') {
                    New-AfMenuScreen -Display $d -Title 'Main menu' -Items $Items -Index 1 -ItemInfo @{ R = @('x') } -Kind 'Main' -Mode $mode -EscapeLabel 'Quit'
                    New-AfMenuScreen -Display $d -Title 'About' -Items $Items -Info @(Get-AfAboutPanelLines) -Kind 'About' -BoxRight 57 -Mode $mode
                    New-AfSplashScreen -Mode $mode -Style $style
                }
            }
            $script:AfUi = $null
            foreach ($screen in $screens) {
                for ($r = 1; $r -le 25; $r++) {
                    $screen.Ch[$r][1] | Should -Be ' '
                    $screen.Ch[$r][80] | Should -Be ' '
                }
                (-join $screen.Ch[25]).Trim() | Should -BeNullOrEmpty
            }
        }
    }

    It 'draws the 8x4 tile on the open background' {
        InModuleScope AutoFixer {
            $screen = New-AfScreen
            Add-AfTile -Screen $screen
            for ($r = 5; $r -le 21; $r++) {
                $expected = -join (2..79 | ForEach-Object { $script:AfTile[($r - 5) % 4][($_ - 2) % 8] })
                (-join $screen.Ch[$r][2..79]) | Should -Be $expected
            }
            (-join $screen.Ch[4]).Trim() | Should -BeNullOrEmpty
            (-join $screen.Ch[22]).Trim() | Should -BeNullOrEmpty
        }
    }

    It 'hides 4 faces on the main menu (3 in Technician), 4 on other menus and 2 on About, all Branded only' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items } {
            param($Items)
            $script:AfUi = @{ IsAdmin = $false }
            $count = { param($s) $n = 0; for ($r = 5; $r -le 21; $r++) { $n += ([regex]::Matches((-join $s.Ch[$r]), [regex]::Escape($script:AfFace))).Count }; $n }
            $branded = Get-AfDisplayStyle -SupportsVt $true -Width 80 -Height 25
            $plain = Get-AfDisplayStyle -Preferred 'Plain' -SupportsVt $true -Width 80 -Height 25
            & $count (New-AfMenuScreen -Display $branded -Title 'Main menu' -Items $Items -ItemInfo @{} -Kind 'Main' -Mode 'Standard') | Should -Be 4
            & $count (New-AfMenuScreen -Display $branded -Title 'Main menu' -Items $Items -ItemInfo @{} -Kind 'Main' -Mode 'Technician') | Should -Be 3
            & $count (New-AfMenuScreen -Display $branded -Title 'Settings' -Items $Items -ItemInfo @{} -Kind 'Menu') | Should -Be 4
            & $count (New-AfMenuScreen -Display $branded -Title 'About' -Items $Items[0..3] -Info @(Get-AfAboutPanelLines) -Kind 'About' -BoxRight 57) | Should -Be 2
            & $count (New-AfMenuScreen -Display $plain -Title 'Main menu' -Items $Items -ItemInfo @{} -Kind 'Main') | Should -Be 0
            $script:AfUi = $null
        }
    }

    It 'puts a face only on a cross that is fully showing, and never twice on one spot' {
        InModuleScope AutoFixer {
            $screen = New-AfScreen
            Add-AfTile -Screen $screen
            # Cover one cell beside the cross at (9, 27): that spot must be skipped.
            Set-AfText -Screen $screen -Row 9 -Col 29 -Text 'x'
            Add-AfFaces -Screen $screen -Spots @(@(9, 27), @(13, 43), @(13, 43), @(7, 15), @(5, 3)) | Should -Be 2
            (-join $screen.Ch[13][40..46]) | Should -Be $script:AfFace
            $screen.Ch[14][43] | Should -Be ' '
            (-join $screen.Ch[9][26..28]) | Should -Be '_|_'
        }
    }

    It 'keeps the Plain look free of character art' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items } {
            param($Items)
            $script:AfUi = @{ IsAdmin = $true }
            $plain = Get-AfDisplayStyle -Preferred 'Plain' -SupportsVt $true -Width 80 -Height 25
            $g = $script:AfGlyph
            $screens = @(
                New-AfMenuScreen -Display $plain -Title 'About' -Items $Items -Info @(Get-AfAboutPanelLines) -Kind 'About' -BoxRight 57
                New-AfSplashScreen -Style 'Plain'
            )
            $script:AfUi = $null
            foreach ($screen in $screens) {
                $text = -join (1..24 | ForEach-Object { -join $screen.Ch[$_] })
                $text | Should -Not -Match ([regex]::Escape([string]$g.Upper))
                $text | Should -Not -Match ([regex]::Escape([string]$g.Lower))
                $text | Should -Not -Match ([regex]::Escape($script:AfFace))
            }
        }
    }

    It 'shows the banner, mode badge, rights and switches, with the letter of each item in brackets' {
        InModuleScope AutoFixer -Parameters @{ Items = $script:Items } {
            param($Items)
            $settings = Get-AfDefaultSettings
            $settings.Online = $true
            $script:AfUi = @{ IsAdmin = $false; Settings = $settings }
            $d = Get-AfDisplayStyle -SupportsVt $true -Width 80 -Height 25
            $screen = New-AfMenuScreen -Display $d -Title 'Main menu' -Items $Items -Index 1 -ItemInfo @{ R = @('Checks and repairs Windows system files.') } -Kind 'Main' -Mode 'Technician' -EscapeLabel 'Quit'
            $script:AfUi = $null
            $row = { param($r) -join $screen.Ch[$r] }
            & $row 2 | Should -Match ('Auto-Fixer {0}' -f [regex]::Escape($script:AfVersion))
            & $row 2 | Should -Match 'TECHNICIAN'
            & $row 4 | Should -Match 'NOT ADMIN'
            & $row 4 | Should -Match 'Online: ON'
            & $row 4 | Should -Match 'Redaction: ON'
            & $row 6 | Should -Match 'MAIN MENU'
            & $row 6 | Should -Match 'WHAT THIS DOES'
            & $row 8 | Should -Match ('{0}  2  \(R\)epair Windows files   \[ADMIN\] \[CHG\]' -f [regex]::Escape([string]$script:AfGlyph.Pointer))
            & $row 7 | Should -Match 'Checks and repairs'
            # The divider sits under item 4, Open the last report.
            $screen.Ch[11][2] | Should -Be $script:AfGlyph.TeeLeft
            & $row 23 | Should -Match '\[Enter\]Select'
        }
    }

    It 'builds the splash wordmark 78 columns wide, with a fill mask of the same shape' {
        InModuleScope AutoFixer {
            $script:AfWordmark.Count | Should -Be 7
            $script:AfWordmarkFill.Count | Should -Be 7
            foreach ($line in $script:AfWordmark + $script:AfWordmarkFill) { $line.Length | Should -Be 78 }
            # Branded fills the letters; NO_COLOR draws the outline only.
            $filled = New-AfSplashScreen -Mode 'Standard'
            $filled.Bg[4][3] | Should -Be 'DarkBlue'
            (New-AfSplashScreen -Mode 'Technician').Bg[4][3] | Should -Be 'DarkRed'
            (New-AfSplashScreen -Fill $false).Bg[4][3] | Should -Be 'Black'
            (-join $filled.Ch[3][2..79]) | Should -Be $script:AfWordmark[0]
        }
    }

    It 'turns two pixel rows into one row of half blocks' {
        InModuleScope AutoFixer {
            $g = $script:AfGlyph
            $screen = New-AfScreen
            Add-AfPixelArt -Screen $screen -Pixels @('C.CS', 'CC.B') -Row 3 -Col 10
            $screen.Ch[3][10] | Should -Be $g.Full
            $screen.Ch[3][11] | Should -Be $g.Lower
            $screen.Fg[3][11] | Should -Be 'DarkCyan'
            $screen.Ch[3][12] | Should -Be $g.Upper
            $screen.Ch[3][13] | Should -Be $g.Upper
            $screen.Fg[3][13] | Should -Be 'Yellow'
            $screen.Bg[3][13] | Should -Be 'Cyan'
            foreach ($art in $script:AfIconArt, $script:AfWrenchArt) {
                @($art | ForEach-Object { $_.Length } | Select-Object -Unique).Count | Should -Be 1
                $art.Count % 2 | Should -Be 0
            }
            $script:AfIconArt[0].Length | Should -Be 8
            $script:AfWrenchArt[0].Length | Should -Be 18
        }
    }
}

Describe 'ConvertTo-AfVtText' {
    It 'uses 24-bit orange in Technician and leaves the cursor on row 25' {
        InModuleScope AutoFixer {
            $script:AfUi = @{ IsAdmin = $true }
            $d = Get-AfDisplayStyle -SupportsVt $true -Width 80 -Height 25
            $items = @(@{ Key = 'Q'; Label = '&Quit' })
            $tech = ConvertTo-AfVtText -Screen (New-AfMenuScreen -Display $d -Title 'T' -Items $items -Mode 'Technician')
            $std = ConvertTo-AfVtText -Screen (New-AfMenuScreen -Display $d -Title 'T' -Items $items -Mode 'Standard')
            $script:AfUi = $null
            $tech | Should -Match ([regex]::Escape('38;2;240;136;42'))
            $std | Should -Not -Match ([regex]::Escape('38;2;240;136;42'))
            $std | Should -Match ([regex]::Escape("$([char]27)[25;1H"))
        }
    }

    It 'leaves the cursor on row 6 for the work screen, under the banner' {
        InModuleScope AutoFixer {
            $screen = New-AfScreen
            Add-AfBannerArea -Screen $screen -Style 'Plain'
            $text = ConvertTo-AfVtText -Screen $screen -LastRow 5 -WorkTop
            $text | Should -Match ([regex]::Escape("$([char]27)[6;1H"))
            $text | Should -Not -Match ([regex]::Escape("$([char]27)[7;1H"))
        }
    }
}

Describe 'Write-AfScreen without VT' {
    It 'writes plain lines for NO_COLOR, with no escape codes' {
        InModuleScope AutoFixer {
            $screen = New-AfScreen
            Set-AfText -Screen $screen -Row 2 -Col 3 -Text 'hello'
            $d = Get-AfDisplayStyle -NoColor '1' -SupportsVt $true -Width 80 -Height 25
            $out = @(Write-AfScreen -Screen $screen -Display $d 6>&1 | ForEach-Object { [string]$_.MessageData })
            $out.Count | Should -Be 24
            $out[1] | Should -Be '  hello'
            ($out -join '') | Should -Not -Match ([regex]::Escape([string][char]27))
        }
    }
}

Describe 'Menus in the Branded look' {
    BeforeEach {
        Remove-Item "$TestDrive\*" -Recurse -Force -ErrorAction SilentlyContinue
        $script:Path = Join-Path $TestDrive 'settings.json'
        $script:Runs = Join-Path $TestDrive 'Runs'
        $script:Calls = [System.Collections.ArrayList]::new()
        $calls = $script:Calls
        $script:Scan = { param($show, $save) $null = $calls.Add("scan show=$show save=$save") }.GetNewClosure()
    }

    It 'work with the same keys as the Ascii screens, and draw with VT codes' {
        $out = Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -ConsoleFacts $script:Good `
            -ReadKey (New-KeyReader 'Enter', 'Down', 'Up', '1', 'Enter', 'q', 'y') 6>&1
        $script:Calls | Should -Be @('scan show=False save=False')
        (($out | ForEach-Object { [string]$_.MessageData }) -join '') | Should -Match ([regex]::Escape("$([char]27)[1;1H"))
    }

    It 'switch between Branded and Plain under Settings and save the choice' {
        $null = Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -ConsoleFacts $script:Good `
            -ReadKey (New-KeyReader 'Enter', 't', 'y', 'b', 'q', 'y') 6>&1
        (Read-AfSettings -Path $script:Path).Style | Should -Be 'Plain'
        $null = Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -ConsoleFacts $script:Good `
            -ReadKey (New-KeyReader 't', 'y', 'b', 'q', 'y') 6>&1
        (Read-AfSettings -Path $script:Path).Style | Should -Be 'Branded'
    }

    It 'keep -Plain to this run: the saved style does not change' {
        $null = Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -ConsoleFacts $script:Good -Plain `
            -ReadKey (New-KeyReader 'Enter', 'q', 'y') 6>&1
        (Read-AfSettings -Path $script:Path).Style | Should -Be 'Branded'
    }

    It 'run every screen without errors in each fallback' {
        $consoles = @(
            $script:Good
            @{ NoColor = '1'; Term = ''; SupportsVt = $true; OutputRedirected = $false; Width = 80; Height = 25 }
            @{ NoColor = ''; Term = ''; SupportsVt = $false; OutputRedirected = $false; Width = 80; Height = 25 }
            @{ NoColor = ''; Term = 'dumb'; SupportsVt = $true; OutputRedirected = $false; Width = 80; Height = 25 }
        )
        foreach ($facts in $consoles) {
            Remove-Item $script:Path -ErrorAction SilentlyContinue
            # Mode, Settings and its style switch, About with both pages, the empty report, a scan, quit.
            $keys = New-KeyReader 'Enter', '5', '5', 'b', '6', 'w', 'Escape', 'l', 'Escape', 'b', '3', 'b', '4', '1', 'x', 'q', 'y'
            { $null = Invoke-AfMainMenu -SettingsPath $script:Path -OutputRoot $script:Runs -ScanAction $script:Scan -ConsoleFacts $facts -ReadKey $keys 6>&1 } | Should -Not -Throw
        }
        $script:Calls.Count | Should -Be 4
        InModuleScope AutoFixer { $script:AfUi | Should -BeNullOrEmpty }
    }
}
