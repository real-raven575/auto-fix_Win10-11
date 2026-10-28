# The About screen: who wrote Auto-Fixer, its license, and every part of Windows
# it uses with the maker's copyright. docs/CREDITS.md holds the same list for
# GitHub readers; Tests/About.Tests.ps1 keeps the two in step with the code.

# Written exactly as raven575 set it (2026-10-26). Change it here only.
$script:AfCreditsLine = 'raven575, Wrench of TEAM Auto-Fixer & Inkwell of TEAM Creative "Herd of Helpers"'
$script:AfAiNote = 'Wrench and Inkwell are Claude, an AI model by Anthropic, which helped write the code.'
$script:AfProjectUrl = 'github.com/real-raven575/auto-fix_Win10-11'

# Program is the .exe the code runs, so the test can find a missing credit.
$script:AfCredits = @(
    @{ Group = 'Windows'; Name = 'Windows PowerShell 5.1'; Program = 'powershell.exe'; Owner = 'Microsoft Corporation'; Use = 'Runs the whole tool. It is on every Windows 10 and 11 PC, so there is nothing to install.' }
    @{ Group = 'Windows'; Name = 'Command Prompt'; Program = 'cmd.exe'; Owner = 'Microsoft Corporation'; Use = 'Runs AutoFix.bat, the launcher that opens with a double-click and asks for administrator rights once.' }
    @{ Group = 'Windows'; Name = 'Filter Manager control'; Program = 'fltmc.exe'; Owner = 'Microsoft Corporation'; Use = 'The launcher runs it only to test for administrator rights. It changes nothing.' }
    @{ Group = 'Windows'; Name = 'Windows Event Log'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Read-only: the System, Application, Setup, Windows Update and four app logs.' }
    @{ Group = 'Windows'; Name = 'Reliability Monitor'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Read-only: the stability score and the crash and install records.' }
    @{ Group = 'Windows'; Name = 'Device Manager data'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Read-only: finds devices with a problem code.' }
    @{ Group = 'Windows'; Name = 'Windows system information'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'The Windows version for the report. Serial numbers are read only so they can be hidden.' }
    @{ Group = 'Windows'; Name = 'Windows crash and repair logs'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Read-only, never moved or deleted: error reports, crash dumps, CBS, DISM and device install logs.' }
    @{ Group = 'Windows'; Name = 'System Restore and Volume Shadow Copy'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Offers a restore point before a repair and checks that it was made.' }
    @{ Group = 'Windows'; Name = 'System File Checker'; Program = 'sfc.exe'; Owner = 'Microsoft Corporation'; Use = 'Checks protected Windows files and replaces damaged ones. Microsoft''s own tool for this.' }
    @{ Group = 'Windows'; Name = 'DISM'; Program = 'dism.exe'; Owner = 'Microsoft Corporation'; Use = 'Checks and repairs the component store that SFC copies its clean files from.' }
    @{ Group = 'Windows'; Name = 'Windows Update'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Only for DISM RestoreHealth, only with the Online switch on, and always announced first.' }
    @{ Group = 'Windows'; Name = 'Shutdown'; Program = 'shutdown.exe'; Owner = 'Microsoft Corporation'; Use = 'The optional restart after repairs, with a countdown you can cancel.' }
    @{ Group = 'Windows'; Name = 'Task Kill'; Program = 'taskkill.exe'; Owner = 'Microsoft Corporation'; Use = 'Stops a stalled SFC or DISM step, and only after you say yes.' }
    @{ Group = 'Windows'; Name = 'Credential Manager'; Program = 'cmdkey.exe'; Owner = 'Microsoft Corporation'; Use = 'Lists saved network-drive passwords by server name and removes the ones you pick. Never shows a password.' }
    @{ Group = 'Windows'; Name = 'Net'; Program = 'net.exe'; Owner = 'Microsoft Corporation'; Use = 'Drops a share connection with no drive letter and no open files after its saved password is removed.' }
    @{ Group = 'Windows'; Name = 'SMB client'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Read-only: lists mapped drives and open share connections (Get-SmbMapping, Get-SmbConnection).' }
    @{ Group = 'Windows'; Name = 'Kerberos list'; Program = 'klist.exe'; Owner = 'Microsoft Corporation'; Use = 'On a domain PC, clears your sign-in tickets after a password is removed, only if you say yes.' }
    @{ Group = 'Windows'; Name = 'Domain controller locator'; Program = 'nltest.exe'; Owner = 'Microsoft Corporation'; Use = 'Read-only: checks that Windows can find a domain controller.' }
    @{ Group = 'Windows'; Name = 'Windows Time'; Program = 'w32tm.exe'; Owner = 'Microsoft Corporation'; Use = 'Read-only: compares the clock with the domain controller, because sign-in fails past 5 minutes.' }
    @{ Group = 'Windows'; Name = 'DNS client'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Read-only: finds the domain controllers of a domain (Resolve-DnsName).' }
    @{ Group = 'Windows'; Name = 'Domain join cmdlets'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Add-Computer, Remove-Computer and Test-ComputerSecureChannel join, leave and repair the trust, each only after you say yes.' }
    @{ Group = 'Windows'; Name = 'Windows power management'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Keeps the PC awake while a long repair runs. No power setting is changed.' }
    @{ Group = 'Windows'; Name = '.NET Framework'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Built-in code library: starting programs, the HTML report and text matching.' }
    @{ Group = 'Windows'; Name = 'Your web browser'; Program = ''; Owner = 'its maker'; Use = 'Opens the HTML report when you ask. The tool does not choose or ship a browser.' }
    @{ Group = 'Optional'; Name = 'PowerShell 7'; Program = ''; Owner = 'Microsoft Corporation, MIT License'; Use = 'The tool also runs on it, but never needs it.' }
    @{ Group = 'Build'; Name = 'Pester'; Program = ''; Owner = 'Pester team, Apache License 2.0'; Use = 'Runs the automated tests.' }
    @{ Group = 'Build'; Name = 'PSScriptAnalyzer'; Program = ''; Owner = 'Microsoft Corporation, MIT License'; Use = 'Checks the code for common mistakes.' }
    @{ Group = 'Build'; Name = 'PowerShell Gallery'; Program = ''; Owner = 'Microsoft Corporation'; Use = 'Where the tests download Pester and PSScriptAnalyzer.' }
    @{ Group = 'Build'; Name = 'GitHub Actions'; Program = ''; Owner = 'GitHub, Inc.'; Use = 'Runs every test on a clean Windows machine, under PowerShell 5.1 and 7.' }
    @{ Group = 'Build'; Name = 'actions/checkout and actions/upload-artifact'; Program = ''; Owner = 'GitHub, Inc. and contributors, MIT License'; Use = 'Copy the code in and save the test results.' }
)

$script:AfTrademarks = 'Microsoft, Windows, PowerShell and Windows Update are trademarks of the Microsoft group of companies. GitHub is a trademark of GitHub, Inc. Claude is a trademark of Anthropic. Auto-Fixer is not made, endorsed or supported by Microsoft, GitHub or Anthropic.'

function Get-AfCredits {
    # One record per credited part, in screen order.
    [CmdletBinding()]
    param()

    foreach ($credit in $script:AfCredits) { [pscustomobject]$credit }
}

function Split-AfText {
    # Breaks text into lines no wider than -Width, at spaces. Words are never changed.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [int] $Width = 76
    )

    $line = ''
    foreach ($word in ($Text -split ' ')) {
        if ($line -and ($line.Length + 1 + $word.Length) -gt $Width) {
            $line
            $line = $word
        }
        elseif ($line) { $line += ' ' + $word }
        else { $line = $word }
    }
    if ($line) { $line }
}

function Format-AfAboutField {
    # '    Name        value', with long values wrapped under the value column.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )

    $indent = '    {0,-11} ' -f $Name
    foreach ($part in (Split-AfText -Text $Value -Width 62)) {
        $indent + $part
        $indent = ' ' * $indent.Length
    }
}

function Get-AfAboutLines {
    # The top of the About screen, as plain lines that fit 80 columns.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    ''
    '  About Auto-Fixer'
    '    Operation: Back on Its Feet'
    Format-AfAboutField -Name 'Version' -Value $script:AfVersion
    Format-AfAboutField -Name 'Publisher' -Value 'raven575'
    Format-AfAboutField -Name 'Written by' -Value $script:AfCreditsLine
    Format-AfAboutField -Name '' -Value ('({0})' -f $script:AfAiNote)
    Format-AfAboutField -Name 'License' -Value 'MIT License, Copyright (c) 2026 raven575'
    Format-AfAboutField -Name 'Project' -Value $script:AfProjectUrl
    ''
    foreach ($part in (Split-AfText -Text 'This tool is provided "as is", without warranty of any kind. It uses only programs that come with Windows. It installs nothing and sends nothing anywhere unless you turn on the Online switch.' -Width 72)) { '    ' + $part }
}

function Get-AfAboutPanelLines {
    # The About box in the Branded and Plain look: the same facts, narrow enough to
    # leave room for Wrench on the right.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    'Auto-Fixer {0} - Operation: Back on Its Feet' -f $script:AfVersion
    $label = 'Credits  '
    foreach ($part in (Split-AfText -Text $script:AfCreditsLine -Width 42)) {
        $label + $part
        $label = ' ' * 9
    }
    Split-AfText -Text ('({0})' -f $script:AfAiNote) -Width 51
    'License  MIT License, Copyright (c) 2026 raven575'
    'Project  ' + $script:AfProjectUrl
}

function Get-AfCreditLines {
    # The tools list: name, maker and one line on how the tool uses it.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $titles = [ordered]@{
        Windows  = 'Parts of Windows this tool uses (called, never copied or shipped)'
        Optional = 'Optional'
        Build    = 'Used only to build and test it (not part of the download)'
    }
    foreach ($group in $titles.Keys) {
        ''
        '  ' + $titles[$group]
        foreach ($credit in @(Get-AfCredits | Where-Object Group -eq $group)) {
            $name = $credit.Name
            if ($credit.Program) { $name = '{0} ({1})' -f $credit.Name, $credit.Program }
            foreach ($part in (Split-AfText -Text ('{0}. Copyright {1}.' -f $name, $credit.Owner) -Width 74)) { '    ' + $part }
            foreach ($part in (Split-AfText -Text $credit.Use -Width 72)) { '      ' + $part }
        }
    }
    ''
    '  Earlier work it builds on'
    '    SFC + DISM Repair Tool v1.1 by raven575 (kept unchanged in reference\).'
    ''
    foreach ($part in (Split-AfText -Text $script:AfTrademarks -Width 76)) { '  ' + $part }
}

function Get-AfLicenseLines {
    # The LICENSE file exactly as it is, so the screen can never drift from it.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path = (Join-Path (Split-Path $script:AfModuleRoot -Parent) 'LICENSE'))

    if (Test-Path -LiteralPath $Path) { return @(Get-Content -LiteralPath $Path) }
    return @('The LICENSE file is missing from this copy.', ('Auto-Fixer uses the MIT License. The full text is at {0}.' -f $script:AfProjectUrl))
}

function Show-AfPagedLines {
    # One console page at a time. Any key shows more; Esc stops early.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Lines,
        [int] $PageSize = 18,
        [scriptblock] $Header = {},
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    # Under the Branded or Plain banner the page starts on row 6, so it is shorter.
    if ((Get-AfDisplay).Style -ne 'Ascii') { $PageSize = [math]::Min($PageSize, 16) }
    $at = 0
    while ($at -lt $Lines.Count) {
        Clear-AfScreen
        & $Header
        $Lines[$at..([math]::Min($at + $PageSize, $Lines.Count) - 1)] | ForEach-Object { Write-Host $_ }
        $at += $PageSize
        Write-Host ''
        if ($at -lt $Lines.Count) {
            Write-Host '  Press any key for more, or Esc to go back.' -ForegroundColor DarkGray
            if ((& $ReadKey) -eq 'Escape') { return }
        }
        else {
            Write-Host '  Press any key to go back.' -ForegroundColor DarkGray
            $null = & $ReadKey
        }
    }
}

function Invoke-AfAboutMenu {
    # Main menu item 6. Sets $script:AfQuitRequested when the user quits from here.
    [CmdletBinding()]
    param(
        [string] $Mode = 'Standard',
        [scriptblock] $ReadKey = { Read-AfMenuKey }
    )

    # Script scope, so the screen script blocks below can read it when they run.
    $script:AfAboutMode = $Mode
    $banner = { Show-AfBanner -Mode $script:AfAboutMode }
    $header = {
        & $banner
        Get-AfAboutLines | ForEach-Object { Write-Host $_ }
    }
    $items = @(
        @{ Key = 'W'; Label = '&Windows tools this program uses' }
        @{ Key = 'L'; Label = '&License, full text' }
        @{ Key = 'B'; Label = '&Back' }
        @{ Key = 'Q'; Label = '&Quit' }
    )
    while ($true) {
        $choice = Select-AfMenuItem -Title 'About' -Items $items -Header $header -Info @(Get-AfAboutPanelLines) -Kind 'About' -Mode $Mode `
            -BoxRight 57 -EscapeKey 'B' -ReadKey $ReadKey
        switch ($choice) {
            'W' { Show-AfPagedLines -Lines @(Get-AfCreditLines) -Header $banner -ReadKey $ReadKey }
            'L' { Show-AfPagedLines -Lines @(Get-AfLicenseLines) -Header $banner -ReadKey $ReadKey }
            'B' { return }
            'Q' { if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return } }
        }
    }
}
