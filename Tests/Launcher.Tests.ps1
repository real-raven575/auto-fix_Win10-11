# AutoFix.bat is the launcher people double-click. cmd.exe misreads batch files
# with Unix line endings, and a bare "powershell.exe" could be any program on PATH.

Describe 'AutoFix.bat launcher' {
    BeforeAll { $script:Path = Join-Path $PSScriptRoot '..\AutoFix.bat' }

    It 'uses Windows line endings only' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        ([regex]::Matches($text, '(?<!\r)\n')).Count | Should -Be 0
        ([regex]::Matches($text, '\r\n')).Count | Should -BeGreaterThan 10
    }

    It 'starts the built-in Windows PowerShell by full path' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        $text | Should -Match ([regex]::Escape('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'))
        $text | Should -Match ([regex]::Escape('-ExecutionPolicy Bypass -File "%~dp0Start-AutoFixer.ps1"'))
    }

    It 'asks for administrator rights only once' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        ([regex]::Matches($text, '-Verb RunAs')).Count | Should -Be 1
        $text | Should -Match '--elevated'
    }

    It 'opens the menu for people and skips it in CI' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        $text | Should -Match 'set "ARGS=-Open"'
        $text | Should -Match 'if defined AUTOFIX_CI set "ARGS=-NoMenu"'
    }

    It 'waits for a key before the admin prompt, except in CI' {
        $text = Get-Content -Raw -LiteralPath $script:Path
        $pause = $text.IndexOf('Press any key to continue. Windows will then ask for administrator rights.')
        $pause | Should -BeGreaterThan 0
        $pause | Should -BeLessThan $text.IndexOf('-Verb RunAs')
        ([regex]::Matches($text, 'if not defined AUTOFIX_CI \(\r\n[^)]*pause >nul')).Count | Should -Be 2
    }
}
