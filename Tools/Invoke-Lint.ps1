<#
.SYNOPSIS
    Lints every PowerShell file in the repo with PSScriptAnalyzer: the same check
    CI runs, so a clean run here means a clean Lint step there.
.DESCRIPTION
    Read-only: it reports problems and changes no file.
      AutoFixer, Start-AutoFixer.ps1, Tools, Templates   the repo settings file.
      Tests                                              the same settings, plus
                                                         PSReviewUnusedParameter off
                                                         (test stubs copy the real
                                                         parameter lists on purpose).
    Exit code 0 = no issues, 1 = issues found, 2 = PSScriptAnalyzer is missing.
.EXAMPLE
    .\Tools\Invoke-Lint.ps1
#>
[CmdletBinding()]
param(
    # Error, Warning by default. Add Information to see the advisory rules too.
    [ValidateSet('Error', 'Warning', 'Information')]
    [string[]] $Severity = @('Error', 'Warning')
)

$root = Split-Path -Parent $PSScriptRoot
if (-not (Get-Module PSScriptAnalyzer -ListAvailable)) {
    Write-Host ' NO TOOL ' -ForegroundColor Black -BackgroundColor Yellow -NoNewline
    Write-Host ' PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 2
}
Import-Module PSScriptAnalyzer

# The settings file is passed by path (a hashtable read from it is not applied the same way).
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$testSettings = @{ ExcludeRules = [string[]](@((Import-PowerShellDataFile $settings).ExcludeRules) + 'PSReviewUnusedParameter') }

$targets = @(
    @{ Path = 'AutoFixer'; Settings = $settings; Recurse = $true }
    @{ Path = 'Start-AutoFixer.ps1'; Settings = $settings; Recurse = $false }
    @{ Path = 'Tools'; Settings = $settings; Recurse = $true }
    @{ Path = 'Templates'; Settings = $settings; Recurse = $true }
    @{ Path = 'Tests'; Settings = $testSettings; Recurse = $true }
)

$issues = New-Object System.Collections.Generic.List[object]
foreach ($t in $targets) {
    $path = Join-Path $root $t.Path
    if (-not (Test-Path $path)) { continue }
    $found = @(Invoke-ScriptAnalyzer -Path $path -Recurse:$t.Recurse -Settings $t.Settings -Severity $Severity)
    $color = 'Green'
    if ($found.Count -gt 0) { $color = 'Yellow' }
    Write-Host ('  {0,-22} {1} issue(s)' -f $t.Path, $found.Count) -ForegroundColor $color
    foreach ($f in $found) { $issues.Add($f) }
}

if ($issues.Count -gt 0) {
    $issues | Sort-Object ScriptName, Line |
        Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message |
        Out-String -Width 220 | Write-Host
    Write-Host (' {0} LINT ISSUE(S) ' -f $issues.Count) -ForegroundColor White -BackgroundColor DarkRed
    exit 1
}
Write-Host ' LINT CLEAN ' -ForegroundColor Black -BackgroundColor Green
exit 0
