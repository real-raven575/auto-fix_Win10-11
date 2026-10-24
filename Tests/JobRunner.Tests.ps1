BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Job Runner' {
    It 'weights progress by expected time, not step count' {
        InModuleScope AutoFixer {
            $steps = @(
                New-AfStep -Id a -Name 'Quick' -EstimatedSeconds 10 -Action { }
                New-AfStep -Id b -Name 'Slow' -EstimatedSeconds 90 -Action { }
            )
            $p = Get-AfProgress -Steps $steps -CompletedCount 1
            $p.Percent | Should -Be 10
            $p.SecondsLeft | Should -Be 90
        }
    }

    It 'keeps going after a step fails and reports every step' {
        InModuleScope AutoFixer {
            $events = New-Object System.Collections.Generic.List[hashtable]
            $steps = @(
                New-AfStep -Id ok -Name 'Works' -Action { 1; 2 }
                New-AfStep -Id bad -Name 'Breaks' -Action { throw 'boom' }
                New-AfStep -Id admin -Name 'Needs admin' -RequiresAdmin -Action { 3 }
                New-AfStep -Id args -Name 'Uses parameters' -Parameters @{ Value = 7 } -Action { param($Value) $Value * 2 }
            )
            $results = Invoke-AfSteps -Steps $steps -IsAdmin $false -OnEvent { param($e) $events.Add($e) }

            @($results | ForEach-Object Status) | Should -Be @('Done', 'Failed', 'Skipped', 'Done')
            $results[0].Count | Should -Be 2
            $results[1].Error | Should -Be 'boom'
            $results[3].Output | Should -Be @(14)
            $events.Count | Should -Be 8
            $events[-1].Percent | Should -Be 100
        }
    }
}
