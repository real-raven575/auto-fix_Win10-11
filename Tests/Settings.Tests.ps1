BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Read-AfSettings and Save-AfSettings' {
    BeforeEach { $script:Path = Join-Path $TestDrive 'settings.json'; Remove-Item "$TestDrive\*" -Force -ErrorAction SilentlyContinue }

    It 'returns nothing when there is no file, so the menu asks for the mode' {
        Read-AfSettings -Path $script:Path | Should -BeNullOrEmpty
    }

    It 'starts in Standard mode with every switch off' {
        $d = InModuleScope AutoFixer { Get-AfDefaultSettings }
        $d.Mode | Should -Be 'Standard'
        $d.ShowSensitive | Should -BeFalse
        $d.SaveSensitive | Should -BeFalse
        $d.Online | Should -BeFalse
    }

    It 'reads back what it saved' {
        $s = InModuleScope AutoFixer { Get-AfDefaultSettings }
        $s.Mode = 'Technician'; $s.ShowSensitive = $true
        Save-AfSettings -Settings $s -Path $script:Path
        $back = Read-AfSettings -Path $script:Path
        $back.Mode | Should -Be 'Technician'
        $back.ShowSensitive | Should -BeTrue
        $back.SaveSensitive | Should -BeFalse
        $back.Online | Should -BeFalse
    }

    It 'writes only the mode and the switches' {
        $s = InModuleScope AutoFixer { Get-AfDefaultSettings }
        $s | Add-Member -NotePropertyName ComputerName -NotePropertyValue 'ALICE-PC'
        Save-AfSettings -Settings $s -Path $script:Path
        $text = Get-Content -LiteralPath $script:Path -Raw
        $text | Should -Not -Match 'ALICE'
        @((ConvertFrom-Json $text).PSObject.Properties.Name) | Should -Be @('schemaVersion', 'mode', 'showSensitive', 'saveSensitive', 'online')
    }

    It 'renames a damaged file to .bad instead of deleting it' {
        Set-Content -LiteralPath $script:Path -Value '{ not json'
        Read-AfSettings -Path $script:Path -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        $script:Path | Should -Not -Exist
        "$($script:Path).bad" | Should -Exist
        Get-Content -LiteralPath "$($script:Path).bad" -Raw | Should -Match 'not json'
    }

    It 'keeps an older .bad file when another damaged file turns up' {
        Set-Content -LiteralPath "$($script:Path).bad" -Value 'older'
        Set-Content -LiteralPath $script:Path -Value '{"mode":"Wizard","showSensitive":false,"saveSensitive":false,"online":false}'
        Read-AfSettings -Path $script:Path -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Content -LiteralPath "$($script:Path).bad" -Raw | Should -Match 'older'
        @(Get-ChildItem $TestDrive -Filter '*.bad').Count | Should -Be 2
    }

    It 'treats a switch that is not true or false as damaged' {
        Set-Content -LiteralPath $script:Path -Value '{"mode":"Standard","showSensitive":"yes","saveSensitive":false,"online":false}'
        Read-AfSettings -Path $script:Path -WarningAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
