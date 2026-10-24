BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force
}

Describe 'Protect-AfText' {
    BeforeEach { $script:R = New-AfRedactor -Names @('alice', 'ALICE-PC', 'CONTOSO') }

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

    It 'redacts the full machine name before the user name inside it' {
        Protect-AfText -Redactor $script:R -Text 'ALICE-PC' | Should -Not -Match 'PC'
    }

    It 'passes text through when disabled' {
        $off = New-AfRedactor -Names @('alice') -Disabled
        Protect-AfText -Redactor $off -Text 'alice at 10.0.0.5' | Should -Be 'alice at 10.0.0.5'
    }
}

Describe 'Confirm-AfSaveSensitive' {
    It 'only accepts an exact YES' {
        Confirm-AfSaveSensitive -Answer 'YES' | Should -BeTrue
        Confirm-AfSaveSensitive -Answer 'yes' | Should -BeFalse
        Confirm-AfSaveSensitive -Answer '' | Should -BeFalse
    }
}
