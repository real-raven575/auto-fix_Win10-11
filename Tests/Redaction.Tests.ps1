BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Protect-AfText' {
    BeforeEach { $script:R = New-AfRedactor -Names @('alice', 'ALICE-PC', 'CONTOSO') -Serials @() }

    It 'replaces each kind of sensitive value with a placeholder' {
        $text = 'alice on ALICE-PC (CONTOSO) from 192.168.1.20 mac 00-1A-2B-3C-4D-5E mail alice.smith@contoso.com sid S-1-5-21-1004336348-1177238915-682003330-1001 key ABCDE-12345-FGHIJ-67890-KLMNO'
        $out = Protect-AfText -Redactor $script:R -Text $text
        $out | Should -Not -Match 'alice|ALICE-PC|CONTOSO|192\.168|00-1A|contoso\.com|S-1-5-21|ABCDE'
        $out | Should -Match '<IP-1>'
        $out | Should -Match '<MAC-1>'
        $out | Should -Match '<EMAIL-1>'
        $out | Should -Match '<SID-1>'
        $out | Should -Match '<KEY-1>'
    }

    It 'gives the same value the same placeholder, and different values different ones' {
        $a = Protect-AfText -Redactor $script:R -Text 'from 10.0.0.5'
        $b = Protect-AfText -Redactor $script:R -Text 'again 10.0.0.5, then 10.0.0.6'
        $a | Should -Be 'from <IP-1>'
        $b | Should -Be 'again <IP-1>, then <IP-2>'
    }

    It 'hides the profile folder name in paths, even for other users' {
        Protect-AfText -Redactor $script:R -Text 'C:\Users\bob\AppData\Local\app.exe' | Should -Be 'C:\Users\<USER-1>\AppData\Local\app.exe'
        Protect-AfText -Redactor $script:R -Text 'C:\Users\Public\Desktop' | Should -Be 'C:\Users\Public\Desktop'
    }

    It 'does not treat a Windows build number as an IP address' {
        Protect-AfText -Redactor $script:R -Text 'Windows 10.0.19041.1 build' | Should -Be 'Windows 10.0.19041.1 build'
    }

    It 'does not treat an app version after the word Version as an IP address' {
        $text = "Version`t`t:`t3.10.20.24 and version: 1.2.3.4 but from 10.0.0.9"
        Protect-AfText -Redactor $script:R -Text $text | Should -Be "Version`t`t:`t3.10.20.24 and version: 1.2.3.4 but from <IP-1>"
    }

    It 'hides a Tailscale device and tailnet name but keeps .ts.net' {
        $a = Protect-AfText -Redactor $script:R -Text 'Name resolution for the name nextcloud.tailabc123.ts.net timed out'
        $b = Protect-AfText -Redactor $script:R -Text 'again nextcloud.tailabc123.ts.net and nas.tailabc123.ts.net'
        $a | Should -Be 'Name resolution for the name <HOST-1>.ts.net timed out'
        $b | Should -Be 'again <HOST-1>.ts.net and <HOST-2>.ts.net'
    }

    It 'redacts the full machine name before the user name inside it' {
        Protect-AfText -Redactor $script:R -Text 'ALICE-PC' | Should -Not -Match 'PC'
    }

    It 'passes text through when disabled' {
        $off = New-AfRedactor -Names @('alice') -Serials @() -Disabled
        Protect-AfText -Redactor $off -Text 'alice at 10.0.0.5' | Should -Be 'alice at 10.0.0.5'
    }

    It 'hides serial numbers and service tags as whole words only' {
        $r = New-AfRedactor -Names @() -Serials @('7XK2QM3', 'WD-WX12A3456789')
        Protect-AfText -Redactor $r -Text 'Service tag 7XK2QM3, disk WD-WX12A3456789' | Should -Be 'Service tag <SERIAL-2>, disk <SERIAL-1>'
        Protect-AfText -Redactor $r -Text 'build A7XK2QM3B' | Should -Be 'build A7XK2QM3B'
    }

    It 'ignores placeholder serials that makers ship' {
        $r = New-AfRedactor -Names @() -Serials @('To be filled by O.E.M.', 'Default string', '0000000', '123')
        @($r.Serials).Count | Should -Be 0
    }
}

Describe 'Built-in words and shared paths' {
    It 'never hides System or other built-in account words, even when Auto-Fixer runs as SYSTEM' {
        $r = New-AfRedactor -Names @('SYSTEM', 'ALICE-PC', 'WORKGROUP') -Serials @()
        $r.Names | Should -Be @('ALICE-PC')
        Protect-AfText -Redactor $r -Text 'Open System Restore from Settings > System > Recovery on ALICE-PC' |
            Should -Be 'Open System Restore from Settings > System > Recovery on <NAME-1>'
    }

    It 'skips built-in names found during a run, but keeps a real name next to them' {
        $r = New-AfRedactor -Names @('ALICE-PC') -Serials @()
        # Add-AfRedactionName is internal to the module.
        InModuleScope AutoFixer -Parameters @{ R = $r } { param($R) Add-AfRedactionName -Redactor $R -Names @('NT AUTHORITY\SYSTEM', 'Administrator', 'Guest', 'CONTOSO\jdoe') }
        $r.Names | Should -Not -Contain 'SYSTEM'
        $r.Names | Should -Not -Contain 'NT AUTHORITY\SYSTEM'
        $r.Names | Should -Not -Contain 'Administrator'
        $r.Names | Should -Contain 'jdoe'
        $r.Names | Should -Contain 'CONTOSO'
        Protect-AfText -Redactor $r -Text 'Administrator rights for jdoe' | Should -Match '^Administrator rights for <NAME-\d+>$'
    }

    It 'hides both parts of an unknown \\server\share' {
        $r = New-AfRedactor -Names @('ALICE-PC') -Serials @()
        Protect-AfText -Redactor $r -Text 'Add printer : \\fs01\Floor2-Color added' | Should -Be 'Add printer : \\<HOST-1>\<SHARE-1> added'
        Protect-AfText -Redactor $r -Text 'again \\fs01\Floor2-Color' | Should -Be 'again \\<HOST-1>\<SHARE-1>'
    }

    It 'hides the share when only the server was known' {
        $r = New-AfRedactor -Names @('printsrv') -Serials @()
        Protect-AfText -Redactor $r -Text '\\printsrv\Accounting' | Should -Be '\\<NAME-1>\<SHARE-1>'
        Protect-AfText -Redactor $r -Text '\\10.0.0.5\Accounting' | Should -Be '\\<IP-1>\<SHARE-1>'
    }

    It 'hides a known share name with spaces in full' {
        $r = New-AfRedactor -Names @('ALICE-PC') -Serials @()
        # Add-AfRedactionName is internal to the module.
        InModuleScope AutoFixer -Parameters @{ R = $r } { param($R) Add-AfRedactionName -Redactor $R -Names @('\\printsrv\Front Desk') }
        Protect-AfText -Redactor $r -Text 'Printer added: \\printsrv\Front Desk' | Should -Not -Match 'printsrv|Front|Desk'
    }

    It 'leaves Windows device paths alone' {
        $r = New-AfRedactor -Names @('ALICE-PC') -Serials @()
        Protect-AfText -Redactor $r -Text '\\?\Volume{1234}\ and \\.\PHYSICALDRIVE0' | Should -Be '\\?\Volume{1234}\ and \\.\PHYSICALDRIVE0'
    }
}

Describe 'Read-AfYesNo' {
    BeforeAll {
        function New-KeyReader([string[]] $Keys) {
            $queue = [System.Collections.Queue]::new()
            foreach ($k in $Keys) { $queue.Enqueue([char]$k) }
            return { $queue.Dequeue() }.GetNewClosure()
        }
    }

    It 'returns true for Y and false for N, in either case' {
        InModuleScope AutoFixer -Parameters @{ Y = (New-KeyReader 'y'); N = (New-KeyReader 'N') } {
            param($Y, $N)
            Read-AfYesNo -Prompt 'Sure?' -ReadKey $Y | Should -BeTrue
            Read-AfYesNo -Prompt 'Sure?' -ReadKey $N | Should -BeFalse
        }
    }

    It 'treats Esc as No, from a menu key reader or a raw key press' {
        InModuleScope AutoFixer -Parameters @{ Menu = { 'Escape' }; Raw = { [char]27 } } {
            param($Menu, $Raw)
            Read-AfYesNo -Prompt 'Sure?' -ReadKey $Menu | Should -BeFalse
            Read-AfYesNo -Prompt 'Sure?' -ReadKey $Raw | Should -BeFalse
        }
    }

    It 'asks again after one unknown key' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader 'x', 'Y') } {
            param($Keys)
            Read-AfYesNo -Prompt 'Sure?' -ReadKey $Keys | Should -BeTrue
        }
    }

    It 'gives up after a second unknown key and returns nothing' {
        InModuleScope AutoFixer -Parameters @{ Keys = (New-KeyReader 'x', 'q') } {
            param($Keys)
            Read-AfYesNo -Prompt 'Sure?' -ReadKey $Keys | Should -BeNullOrEmpty
        }
    }
}

Describe 'Confirm-AfSaveSensitive' {
    BeforeAll {
        function New-KeyReader([string[]] $Keys) {
            $queue = [System.Collections.Queue]::new()
            foreach ($k in $Keys) { $queue.Enqueue([char]$k) }
            return { $queue.Dequeue() }.GetNewClosure()
        }
    }

    It 'saves unredacted only after Y' {
        Confirm-AfSaveSensitive -ReadKey (New-KeyReader 'Y') | Should -BeTrue
        Confirm-AfSaveSensitive -ReadKey (New-KeyReader 'N') | Should -BeFalse
        Confirm-AfSaveSensitive -ReadKey (New-KeyReader 'a', 'b') | Should -BeFalse
    }
}
