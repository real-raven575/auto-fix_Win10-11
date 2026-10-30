# The progress panel (CRTV-0010: one bar row, words on top, done cells Black on
# Green, the rest White on DarkGray). Panels are built as rows of runs, so these
# tests read them without a console.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Get-AfBarFill' {
    It 'rounds down and stays inside the bar' {
        InModuleScope AutoFixer {
            Get-AfBarFill -Percent 0 -Width 74 | Should -Be 0
            Get-AfBarFill -Percent 50 -Width 74 | Should -Be 37
            Get-AfBarFill -Percent 99.9 -Width 74 | Should -Be 73
            Get-AfBarFill -Percent 100 -Width 74 | Should -Be 74
            Get-AfBarFill -Percent 140 -Width 74 | Should -Be 74
            Get-AfBarFill -Percent -5 -Width 74 | Should -Be 0
            Get-AfBarFill -Percent 50 -Width 0 | Should -Be 0
        }
    }
}

Describe 'Get-AfProgressKind' {
    It 'draws the panel only on a console that can show it' {
        InModuleScope AutoFixer {
            Get-AfProgressKind -OutputRedirected $false -Term '' -Width 80 | Should -Be 'Live'
            Get-AfProgressKind -OutputRedirected $false -Term '' -Width 60 | Should -Be 'Live'
            Get-AfProgressKind -OutputRedirected $true -Term '' -Width 80 | Should -Be 'Lines'
            Get-AfProgressKind -OutputRedirected $false -Term 'dumb' -Width 80 | Should -Be 'Lines'
            Get-AfProgressKind -OutputRedirected $false -Term '' -Width 40 | Should -Be 'Lines'
        }
    }
}

Describe 'New-AfProgressPanel' {
    It 'makes every row exactly the panel width, so it never wraps' {
        InModuleScope AutoFixer {
            foreach ($width in 78, 60) {
                foreach ($ascii in $false, $true) {
                    $long = 'x' * 200
                    $rows = New-AfProgressPanel -Title 'Repairing system files' -Lines @('Step 1 of 3: SFC', $long) -Percent 47 -Width $width -Ascii:$ascii
                    $rows.Count | Should -Be 5
                    foreach ($row in $rows) { (-join @($row | ForEach-Object { $_.Text })).Length | Should -Be $width }
                }
            }
        }
    }

    It 'colours done cells Black on Green and the rest White on DarkGray' {
        InModuleScope AutoFixer {
            $rows = New-AfProgressPanel -Title 'Scanning' -Lines @('Step 2 of 4: Event logs') -Percent 50 -Width 78
            $bar = @($rows[2] | Select-Object -Skip 1 | Select-Object -SkipLast 1)
            $bar[0].Fg | Should -Be 'Black'
            $bar[0].Bg | Should -Be 'Green'
            $bar[0].Text.Length | Should -Be 37
            $bar[1].Fg | Should -Be 'White'
            $bar[1].Bg | Should -Be 'DarkGray'
            $bar[1].Text.Length | Should -Be 37
            (-join @($bar | ForEach-Object { $_.Text })).Trim() | Should -Be '50%'
        }
    }

    It 'has no green at 0% and no grey at 100% or more' {
        InModuleScope AutoFixer {
            $empty = New-AfProgressPanel -Title 'Scanning' -Percent 0
            @($empty[1] | Where-Object { $_.Bg -eq 'Green' }).Count | Should -Be 0
            $full = New-AfProgressPanel -Title 'Scanning' -Percent 130
            @($full[1] | Where-Object { $_.Bg -eq 'DarkGray' }).Count | Should -Be 0
            (-join @($full[1] | ForEach-Object { $_.Text })) | Should -Match '100%'
            $almost = New-AfProgressPanel -Title 'Scanning' -Percent 99.9
            (-join @($almost[1] | ForEach-Object { $_.Text })) | Should -Match ' 99% '
            @($almost[1] | Where-Object { $_.Bg -eq 'DarkGray' }).Count | Should -Be 1
        }
    }

    It 'uses the mode colours for the frame and title' {
        InModuleScope AutoFixer {
            $standard = New-AfProgressPanel -Title 'Scanning' -Percent 10 -Mode 'Standard'
            $standard[0][0].Fg | Should -Be 'DarkCyan'
            $standard[0][1].Fg | Should -Be 'Cyan'
            $standard[0][1].Text | Should -Be ' SCANNING '
            $technician = New-AfProgressPanel -Title 'Scanning' -Percent 10 -Mode 'Technician'
            $technician[0][0].Fg | Should -Be 'DarkYellow'
            $technician[0][1].Fg | Should -Be 'Orange'
        }
    }

    It 'draws the Ascii panel with plain ASCII and the percent after the bar' {
        InModuleScope AutoFixer {
            $rows = New-AfProgressPanel -Title 'Scanning' -Lines @('Step 1 of 2') -Percent 50 -Width 78 -Ascii
            $text = @($rows | ForEach-Object { -join @($_ | ForEach-Object { $_.Text }) })
            foreach ($t in $text) { [int[]][char[]]$t | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty }
            $text[0] | Should -Match '^\+- SCANNING -+\+$'
            $text[2] | Should -Be ('| ' + ('#' * 34) + ('-' * 35) + '  50% |')
            $text[3] | Should -Match '^\+-+\+$'
        }
    }
}

Describe 'ConvertTo-AfPanelText' {
    It 'starts in column 2 and ends by clearing the rest of the line' {
        InModuleScope AutoFixer {
            $rows = New-AfProgressPanel -Title 'Scanning' -Percent 50 -Width 78
            $plain = ConvertTo-AfPanelText -Row $rows[1]
            $plain.Length | Should -Be 79
            $plain[0] | Should -Be ' '
            $e = [char]27
            $vt = ConvertTo-AfPanelText -Row $rows[1] -Vt
            $vt | Should -Match ([regex]::Escape("$e[0;30;102m"))
            $vt | Should -Match ([regex]::Escape("$e[0;97;100m"))
            $vt.EndsWith("$e[0m$e[K") | Should -BeTrue
        }
    }
}

Describe 'Progress view' {
    It 'writes only activity lines when the panel is off (redirected output)' {
        InModuleScope AutoFixer {
            Mock Write-Host { }
            $view = @{ Title = 'Scanning'; Mode = 'Standard'; Kind = 'Lines'; Ascii = $true; Color = 'None'; Width = 78; Shown = 0; Last = $null }
            Update-AfProgressView -View $view -Lines @('Step 1 of 2') -Percent 50
            Should -Invoke Write-Host -Times 0 -Exactly
            Write-AfProgressText -View $view -Text 'done line' -Color Green
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'done line' }
            Close-AfProgressView -View $view
            Should -Invoke Write-Host -Times 1 -Exactly
        }
    }

    It 'redraws in place and leaves nothing behind when closed' {
        InModuleScope AutoFixer {
            $script:written = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $script:written.Add([string]$Object) }
            Mock Enable-AfVirtualTerminal { $true }
            $e = [char]27
            $view = @{ Title = 'Scanning'; Mode = 'Standard'; Kind = 'Live'; Ascii = $false; Color = 'Vt'; Width = 78; Shown = 0; Last = $null }
            Update-AfProgressView -View $view -Lines @('Step 1 of 2', 'about 9s left') -Percent 10
            $view.Shown | Should -Be 5
            $script:written.Count | Should -Be 5
            $script:written.Clear()
            Update-AfProgressView -View $view -Lines @('Step 2 of 2', 'about 4s left') -Percent 60
            $script:written[0] | Should -Be "$e[0m$e[5F$e[J"
            $script:written.Count | Should -Be 6
            $script:written.Clear()
            Write-AfProgressText -View $view -Text 'step line' -Color Green
            $script:written[0] | Should -Be "$e[0m$e[5F$e[J"
            $script:written[1] | Should -Be 'step line'
            $script:written.Count | Should -Be 7
            $script:written.Clear()
            Close-AfProgressView -View $view
            $view.Shown | Should -Be 0
            $script:written[0] | Should -Be "$e[0m$e[5F$e[J"
            Close-AfProgressView -View $view
            $script:written.Count | Should -Be 1
        }
    }

    It 'is safe with no view at all' {
        InModuleScope AutoFixer {
            Mock Write-Host { }
            { Update-AfProgressView -View $null -Percent 5; Close-AfProgressView -View $null } | Should -Not -Throw
            Write-AfProgressText -View $null -Text 'line'
            Should -Invoke Write-Host -Times 1 -Exactly
        }
    }
}

Describe 'Stock progress bar' {
    It 'is no longer used anywhere in Auto-Fixer' {
        $root = Join-Path $PSScriptRoot '..\AutoFixer'
        $hits = Get-ChildItem -Path $root -Filter '*.ps1' -Recurse | Select-String -Pattern '^\s*[^#]*\bWrite-Progress\b'
        $hits | Should -BeNullOrEmpty
    }
}
