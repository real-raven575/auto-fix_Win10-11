# Remove or install Office. Only the pure helpers and the menu gating are tested: nothing is
# removed, installed or downloaded here, and a key queue that runs dry fails the test.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    function New-KeyReader([string[]] $Keys = @()) {
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        return { $queue.Dequeue() }.GetNewClosure()
    }
    function New-TestSettings([string] $Mode = 'Technician', [bool] $Online = $false, [bool] $Addons = $false) {
        [pscustomobject]@{ SchemaVersion = 1; Mode = $Mode; ShowSensitive = $false; SaveSensitive = $false; Online = $Online; OnlineAddons = $Addons; Style = 'Branded' }
    }
}

Describe 'Split-AfUninstallCommand' {
    It 'splits the Click-to-Run command and makes it silent' {
        $r = InModuleScope AutoFixer { Split-AfUninstallCommand -Command '"C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe" scenario=install scenariosubtype=ARP sourcetype=None productstoremove=O365ProPlusRetail.16_en-us_x-none culture=en-us version.16=16.0' }
        $r.Exe | Should -Be 'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
        $r.Arguments | Should -Match '^scenario=install .*version\.16=16\.0 DisplayLevel=False$'
    }

    It 'returns nothing for a command that is not quoted' {
        InModuleScope AutoFixer { Split-AfUninstallCommand -Command 'MsiExec.exe /X{00000000-0000-0000-0000-000000000000}' } | Should -BeNullOrEmpty
        InModuleScope AutoFixer { Split-AfUninstallCommand -Command '' } | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-AfProductKey' {
    # Made-up text in the shape of a key; not a real key.
    It 'normalises spaces, dashes and case to five groups of five' {
        InModuleScope AutoFixer { ConvertTo-AfProductKey -Text ' aaaaa bbbbb-ccccc ddddd-11111 ' } | Should -BeExactly 'AAAAA-BBBBB-CCCCC-DDDDD-11111'
    }

    It 'refuses the wrong length or other characters' {
        foreach ($t in 'AAAAA-BBBBB-CCCCC-DDDDD', 'AAAAA-BBBBB-CCCCC-DDDDD-1111!', '') {
            InModuleScope AutoFixer -Parameters @{ T = $t } { param($T) ConvertTo-AfProductKey -Text $T } | Should -BeExactly '' -Because $t
        }
    }
}

Describe 'Read-AfOsppStatus' {
    It 'reads one row per licence block and never more than the last 5 characters' {
        $text = @'
---Processing--------------------------
---------------------------------------
PRODUCT ID: 00000-00000-00000-AA000
SKU ID: 00000000-0000-0000-0000-000000000000
LICENSE NAME: Office 21, Office21ProPlus2021VL_KMS_Client_AE edition
LICENSE DESCRIPTION: Office 21, VOLUME_KMSCLIENT channel
LICENSE STATUS:  ---LICENSED---
Last 5 characters of installed product key: 11111
---------------------------------------
PRODUCT ID: 00000-00000-00000-AA001
LICENSE NAME: Office 21, Office21VisioPro2021VL_MAK_AE edition
LICENSE STATUS:  ---NOTIFICATIONS---
ERROR CODE: 0xC004F074
Last 5 characters of installed product key: 22222
---------------------------------------
---Exiting-----------------------------
'@
        $rows = @(InModuleScope AutoFixer -Parameters @{ T = $text } { param($T) Read-AfOsppStatus -Text $T })
        $rows.Count | Should -Be 2
        $rows[0].Last5 | Should -Be '11111'
        $rows[0].Licensed | Should -BeTrue
        $rows[0].Error | Should -Be ''
        $rows[1].Last5 | Should -Be '22222'
        $rows[1].Licensed | Should -BeFalse
        $rows[1].Error | Should -Be '0xC004F074'
        $rows[1].Name | Should -Match 'VisioPro'
    }

    It 'returns nothing when no key is installed' {
        @(InModuleScope AutoFixer { Read-AfOsppStatus -Text '<No installed product keys detected>' }).Count | Should -Be 0
    }
}

Describe 'Get-AfInstallerKind' {
    It 'knows a program, an ISO and anything else from the first bytes' {
        $exe = [byte[]](0x4D, 0x5A, 0x90, 0x00)
        $iso = [byte[]]::new(34000)
        [Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($iso, 32769)
        $html = [Text.Encoding]::ASCII.GetBytes('<!DOCTYPE html>')
        InModuleScope AutoFixer -Parameters @{ B = $exe } { param($B) Get-AfInstallerKind -Bytes $B } | Should -Be 'exe'
        InModuleScope AutoFixer -Parameters @{ B = $iso } { param($B) Get-AfInstallerKind -Bytes $B } | Should -Be 'iso'
        InModuleScope AutoFixer -Parameters @{ B = $html } { param($B) Get-AfInstallerKind -Bytes $B } | Should -Be 'other'
    }
}

Describe 'Get-AfOdtLink' {
    It 'finds the Office Deployment Tool link on Microsoft''s page, and nothing elsewhere' {
        $html = '<a href="https://www.microsoft.com/x">x</a> <a href="https://download.microsoft.com/download/6c1eeb25/officedeploymenttool_18129-20030.exe">Download</a>'
        InModuleScope AutoFixer -Parameters @{ H = $html } { param($H) Get-AfOdtLink -Html $H } | Should -Be 'https://download.microsoft.com/download/6c1eeb25/officedeploymenttool_18129-20030.exe'
        InModuleScope AutoFixer { Get-AfOdtLink -Html '<a href="https://evil.example.com/officedeploymenttool.exe">' } | Should -Be ''
    }
}

Describe 'Get-AfGetHelpVerdict' {
    It 'passes the good exit codes and flags the rest, and error text even with code 0' {
        foreach ($c in 0, 66, 68) { InModuleScope AutoFixer -Parameters @{ C = $c } { param($C) Get-AfGetHelpVerdict -Text 'Scenario finished' -ExitCode $C } | Should -Be '' -Because "$c" }
        InModuleScope AutoFixer { Get-AfGetHelpVerdict -Text 'done' -ExitCode 6 } | Should -Match 'returned 6'
        InModuleScope AutoFixer { Get-AfGetHelpVerdict -Text 'Error: unknown scenario' -ExitCode 0 } | Should -Match 'reported an error'
    }
}

Describe 'Remove or install Office menu' {
    It 'is only in the Office and Outlook menu in Technician mode' {
        $calls = [System.Collections.ArrayList]::new()
        $os = { param($S) $null = $calls.Add('office') }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Standard'); O = $os; K = (New-KeyReader 'o', 'b') } {
            param($S, $O, $K) Invoke-AfOutlookMenu -Settings $S -OutputRoot $TestDrive -OfficeSetup $O -ReadKey $K 6>$null
        }
        $calls.Count | Should -Be 0
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician'); O = $os; K = (New-KeyReader 'o', 'b') } {
            param($S, $O, $K) Invoke-AfOutlookMenu -Settings $S -OutputRoot $TestDrive -OfficeSetup $O -ReadKey $K 6>$null
        }
        $calls | Should -Be @('office')
    }

    It 'removes only after two yeses' {
        $calls = [System.Collections.ArrayList]::new()
        $rm = { param($S) $null = $calls.Add('remove') }.GetNewClosure()
        # R, Y, N: stopped. Any key. R, Y, Y: runs. Any key, then B.
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings); R = $rm; K = (New-KeyReader 'r', 'y', 'n', 'x1', 'r', 'y', 'y', 'x2', 'b') } {
            param($S, $R, $K) Invoke-AfOfficeSetupMenu -Settings $S -OutputRoot $TestDrive -Remove $R -ReadKey $K 6>$null
        }
        $calls | Should -Be @('remove')
    }

    It 'asks for the installer first, with no extra key press' {
        $calls = [System.Collections.ArrayList]::new()
        $in = { param($S, $Src) $null = $calls.Add('install') }.GetNewClosure()
        # I without a source: a notice on the menu, then B. A spare key would be left over.
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings); I = $in; K = (New-KeyReader 'i', 'b') } {
            param($S, $I, $K) Invoke-AfOfficeSetupMenu -Settings $S -OutputRoot $TestDrive -Install $I -ReadKey $K 6>$null
        }
        $calls.Count | Should -Be 0
    }

    It 'shows a note instead of a download while the add-ons are off, and downloads once they are on' {
        $calls = [System.Collections.ArrayList]::new()
        $dl = { $null = $calls.Add('download') }.GetNewClosure()
        # Off: D shows the note (no Settings offered: none given). Any key, then B.
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings); D = $dl; K = (New-KeyReader 'd', 'x1', 'b') } {
            param($S, $D, $K) Invoke-AfOfficeSetupMenu -Settings $S -OutputRoot $TestDrive -Download $D -ReadKey $K 6>$null
        }
        $calls.Count | Should -Be 0
        InModuleScope AutoFixer -Parameters @{ S = (New-TestSettings 'Technician' $true $true); D = $dl; K = (New-KeyReader 'd', 'x1', 'b') } {
            param($S, $D, $K) Invoke-AfOfficeSetupMenu -Settings $S -OutputRoot $TestDrive -Download $D -ReadKey $K 6>$null
        }
        $calls | Should -Be @('download')
    }
}
