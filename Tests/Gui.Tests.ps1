# The Auto-Fixer window (layout B). The colour maths and menu.json checks run on any
# machine; loading the real window needs Windows and an STA thread (Windows PowerShell 5.1).

BeforeDiscovery {
    $script:CanLoadWindow = ([Environment]::OSVersion.Platform -eq 'Win32NT') -and ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
    $script:OnWindows = ([Environment]::OSVersion.Platform -eq 'Win32NT')
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Colour helpers' {
    It 'turns #RRGGBB into numbers and back' {
        InModuleScope AutoFixer {
            ConvertTo-AfRgb '#0067C0' | Should -Be @(0, 103, 192)
            ConvertTo-AfHex @(0, 103, 192) | Should -Be '#0067C0'
        }
    }

    It 'rejects a colour that is not #RRGGBB' {
        InModuleScope AutoFixer { { ConvertTo-AfRgb 'blue' } | Should -Throw }
    }

    It 'measures contrast the WCAG way' {
        InModuleScope AutoFixer {
            [math]::Round((Get-AfContrastRatio '#000000' '#FFFFFF'), 1) | Should -Be 21
            [math]::Round((Get-AfContrastRatio '#777777' '#777777'), 1) | Should -Be 1
        }
    }

    It 'reads the Windows accent DWORD (0xAABBGGRR) as #RRGGBB' {
        InModuleScope AutoFixer {
            ConvertFrom-AfAbgr -Value 0xFFD77800 | Should -Be '#0078D7'
            ConvertFrom-AfAbgr -Value 4278222848 | Should -Be '#008000'
        }
    }

    It 'follows the Windows app mode unless Settings picks Light or Dark' {
        InModuleScope AutoFixer {
            Resolve-AfThemeBase -Setting 'System' -AppsLight $true | Should -Be 'Light'
            Resolve-AfThemeBase -Setting 'System' -AppsLight $false | Should -Be 'Dark'
            Resolve-AfThemeBase -Setting 'Light' -AppsLight $false | Should -Be 'Light'
            Resolve-AfThemeBase -Setting 'Dark' -AppsLight $true | Should -Be 'Dark'
        }
    }
}

Describe 'Theme palette' {
    # Windows accent colours from the Personalization picker, light and dark ones.
    It 'keeps text on the accent readable (4.5:1) for <Accent> on <Base>' -ForEach @(
        foreach ($a in '#0067C0', '#FFB900', '#E81123', '#00CC6A', '#767676', '#FFFFFF', '#000000', '#881798', '#FF8C00') {
            foreach ($b in 'Light', 'Dark') { @{ Accent = $a; Base = $b } }
        }
    ) {
        InModuleScope AutoFixer -Parameters @{ Accent = $Accent; Base = $Base } {
            param($Accent, $Base)
            $p = Get-AfThemePalette -Base $Base -Accent $Accent
            Get-AfContrastRatio $p.Colors.AccentText $p.Colors.Accent | Should -BeGreaterOrEqual 4.5
            Get-AfContrastRatio $p.Colors.AccentOnSurface $p.Colors.Card | Should -BeGreaterOrEqual 4.5
        }
    }

    It 'keeps every tile group, tag and mode badge readable on <Base>' -ForEach @(@{ Base = 'Light' }, @{ Base = 'Dark' }) {
        InModuleScope AutoFixer -Parameters @{ Base = $Base } {
            param($Base)
            $p = Get-AfThemePalette -Base $Base
            foreach ($set in $p.Groups, $p.Tags, $p.Badges) {
                foreach ($k in $set.Keys) {
                    $r = Get-AfContrastRatio $set[$k].Fg $set[$k].Bg
                    if ($r -lt 4.5) { throw ('{0} {1} on {2} is only {3:N2}:1' -f $k, $set[$k].Fg, $set[$k].Bg, $r) }
                }
            }
            foreach ($bg in 'Card', 'Content', 'Window', 'StatusBar', 'RailSelected', 'CardHover') {
                Get-AfContrastRatio $p.Colors.Text $p.Colors[$bg] | Should -BeGreaterOrEqual 4.5
                Get-AfContrastRatio $p.Colors.Muted $p.Colors[$bg] | Should -BeGreaterOrEqual 4.5
            }
        }
    }

    It 'uses only Windows high contrast colours when high contrast is on' {
        InModuleScope AutoFixer {
            $p = Get-AfThemePalette -HighContrast -Accent '#FF0000'
            $p.Base | Should -Be 'HighContrast'
            foreach ($v in $p.Colors.Values) { $v | Should -Match '^sys:' }
            foreach ($v in $p.Tags.Values) { $v.Fg | Should -Match '^sys:'; $v.Bg | Should -Match '^sys:' }
        }
    }

    It 'gives every brush key the window asks for' {
        InModuleScope AutoFixer {
            $xaml = Get-Content -LiteralPath (Join-Path $script:AfGuiFolder 'MainWindow.xaml') -Raw
            $keys = [regex]::Matches($xaml, 'DynamicResource (\w+)Brush') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            foreach ($base in 'Light', 'Dark') {
                $p = Get-AfThemePalette -Base $base
                foreach ($k in $keys) { $p.Colors.Contains($k) | Should -BeTrue -Because "$k is used in MainWindow.xaml ($base)" }
            }
            $hc = Get-AfThemePalette -HighContrast
            foreach ($k in $keys) { $hc.Colors.Contains($k) | Should -BeTrue -Because "$k is used in MainWindow.xaml (high contrast)" }
        }
    }
}

Describe 'menu.json' {
    It 'has no problems' {
        InModuleScope AutoFixer { @(Test-AfGuiMenu) | Should -BeNullOrEmpty }
    }

    It 'lists every main menu task, with Printers marked SOON' {
        InModuleScope AutoFixer {
            $ids = @((Read-AfGuiMenu).Tiles.id)
            foreach ($id in 'scan', 'findings', 'repair', 'network', 'cleanup', 'office', 'printers', 'report', 'logs') { $ids | Should -Contain $id }
            @(((Read-AfGuiMenu).Tiles | Where-Object id -eq 'printers').tags) | Should -Contain 'SOON'
        }
    }

    It 'runs a task that changes the PC only through the "Are you sure?" dialog' {
        InModuleScope AutoFixer {
            foreach ($t in (Read-AfGuiMenu).Tiles) {
                if (@($t.tags) -contains 'CHG') { @('soon') + $script:AfGuiConfirmActions | Should -Contain $t.action -Because "$($t.id) changes the PC" }
            }
            # Repair and Clean up run here now; Network and Office stay in the console.
            ((Read-AfGuiMenu).Tiles | Where-Object id -eq 'repair').action | Should -Be 'repair'
            ((Read-AfGuiMenu).Tiles | Where-Object id -eq 'cleanup').action | Should -Be 'cleanup'
            ((Read-AfGuiMenu).Tiles | Where-Object id -eq 'network').action | Should -Be 'soon'
        }
    }

    It 'catches a clashing access key, an unknown colour group and a change step without a confirm' {
        InModuleScope AutoFixer {
            $bad = [pscustomobject]@{
                Tiles  = @(
                    [pscustomobject]@{ id = 'a'; label = '&Scan'; icon = 'E721'; group = 'safe'; tags = @(); action = 'scan'; description = 'x' }
                    [pscustomobject]@{ id = 'b'; label = '&Second'; icon = 'E721'; group = 'nope'; tags = @('CHG'); action = 'scan'; description = 'x' }
                )
                Footer = @()
            }
            $problems = @(Test-AfGuiMenu -Menu $bad)
            ($problems -join "`n") | Should -Match 'access key S'
            ($problems -join "`n") | Should -Match "group 'nope'"
            ($problems -join "`n") | Should -Match 'no confirm step'
        }
    }

    It 'turns console access keys into WPF ones' {
        InModuleScope AutoFixer {
            Get-AfAccessKey -Label 'Se&ttings' | Should -Be 'T'
            Get-AfAccessKey -Label 'Plain' | Should -BeNullOrEmpty
            ConvertTo-AfWpfLabel -Label 'Se&ttings' | Should -Be 'Se_ttings'
            ConvertTo-AfWpfLabel -Label 'a_b &c' | Should -Be 'a__b _c'
        }
    }
}

Describe 'Splash screen' {
    It 'shows Herd of Helpers, then Auto-Fixer, in 3.5 s when Branded' {
        InModuleScope AutoFixer {
            $plan = @(Get-AfGuiSplashPlan -Plain $false)
            $plan.Title | Should -Be @('Herd of Helpers', 'Auto-Fixer')
            ($plan | Measure-Object -Property Ms -Sum).Sum | Should -Be 3500
        }
    }

    It 'shows Auto-Fixer only when Plain' {
        InModuleScope AutoFixer {
            $plan = @(Get-AfGuiSplashPlan -Plain $true)
            $plan.Title | Should -Be @('Auto-Fixer')
            $plan[0].Ms | Should -Be 3500
        }
    }
}

Describe 'AUTO-FIXER wordmarks' {
    It 'uses the mosaic for Herd and the lockup for Plain, black on light and white on dark' {
        InModuleScope AutoFixer {
            Get-AfGuiWordmark -Plain $false -Base 'Light' | Should -Be 'wordmark-herd.png'
            Get-AfGuiWordmark -Plain $false -Base 'Dark' | Should -Be 'wordmark-herd.png'
            Get-AfGuiWordmark -Plain $true -Base 'Light' | Should -Be 'wordmark-plain-black.png'
            Get-AfGuiWordmark -Plain $true -Base 'Dark' | Should -Be 'wordmark-plain-white.png'
        }
    }

    It 'shows no picture in high contrast, so the text name shows instead' {
        InModuleScope AutoFixer {
            Get-AfGuiWordmark -Plain $false -Base 'HighContrast' | Should -BeNullOrEmpty
            Get-AfGuiWordmark -Plain $true -Base 'HighContrast' | Should -BeNullOrEmpty
        }
    }

    It 'ships <File> as a real PNG, wide enough to stay sharp at 200% scaling' -ForEach @(
        @{ File = 'wordmark-herd.png' }, @{ File = 'wordmark-plain-black.png' }, @{ File = 'wordmark-plain-white.png' }
    ) {
        $path = Join-Path $PSScriptRoot ('..\AutoFixer\Gui\Art\{0}' -f $File)
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0..7] | Should -Be @(137, 80, 78, 71, 13, 10, 26, 10)
        # IHDR width, big-endian, bytes 16-19. The left bar draws it at most 200 px wide.
        # Cast first: shifting a [byte] keeps only 8 bits.
        $width = ([int]$bytes[16] -shl 24) + ([int]$bytes[17] -shl 16) + ([int]$bytes[18] -shl 8) + [int]$bytes[19]
        $width | Should -BeGreaterOrEqual 400
    }

    It 'uses Wrench for Branded and the four-bar mark for Plain, dark versions on dark' {
        InModuleScope AutoFixer {
            Get-AfGuiLogo -Plain $false -Base 'Light' | Should -Be 'logo-branded.png'
            Get-AfGuiLogo -Plain $false -Base 'Dark' | Should -Be 'logo-branded-dark.png'
            Get-AfGuiLogo -Plain $true -Base 'Light' | Should -Be 'logo-plain-black.png'
            Get-AfGuiLogo -Plain $true -Base 'Dark' | Should -Be 'logo-plain-white.png'
            Get-AfGuiLogo -Plain $true -Base 'HighContrast' | Should -BeNullOrEmpty
            Get-AfGuiSplashArt -Name 'splash-herd' -Base 'Light' | Should -Be 'splash-herd.png'
            Get-AfGuiSplashArt -Name 'splash-herd' -Base 'Dark' | Should -Be 'splash-herd-dark.png'
            Get-AfGuiSplashArt -Name 'splash-herd' -Base 'HighContrast' | Should -BeNullOrEmpty
        }
    }

    It 'ships <File> as a real <Width>x<Height> PNG' -ForEach @(
        @{ File = 'logo-branded.png'; Width = 256; Height = 256 }
        @{ File = 'logo-branded-dark.png'; Width = 256; Height = 256 }
        @{ File = 'logo-plain-black.png'; Width = 256; Height = 256 }
        @{ File = 'logo-plain-white.png'; Width = 256; Height = 256 }
        @{ File = 'splash-herd.png'; Width = 960; Height = 360 }
        @{ File = 'splash-herd-dark.png'; Width = 960; Height = 360 }
    ) {
        $path = Join-Path $PSScriptRoot ('..\AutoFixer\Gui\Art\{0}' -f $File)
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0..7] | Should -Be @(137, 80, 78, 71, 13, 10, 26, 10)
        $w = ([int]$bytes[16] -shl 24) + ([int]$bytes[17] -shl 16) + ([int]$bytes[18] -shl 8) + [int]$bytes[19]
        $h = ([int]$bytes[20] -shl 24) + ([int]$bytes[21] -shl 16) + ([int]$bytes[22] -shl 8) + [int]$bytes[23]
        $w | Should -Be $Width
        $h | Should -Be $Height
    }

    It 'puts the wordmark on the Auto-Fixer splash card' {
        InModuleScope AutoFixer {
            $card = @(Get-AfGuiSplashPlan -Plain $true)[0]
            $card.Wordmark | Should -BeTrue
            @(Get-AfGuiSplashPlan -Plain $false)[0].Wordmark | Should -BeFalse
        }
    }
}

Describe 'Window warnings match the console' {
    It 'uses the console Technician warning word for word' {
        InModuleScope AutoFixer {
            $text = (Get-AfGuiText -Name 'Technician') -replace '\s+', ' '
            $text | Should -Match 'Choose it only if you know these tools and accept responsibility for the changes'
            $text | Should -Match 'Are you sure\?'
        }
    }

    It 'names the only internet destination before Online is turned on' {
        InModuleScope AutoFixer { Get-AfGuiText -Name 'Online' | Should -Match 'Windows Update \(Microsoft\)' }
    }
}

Describe 'Reading the Windows colours' -Skip:(-not $script:OnWindows) {
    It 'returns light/dark, an accent colour and high contrast' {
        InModuleScope AutoFixer {
            $t = Get-AfWindowsTheme
            $t.AppsLight | Should -BeOfType [bool]
            $t.Accent | Should -Match '^#[0-9A-F]{6}$'
            $t.HighContrast | Should -BeOfType [bool]
        }
    }
}

Describe 'The real window' -Skip:(-not $script:CanLoadWindow) {
    It 'loads every page, style and colour without showing anything' {
        @(Test-AfGuiLoad) | Should -BeNullOrEmpty
    }

    It 'draws scroll bars in theme colours, not the light Windows default' {
        InModuleScope AutoFixer {
            $parts = New-AfGuiWindow
            try {
                $style = $parts.Window.Resources[[System.Windows.Controls.Primitives.ScrollBar]]
                $style | Should -Not -BeNullOrEmpty
                $parts.Window.Resources['AfScrollThumb'] | Should -Not -BeNullOrEmpty
            }
            finally { $parts.Window.Close() }
        }
    }

    It 'leaves the first-run page for Home once a mode is picked, and the tiles work after' {
        InModuleScope AutoFixer {
            $parts = New-AfGuiWindow
            $ui = $parts.Ui
            $path = Join-Path ([IO.Path]::GetTempPath()) ('af-gui-firstrun-{0}.json' -f [guid]::NewGuid())
            try {
                $state = @{ Settings = $null; SettingsPath = $path; ThemeData = (Read-AfThemeFile); ThemeSignature = ''
                    Redactor = (New-AfRedactor); IsAdmin = $false; ForcePlain = $false; Page = ''; Syncing = $false; Note = $null
                }
                Set-AfGuiRailLock -Ui $ui -Locked $true
                $ui.Rail.IsHitTestVisible | Should -BeFalse
                Show-AfGuiPage -Ui $ui -State $state -Page 'PageFirstRun' -Title 'Welcome to Auto-Fixer'

                Complete-AfGuiFirstRun -Ui $ui -State $state -Mode 'Standard' -Style 'Plain'
                $state.Page | Should -Be 'PageHome'
                $ui.PageHome.Visibility | Should -Be 'Visible'
                $ui.PageFirstRun.Visibility | Should -Be 'Collapsed'
                $ui.Rail.IsHitTestVisible | Should -BeTrue
                $ui.Rail.IsEnabled | Should -BeTrue
                (Read-AfSettings -Path $path).Mode | Should -Be 'Standard'
                (Read-AfSettings -Path $path).Style | Should -Be 'Plain'
                $ui.WordmarkImage.Visibility | Should -Be 'Visible'
                $ui.AppNameText.Visibility | Should -Be 'Collapsed'
                # The Plain lockup carries the four-bar mark, so the separate logo stays hidden.
                $ui.LogoImage.Visibility | Should -Be 'Collapsed'
                $parts.Window.Icon | Should -Not -BeNullOrEmpty

                $state.Note = 'Opened the logs folder. Older runs are one folder up, in Runs.'
                Update-AfGuiChrome -Ui $ui -State $state
                $ui.StatusHost.Children.Count | Should -Be 6
                $about = [pscustomobject]@{ id = 'about'; label = '&About and credits'; icon = 'E946'; group = 'app'; tags = @(); action = 'about'; description = '' }
                Invoke-AfGuiItem -Ui $ui -State $state -Item $about
                $state.Page | Should -Be 'PageAbout'
                # The note belonged to the earlier click, so the next page clears it.
                $state.Note | Should -BeNullOrEmpty
                $ui.StatusHost.Children.Count | Should -Be 5
            }
            finally {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                $parts.Window.Close()
            }
        }
    }
}

Describe 'Repair, Clean up and Findings pages' -Skip:(-not $script:CanLoadWindow) {
    It 'builds a card per step and drive, and locks them without administrator rights' {
        InModuleScope AutoFixer {
            $parts = New-AfGuiWindow
            $ui = $parts.Ui
            $root = Join-Path ([IO.Path]::GetTempPath()) ('af-gui-pages-{0}' -f [guid]::NewGuid())
            try {
                $state = @{ Settings = [pscustomobject]@{ Mode = 'Standard'; Online = $false }; OutputRoot = $root; IsAdmin = $false; Redactor = (New-AfRedactor); CleanItems = $null }
                Show-AfGuiRepairPage -Ui $ui -State $state -Window $parts.Window
                # One card per SFC and DISM step, plus Run all.
                $ui.RepairHost.Children.Count | Should -Be ($script:AfRepairSteps.Count + 1)
                $ui.RepairAdminNote.Visibility | Should -Be 'Visible'
                Show-AfGuiCleanupPage -Ui $ui -State $state -Window $parts.Window
                $ui.CleanMeasure.IsEnabled | Should -BeFalse
                $ui.CleanRun.Visibility | Should -Be 'Collapsed'

                $state.IsAdmin = $true
                $state.CleanItems = @(
                    @{ Key = 'Temporary Files'; Label = 'Temporary files'; Group = 'Your files'; Size = 2048; Warn = 0; Checked = $true; Locked = $null }
                    @{ Key = 'Setup Log Files'; Label = 'Windows setup log files'; Group = 'System files (administrator)'; Size = $null; Warn = 0; Checked = $false; Locked = 'Locked: the scan reads them.' }
                )
                Show-AfGuiCleanItems -Ui $ui -State $state
                $boxes = @($ui.CleanItemsHost.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
                $boxes.Count | Should -Be 2
                $boxes[1].IsEnabled | Should -BeFalse
                $ui.CleanRun.IsEnabled | Should -BeTrue
                $ui.CleanTotal.Text | Should -Match '2\.0 KB'

                Show-AfGuiFindingsPage -Ui $ui -State $state -Window $parts.Window
                $ui.FindingsSummary.Text | Should -Match 'No saved scan yet'
            }
            finally { $parts.Window.Close() }
        }
    }
}

Describe 'Mouse wheel hand-off from the Activity box to the page' {
    It 'passes the wheel on only at the edge it is moving toward' -TestCases @(
        @{ Offset = 0; Scrollable = 100; Delta = 120; Pass = $true }    # top, wheel up
        @{ Offset = 0; Scrollable = 100; Delta = -120; Pass = $false }  # top, wheel down
        @{ Offset = 50; Scrollable = 100; Delta = 120; Pass = $false }  # middle
        @{ Offset = 50; Scrollable = 100; Delta = -120; Pass = $false } # middle
        @{ Offset = 100; Scrollable = 100; Delta = -120; Pass = $true } # bottom, wheel down
        @{ Offset = 100; Scrollable = 100; Delta = 120; Pass = $false } # bottom, wheel up
        @{ Offset = 0; Scrollable = 0; Delta = -120; Pass = $true }     # nothing to scroll
    ) {
        param($Offset, $Scrollable, $Delta, $Pass)
        InModuleScope AutoFixer -Parameters @{ O = $Offset; S = $Scrollable; D = $Delta } {
            param($O, $S, $D)
            Test-AfGuiPassScroll -Offset $O -Scrollable $S -Delta $D
        } | Should -Be $Pass
    }
}

Describe 'AutoFix-GUI.bat launcher' {
    BeforeAll { $script:Path = Join-Path $PSScriptRoot '..\AutoFix-GUI.bat' }

    It 'uses Windows line endings only' {
        $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($script:Path))
        ([regex]::Matches($text, '(?<!\r)\n')).Count | Should -Be 0
    }

    It 'starts the built-in Windows PowerShell by full path, single-threaded, with -Gui' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        $text | Should -Match ([regex]::Escape('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'))
        $text | Should -Match ([regex]::Escape('-STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-AutoFixer.ps1" -Gui'))
    }

    It 'asks for administrator rights only once' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        ([regex]::Matches($text, '-Verb RunAs')).Count | Should -Be 1
    }

    It 'only checks the window files in CI, since CI cannot show a window' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        $text | Should -Match 'if defined AUTOFIX_CI \('
        $text | Should -Match '-Gui -GuiCheckOnly'
    }
}
