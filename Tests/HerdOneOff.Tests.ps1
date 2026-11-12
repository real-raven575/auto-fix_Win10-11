# The HERD themed one-off template (raven575, 2026-11-09: every one-off script
# gets our theming, progress bar and highlighted warnings) and the shared lint
# script. The template is dot-sourced, which loads its functions and runs nothing.
BeforeAll {
    $script:Template = Join-Path $PSScriptRoot '..\Templates\HerdOneOff.ps1'
    $script:Lint = Join-Path $PSScriptRoot '..\Tools\Invoke-Lint.ps1'
    . $script:Template -Plain
}

Describe 'HERD one-off template: files' {
    It 'keeps the template and the lint script pure ASCII, so Windows PowerShell 5.1 reads them' {
        foreach ($path in @($script:Template, $script:Lint)) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because $path
        }
    }

    It 'loads its functions without running any step when dot-sourced' {
        Get-Command Invoke-HerdSteps -CommandType Function | Should -Not -BeNullOrEmpty
        Get-Variable -Name Steps -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'HERD one-off template: look' {
    It 'uses the Auto-Fixer colours: Standard cyan, Technician orange' {
        (Get-HerdTheme).Frame | Should -Be 'DarkCyan'
        (Get-HerdTheme -Technician).Frame | Should -Be 'DarkYellow'
    }

    It 'fills the bar like Auto-Fixer: rounds down and stays inside' {
        Get-HerdBarFill -Percent 0 -Width 50 | Should -Be 0
        Get-HerdBarFill -Percent 50 -Width 50 | Should -Be 25
        Get-HerdBarFill -Percent 99.9 -Width 50 | Should -Be 49
        Get-HerdBarFill -Percent 100 -Width 50 | Should -Be 50
        Get-HerdBarFill -Percent 140 -Width 50 | Should -Be 50
        Get-HerdBarFill -Percent -5 -Width 50 | Should -Be 0
        Get-HerdBarFill -Percent 50 -Width 0 | Should -Be 0
    }

    It 'writes result lines in the same shape as a scan' {
        Get-HerdStatusLine -Status 'Done' -Step 'Read Windows version' -Summary 'build 26100' -Seconds 0.42 |
            Should -Be '[done   ] Read Windows version - build 26100 (0.4 s)'
        Get-HerdStatusLine -Status 'Failed' -Step 'X' -Summary 'exit 5 (access denied)' -Seconds 2 |
            Should -Be '[failed ] X - exit 5 (access denied) (2 s)'
    }

    It 'puts warnings and failures in the log as well as on screen' {
        $script:HerdLog.Clear()
        Write-HerdWarning 'Only 3 GB free on C:'
        Write-HerdFailure 'DISM exit 87: a parameter is wrong'
        $script:HerdLog[0] | Should -Match 'WARNING: Only 3 GB free on C:$'
        $script:HerdLog[1] | Should -Match 'FAILED: DISM exit 87: a parameter is wrong$'
    }
}

Describe 'HERD one-off template: safe by default' {
    # CI has no keyboard, which turns Background Mode on; these tests are the interactive path.
    BeforeEach { $script:HerdLog.Clear(); $script:HerdBackground = $false; $script:HerdGo = '' }

    It 'runs read-only steps before steps that change the PC' {
        Mock Confirm-HerdChange { $true }
        $steps = @(
            @{ Name = 'Change'; Changes = 'Deletes temp files'; Run = { 'changed' } }
            @{ Name = 'Look'; Changes = $null; Run = { 'looked' } }
        )
        $r = Invoke-HerdSteps -Steps $steps
        $r[0].Name | Should -Be 'Look'
        $r[1].Name | Should -Be 'Change'
        $r[1].Status | Should -Be 'Done'
    }

    It 'skips a change when the user says no, and never runs it' {
        Mock Confirm-HerdChange { $false }
        $script:ran = $false
        $steps = @(@{ Name = 'Change'; Changes = 'Deletes temp files'; Run = { $script:ran = $true; 'changed' } })
        $r = Invoke-HerdSteps -Steps $steps
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Summary | Should -Be 'you said no'
        $script:ran | Should -BeFalse
    }

    It 'asks nothing and changes nothing under -WhatIf, but still runs read-only steps' {
        Mock Confirm-HerdChange { $true }
        $steps = @(
            @{ Name = 'Change'; Changes = 'Deletes temp files'; Run = { 'changed' } }
            @{ Name = 'Look'; Changes = $null; Run = { 'looked' } }
        )
        $r = Invoke-HerdSteps -Steps $steps -WhatIf
        ($r | Where-Object Name -eq 'Look').Status | Should -Be 'Done'
        ($r | Where-Object Name -eq 'Change').Status | Should -Be 'Skipped'
        Should -Invoke Confirm-HerdChange -Times 0 -Exactly
    }

    It 'reports a failing step honestly, on one line, and carries on' {
        $steps = @(
            @{ Name = 'Breaks'; Changes = $null; Run = { throw "exit 5 (access denied)`nsecond line" } }
            @{ Name = 'Works'; Changes = $null; Run = { 'ok' } }
        )
        $r = Invoke-HerdSteps -Steps $steps
        $r[0].Status | Should -Be 'Failed'
        $r[0].Summary | Should -Be 'exit 5 (access denied)'
        $r[1].Status | Should -Be 'Done'
        @($script:HerdLog -match '\[failed \] 1 of 2: Breaks - exit 5').Count | Should -Be 1
    }
}

Describe 'HERD one-off template: Background Mode (from TEAM 9to5, FIXW-0023)' {
    BeforeEach { $script:HerdLog.Clear(); $script:HerdBackground = $true; $script:HerdGo = '' }

    It 'never asks, and skips a change without -Go YES' {
        Mock Confirm-HerdChange { $true }
        $steps = @(@{ Name = 'Change'; Changes = 'Deletes temp files'; Run = { 'changed' } })
        $r = Invoke-HerdSteps -Steps $steps
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Summary | Should -Be 'Background Mode: needs -Go YES'
        Should -Invoke Confirm-HerdChange -Times 0 -Exactly
    }

    It 'runs a change with -Go YES (exact, upper case) and logs that it did' {
        Mock Confirm-HerdChange { $false }
        $script:HerdGo = 'YES'
        $steps = @(@{ Name = 'Change'; Changes = 'Deletes temp files'; Run = { 'changed' } })
        (Invoke-HerdSteps -Steps $steps)[0].Status | Should -Be 'Done'
        @($script:HerdLog -match 'Background Mode, -Go YES: Deletes temp files').Count | Should -Be 1
        $script:HerdGo = 'yes'
        (Invoke-HerdSteps -Steps $steps)[0].Status | Should -Be 'Skipped'
        Should -Invoke Confirm-HerdChange -Times 0 -Exactly
    }
}

Describe 'HERD one-off template: RESULT block and masking' {
    It 'masks this PC''s computer and user names' {
        $old = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = 'TESTPC-42'
            Protect-HerdText 'saved on testpc-42 at noon' | Should -Be 'saved on <PC> at noon'
            Protect-HerdText 'nothing to hide' | Should -Be 'nothing to hide'
        }
        finally { $env:COMPUTERNAME = $old }
    }

    It 'counts the steps and lists each one that did not finish' {
        $results = @(
            [pscustomobject]@{ Name = 'A'; Status = 'Done'; Summary = 'ok' }
            [pscustomobject]@{ Name = 'B'; Status = 'Skipped'; Summary = 'you said no' }
            [pscustomobject]@{ Name = 'C'; Status = 'Failed'; Summary = 'exit 5 (access denied)' }
        )
        $lines = Get-HerdResultLines -Results $results -LogPath 'C:\ProgramData\AutoFixer\OneOff\x.log'
        $lines[0] | Should -Be 'Done 1   Skipped 1   Failed 1   (of 3 steps)'
        $lines[1] | Should -Be 'SKIPPED: B - you said no'
        $lines[2] | Should -Be 'FAILED: C - exit 5 (access denied)'
        $lines[3] | Should -Be 'Log: C:\ProgramData\AutoFixer\OneOff\x.log'
    }
}

Describe 'Shared lint script' {
    It 'is what CI runs, so local and CI lint can never drift apart' {
        $ci = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\.github\workflows\ci.yml')
        $ci | Should -Match 'Tools/Invoke-Lint\.ps1'
    }

    It 'checks every PowerShell file is pure ASCII with no BOM' {
        Get-Content -Raw -LiteralPath $script:Lint | Should -Match 'HerdPureAscii'
    }

    It 'lints the Tests, Tools and Templates folders too' {
        $text = Get-Content -Raw -LiteralPath $script:Lint
        foreach ($folder in 'AutoFixer', 'Start-AutoFixer.ps1', 'Tools', 'Templates', 'Tests') {
            $text | Should -Match ("Path = '{0}'" -f [regex]::Escape($folder))
        }
    }
}
