# Battery health (Reports menu H): Windows' battery report and its summary. Read-only, and
# powercfg is never run here: a fake writes the report files, and logs go to TestDrive.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { if ($queue.Count) { $queue.Dequeue() } else { 'Escape' } }.GetNewClosure()
    }

    function New-BatteryXml([string] $Batteries) {
        return @"
<?xml version="1.0" encoding="utf-8"?>
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <SystemInformation><ComputerName>TESTPCNAME01</ComputerName></SystemInformation>
  <Batteries>$Batteries</Batteries>
</BatteryReport>
"@
    }

    $script:OneBattery = New-BatteryXml @'
<Battery><Id>DELL 7FHHV16</Id><Manufacturer>SMP</Manufacturer><SerialNumber>SN98765XYZ</SerialNumber><Chemistry>LiP</Chemistry><RelativeCapacity>0</RelativeCapacity><DesignCapacity>97003</DesignCapacity><FullChargeCapacity>72752</FullChargeCapacity><CycleCount>412</CycleCount></Battery>
'@
    $script:TwoBatteries = New-BatteryXml @'
<Battery><Id>45N1127</Id><Manufacturer>SANYO</Manufacturer><SerialNumber>AAA11122</SerialNumber><Chemistry>LION</Chemistry><DesignCapacity>23200</DesignCapacity><FullChargeCapacity>23900</FullChargeCapacity><CycleCount>0</CycleCount></Battery>
<Battery><Id>  LGC   45N1775 </Id><Manufacturer>LGC</Manufacturer><SerialNumber>BBB33344</SerialNumber><Chemistry>LION</Chemistry><DesignCapacity>23480</DesignCapacity><FullChargeCapacity>11000</FullChargeCapacity></Battery>
'@

    # A fake powercfg: writes -Html or -Xml to the /output path, and records each call.
    function New-FakePowercfg([System.Collections.ArrayList] $Calls, [string] $Xml, [int] $HtmlExit = 0, [int] $XmlExit = 0) {
        return {
            param($Arguments)
            $null = $Calls.Add(($Arguments -join ' '))
            $out = $Arguments[[array]::IndexOf($Arguments, '/output') + 1]
            if ($Arguments -contains '/xml') {
                if ($XmlExit -ne 0) { return [pscustomobject]@{ ExitCode = $XmlExit; Output = 'Unable to perform operation.' } }
                Set-Content -LiteralPath $out -Value $Xml -Encoding UTF8
                return [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            if ($HtmlExit -ne 0) { return [pscustomobject]@{ ExitCode = $HtmlExit; Output = 'Unable to perform operation.' } }
            Set-Content -LiteralPath $out -Value '<html>TESTPCNAME01 SN98765XYZ</html>'
            return [pscustomobject]@{ ExitCode = 0; Output = ('Battery life report saved to file path {0}.' -f $out) }
        }.GetNewClosure()
    }
}

Describe 'ConvertFrom-AfBatteryXml' {
    It 'reads each battery whatever the namespace, and treats 0 cycles as not reported' {
        $b = InModuleScope AutoFixer -Parameters @{ X = $script:TwoBatteries } { param($X) ConvertFrom-AfBatteryXml -Xml $X }
        @($b).Count | Should -Be 2
        $b[0].Name | Should -Be '45N1127'
        $b[0].Manufacturer | Should -Be 'SANYO'
        $b[0].DesignCapacity | Should -Be 23200
        $b[0].FullChargeCapacity | Should -Be 23900
        $b[0].CycleCount | Should -BeNullOrEmpty
        $b[1].CycleCount | Should -BeNullOrEmpty
        $b[0].Relative | Should -BeFalse
    }

    It 'returns nothing for an empty file or a report with no batteries' {
        InModuleScope AutoFixer -Parameters @{ X = (New-BatteryXml '') } {
            param($X)
            @(ConvertFrom-AfBatteryXml -Xml '').Count | Should -Be 0
            @(ConvertFrom-AfBatteryXml -Xml $X).Count | Should -Be 0
        }
    }
}

Describe 'Get-AfBatteryHealth' {
    It 'gives Good from 80%, Worn from 60%, Replace soon below, and never negative wear' {
        InModuleScope AutoFixer {
            (Get-AfBatteryHealth -DesignCapacity 100 -FullChargeCapacity 80).Verdict | Should -Be 'Good'
            (Get-AfBatteryHealth -DesignCapacity 100 -FullChargeCapacity 79).Verdict | Should -Be 'Worn'
            (Get-AfBatteryHealth -DesignCapacity 100 -FullChargeCapacity 60).Verdict | Should -Be 'Worn'
            (Get-AfBatteryHealth -DesignCapacity 100 -FullChargeCapacity 59).Verdict | Should -Be 'ReplaceSoon'
            $h = Get-AfBatteryHealth -DesignCapacity 97003 -FullChargeCapacity 72752
            $h.HealthPercent | Should -Be 75
            $h.WearPercent | Should -Be 25
            $new = Get-AfBatteryHealth -DesignCapacity 23200 -FullChargeCapacity 23900
            $new.WearPercent | Should -Be 0
            $new.Verdict | Should -Be 'Good'
        }
    }

    It 'is Unknown when the battery reports no capacity' {
        InModuleScope AutoFixer {
            (Get-AfBatteryHealth -DesignCapacity 0 -FullChargeCapacity 50).Verdict | Should -Be 'Unknown'
            (Get-AfBatteryHealth -DesignCapacity $null -FullChargeCapacity 50).Verdict | Should -Be 'Unknown'
            (Get-AfBatteryHealth -DesignCapacity 100 -FullChargeCapacity $null).Verdict | Should -Be 'Unknown'
        }
    }
}

Describe 'Get-AfBatteryModelText' {
    It 'joins manufacturer and name, without repeating the manufacturer or extra spaces' {
        InModuleScope AutoFixer {
            Get-AfBatteryModelText -Manufacturer 'SMP' -Name 'DELL 7FHHV16' | Should -Be 'SMP DELL 7FHHV16'
            Get-AfBatteryModelText -Manufacturer 'LGC' -Name '  LGC   45N1775 ' | Should -Be 'LGC 45N1775'
            Get-AfBatteryModelText -Manufacturer '' -Name '' | Should -Be 'not reported by the battery'
        }
    }
}

Describe 'Get-AfBatteryText' {
    It 'shows the model, capacities, health, wear and verdict, and never the serial' {
        $text = InModuleScope AutoFixer -Parameters @{ X = $script:OneBattery } {
            param($X)
            (Get-AfBatteryText -Batteries (ConvertFrom-AfBatteryXml -Xml $X)).Text -join "`n"
        }
        $text | Should -Match 'Model to search for : SMP DELL 7FHHV16'
        $text | Should -Match '97,003 mWh'
        $text | Should -Match '72,752 mWh'
        $text | Should -Match 'Charge cycles       : 412'
        $text | Should -Match '75% of its design capacity'
        $text | Should -Match 'Wear: 25%'
        $text | Should -Match 'Worn\. Plan a replacement'
        $text | Should -Match 'Serial              : hidden'
        $text | Should -Not -Match 'SN98765XYZ'
    }

    It 'numbers two batteries and marks the worn-out one Replace soon' {
        $lines = InModuleScope AutoFixer -Parameters @{ X = $script:TwoBatteries } {
            param($X)
            Get-AfBatteryText -Batteries (ConvertFrom-AfBatteryXml -Xml $X)
        }
        ($lines.Text -join "`n") | Should -Match 'Battery 2'
        @($lines | Where-Object { $_.Color -eq 'Warning' -and $_.Text -match 'Replace soon' }).Count | Should -Be 1
        ($lines.Text -join "`n") | Should -Not -Match 'AAA11122|BBB33344'
    }
}

Describe 'Show-AfBatteryReport' {
    BeforeEach {
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Opened = [System.Collections.ArrayList]::new()
        $opened = $script:Opened
        $script:Open = { param($p) $null = $opened.Add($p) }.GetNewClosure()
        $script:Root = Join-Path $TestDrive ('runs-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:Temp = Join-Path $TestDrive ('temp-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Temp -Force
    }

    It 'says a PC with no battery has nothing to report, and runs nothing' {
        $p = @{ Root = $script:Root; Run = (New-FakePowercfg -Calls $script:Calls -Xml $script:OneBattery); Open = $script:Open }
        $out = InModuleScope AutoFixer -Parameters $p {
            param($Root, $Run, $Open)
            Show-AfBatteryReport -OutputRoot $Root -GetBatteries { @() } -RunPowercfg $Run -OpenAction $Open -ReadKey { 'Y' } 6>&1 | Out-String
        }
        $out | Should -Match 'This PC has no battery'
        $script:Calls.Count | Should -Be 0
        $script:Opened.Count | Should -Be 0
    }

    It 'saves the report in the PC folder, deletes the XML, hides the serial in the log, and opens on Y' {
        $p = @{ Root = $script:Root; Temp = $script:Temp; Run = (New-FakePowercfg -Calls $script:Calls -Xml $script:OneBattery); Open = $script:Open }
        $r = InModuleScope AutoFixer -Parameters $p {
            param($Root, $Temp, $Run, $Open)
            Show-AfBatteryReport -OutputRoot $Root -TempFolder $Temp -GetBatteries { @([pscustomobject]@{ Name = 'x' }) } -RunPowercfg $Run -OpenAction $Open -ReadKey { 'Y' } 6>$null
        }
        $r.ReportPath | Should -Match 'PC-[A-Z2-9]{6}\\AF-[A-Z2-9]{6}-\d{8}-\d{6}Z-battery\.html$'
        Test-Path -LiteralPath $r.ReportPath | Should -BeTrue
        $script:Calls[0] | Should -Match '^/batteryreport /output .+-battery\.html$'
        $script:Calls[1] | Should -Match '^/batteryreport /xml /output '
        @(Get-ChildItem -LiteralPath $script:Temp).Count | Should -Be 0
        $log = Get-ChildItem -LiteralPath (Split-Path $r.ReportPath) -Filter '*-battery.log' | Select-Object -First 1
        $logText = Get-Content -LiteralPath $log.FullName -Raw
        $logText | Should -Match 'SMP DELL 7FHHV16'
        $logText | Should -Not -Match 'SN98765XYZ'
        $script:Opened[0] | Should -Be $r.ReportPath
    }

    It 'does not open the report on N' {
        $p = @{ Root = $script:Root; Temp = $script:Temp; Run = (New-FakePowercfg -Calls $script:Calls -Xml $script:OneBattery); Open = $script:Open }
        $out = InModuleScope AutoFixer -Parameters $p {
            param($Root, $Temp, $Run, $Open)
            Show-AfBatteryReport -OutputRoot $Root -TempFolder $Temp -GetBatteries { 1 } -RunPowercfg $Run -OpenAction $Open -ReadKey { 'N' } 6>&1 | Out-String
        }
        $out | Should -Match 'battery serial. Check it before you share it'
        $script:Opened.Count | Should -Be 0
    }

    It 'reports the exit code when Windows'' tool fails, and opens nothing' {
        $p = @{ Root = $script:Root; Temp = $script:Temp; Run = (New-FakePowercfg -Calls $script:Calls -Xml $script:OneBattery -HtmlExit 1 -XmlExit 1); Open = $script:Open }
        $out = InModuleScope AutoFixer -Parameters $p {
            param($Root, $Temp, $Run, $Open)
            Show-AfBatteryReport -OutputRoot $Root -TempFolder $Temp -GetBatteries { 1 } -RunPowercfg $Run -OpenAction $Open -ReadKey { 'Y' } 6>&1 | Out-String
        }
        $out | Should -Match 'Windows battery report failed: exit code 1'
        $out | Should -Match 'Unable to perform operation'
        $script:Opened.Count | Should -Be 0
    }

    It 'still runs when Windows cannot say whether there is a battery' {
        $p = @{ Root = $script:Root; Temp = $script:Temp; Run = (New-FakePowercfg -Calls $script:Calls -Xml $script:OneBattery); Open = $script:Open }
        $out = InModuleScope AutoFixer -Parameters $p {
            param($Root, $Temp, $Run, $Open)
            Show-AfBatteryReport -OutputRoot $Root -TempFolder $Temp -GetBatteries { throw 'WMI broken' } -RunPowercfg $Run -OpenAction $Open -ReadKey { 'N' } 6>&1 | Out-String
        }
        $out | Should -Match 'SMP DELL 7FHHV16'
        $script:Calls.Count | Should -Be 2
    }
}

Describe 'Reports menu: Battery health' {
    It 'runs Battery health with H and goes back with B' {
        $script:Ran = [System.Collections.ArrayList]::new()
        $ran = $script:Ran
        $p = @{ Root = (Join-Path $TestDrive 'menu'); Battery = { $null = $ran.Add('H') }.GetNewClosure(); Keys = (New-KeyReader 'h', 'b') }
        InModuleScope AutoFixer -Parameters $p {
            param($Root, $Battery, $Keys)
            Invoke-AfReportMenu -OutputRoot $Root -BatteryAction $Battery -ReadKey $Keys 6>$null
        }
        $script:Ran.Count | Should -Be 1
    }
}
