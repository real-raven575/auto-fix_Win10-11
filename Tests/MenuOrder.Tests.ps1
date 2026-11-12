# Menu order and fit: each menu lists its items in fix-it order (look first, then fix,
# lightest fix first), and every menu fits its box (14 rows; labels and tags end by column 50
# when the "What this does" panel is shown).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    # Runs a menu command with Select-AfMenuItem replaced, and returns what each menu was asked to show.
    function Get-MenuCall([string] $Command, [hashtable] $Params) {
        InModuleScope AutoFixer -Parameters @{ Command = $Command; Params = $Params } {
            param($Command, $Params)
            $script:Seen = [System.Collections.ArrayList]::new()
            Mock Select-AfMenuItem {
                $null = $script:Seen.Add([pscustomobject]@{ Title = $Title; Items = @($Items); Info = @($Info); HasPanel = [bool]$ItemInfo })
                switch ($Title) { 'Mode' { 'S' } 'Main menu' { 'Q' } default { 'B' } }
            }
            $null = & $Command @Params 6>$null
            $script:Seen
        }
    }
    function Get-Keys($Call) { @($Call.Items | ForEach-Object { [string]$_.Key }) -join ' ' }
    function New-TestSettings([string] $Mode) {
        [pscustomobject]@{ SchemaVersion = 1; Mode = $Mode; ShowSensitive = $false; SaveSensitive = $false; Online = $false; Style = 'Branded' }
    }
    # Checks the 14-row box and the label width rule for one menu call.
    function Assert-Fits($Call) {
        $right = 79
        if ($Call.HasPanel) { $right = 51 }
        $rows = InModuleScope AutoFixer -Parameters @{ C = $Call; R = $right } { param($C, $R) Get-AfMenuRowCount -Items $C.Items -Info $C.Info -Right $R }
        $rows | Should -BeLessOrEqual 14 -Because "$($Call.Title) must fit the 14-row box"
        foreach ($item in $Call.Items) {
            $label = [string]$item.Label
            $shown = $label.Length
            if ($label.Contains('&')) { $shown++ }
            $last = 9 + $shown
            if ($item.Tags) { $last = 12 + $shown + ([string]$item.Tags).Length }
            $last | Should -BeLessOrEqual ($right - 1) -Because "'$label' $($item.Tags) must end inside the $($Call.Title) box"
        }
    }
}

Describe 'Menu order' {
    It 'main menu: scan, report, repair, then each problem area, then tools' {
        $calls = Get-MenuCall 'Invoke-AfMainMenu' @{ SettingsPath = (Join-Path $TestDrive 'settings.json'); OutputRoot = (Join-Path $TestDrive 'Runs'); ScanAction = { }; ReadKey = { 'y' } }
        $main = @($calls | Where-Object Title -EQ 'Main menu')[0]
        Get-Keys $main | Should -Be 'S P R N O C X T A Q'
        @($main.Items | Where-Object Divider | ForEach-Object Key) -join ' ' | Should -Be 'R C'
        Assert-Fits $main
    }

    It 'Repair: Run all first, then the read-only checks, then the steps that change the PC' {
        $call = Get-MenuCall 'Invoke-AfRepairMenu' @{ Settings = (New-TestSettings 'Standard'); OutputRoot = $TestDrive; RunBatch = { } }
        Get-Keys $call[0] | Should -Be 'A K N V S R C B Q'
        @($call[0].Items | Where-Object Divider | ForEach-Object Key) -join ' ' | Should -Be 'A C'
        Assert-Fits $call[0]
    }

    It 'Network and domain: tools, checks, the common repair, then leaving (local admin first)' -TestCases @(
        @{ Mode = 'Standard'; Keys = 'W C B Q' }
        @{ Mode = 'Technician'; Keys = 'W C D S T J U L A P B Q' }
    ) {
        param($Mode, $Keys)
        $call = Get-MenuCall 'Invoke-AfNetworkMenu' @{ Settings = (New-TestSettings $Mode); OutputRoot = $TestDrive }
        Get-Keys $call[0] | Should -Be $Keys
        Assert-Fits $call[0]
    }

    It 'Network tools: look first, then fixes from the lightest to the heaviest' -TestCases @(
        @{ Mode = 'Standard'; Keys = 'S P L T O N F R B Q' }
        @{ Mode = 'Technician'; Keys = 'S P L T O N F R A W B Q' }
    ) {
        param($Mode, $Keys)
        $call = Get-MenuCall 'Invoke-AfNetToolsMenu' @{ Settings = (New-TestSettings $Mode); OutputRoot = $TestDrive }
        Get-Keys $call[0] | Should -Be $Keys
        @($call[0].Items | Where-Object Divider | ForEach-Object Key)[0] | Should -Be 'N'
        Assert-Fits $call[0]
    }

    It 'Settings: mode and style, going online, then the sensitive-data switches' {
        $call = Get-MenuCall 'Invoke-AfSettingsMenu' @{ Settings = (New-TestSettings 'Standard'); Path = (Join-Path $TestDrive 's.json') }
        Get-Keys $call[0] | Should -Be 'M Y G S V B Q'
        Assert-Fits $call[0]
    }
}

Describe 'Get-AfMenuRowCount' {
    It 'counts info lines, the blank line after them, items and dividers' {
        InModuleScope AutoFixer {
            $items = @(@{ Key = 'A'; Label = 'a'; Divider = $true }, @{ Key = 'B'; Label = 'b' })
            Get-AfMenuRowCount -Items $items -Info @('one line') -Right 51 | Should -Be 5
            Get-AfMenuRowCount -Items $items -Right 51 | Should -Be 3
        }
    }
}
