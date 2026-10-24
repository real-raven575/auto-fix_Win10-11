<#
.SYNOPSIS
    Scans this PC's logs for crashes and failures and writes a report.

.DESCRIPTION
    M1 is scan-only: it reads logs and never changes the machine. Run it from an
    elevated PowerShell window to include crash dumps, CBS/DISM and device install logs.

    Sensitive data (user and PC names, profile paths, emails, IP and MAC addresses,
    SIDs, product keys) is redacted on screen and in saved reports by default.

.EXAMPLE
    .\Start-AutoFixer.ps1
    .\Start-AutoFixer.ps1 -Days 30 -Open
    .\Start-AutoFixer.ps1 -ShowSensitive     # real values on screen, files stay redacted
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 90)] [int] $Days = 14,
    [string] $OutputRoot = (Join-Path $env:ProgramData 'AutoFixer\Runs'),
    # Shows real values on screen. No prompt: nothing is written to disk by this switch.
    [switch] $ShowSensitive,
    # Saves real values in the report files, after an "are you sure?" warning.
    [switch] $SaveSensitive,
    # Opens report.html when the scan finishes.
    [switch] $Open
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AutoFixer\AutoFixer.psd1') -Force

$includeSensitive = $false
if ($SaveSensitive) {
    $includeSensitive = Confirm-AfSaveSensitive
    if (-not $includeSensitive) { Write-Host '  Keeping redaction on for saved reports.' -ForegroundColor Yellow }
}

# One redactor for screen and file, so placeholders such as <IP-1> match in both.
$redactor = New-AfRedactor -Disabled:$ShowSensitive

Write-Host ''
Write-Host '  Auto-Fixer - scan only, nothing will be changed' -ForegroundColor Cyan
$screenState = 'redacted'
if ($ShowSensitive) { $screenState = 'SHOWN on screen' }
$fileState = 'redacted'
if ($includeSensitive) { $fileState = 'NOT redacted' }
Write-Host ('  Sensitive data: {0}; saved reports: {1}' -f $screenState, $fileState) -ForegroundColor DarkGray
Write-Host ''

$result = Invoke-AutoFixerScan -Days $Days -Redactor $redactor
$fileRedactor = $redactor
if (-not $redactor.Enabled) { $fileRedactor = $null }
$folder = Export-AutoFixerReport -Result $result -OutputRoot $OutputRoot -Redactor $fileRedactor -IncludeSensitive:$includeSensitive

Write-Host ''
if ($result.Findings.Count -eq 0) {
    Write-Host 'No known problems found.' -ForegroundColor Green
}
foreach ($finding in $result.Findings) {
    Write-Host ('[{0}] {1}' -f $finding.Severity, $finding.Title) -ForegroundColor Yellow
    Write-Host ('    {0}' -f (Protect-AfText -Redactor $redactor -Text $finding.Explanation))
}
Write-Host ''
Write-Host ('Report saved to {0}' -f (Protect-AfText -Redactor $redactor -Text $folder.FullName))
if ($Open) { Invoke-Item (Join-Path $folder.FullName 'report.html') }
