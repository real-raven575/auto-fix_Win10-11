<#
.SYNOPSIS
    Scans this PC's logs for crashes and failures and writes a report.

.DESCRIPTION
    M1 is scan-only: it reads logs and never changes the machine. Run it from an
    elevated PowerShell window to include crash dumps, CBS/DISM and device install logs.

.EXAMPLE
    .\Start-AutoFixer.ps1
    .\Start-AutoFixer.ps1 -Days 30 -Redact -Open
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 90)] [int] $Days = 14,
    [string] $OutputRoot = (Join-Path $env:ProgramData 'AutoFixer\Runs'),
    # Masks the user and machine names in the saved report.
    [switch] $Redact,
    # Opens report.html when the scan finishes.
    [switch] $Open
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AutoFixer\AutoFixer.psd1') -Force

Write-Host ''
Write-Host '  Auto-Fixer - scan only, nothing will be changed' -ForegroundColor Cyan
Write-Host ''

$result = Invoke-AutoFixerScan -Days $Days
$folder = Export-AutoFixerReport -Result $result -OutputRoot $OutputRoot -Redact:$Redact

Write-Host ''
if ($result.Findings.Count -eq 0) {
    Write-Host 'No known problems found.' -ForegroundColor Green
}
foreach ($finding in $result.Findings) {
    Write-Host ('[{0}] {1}' -f $finding.Severity, $finding.Title) -ForegroundColor Yellow
    Write-Host ('    {0}' -f $finding.Explanation)
}
Write-Host ''
Write-Host ('Report saved to {0}' -f $folder.FullName)
if ($Open) { Invoke-Item (Join-Path $folder.FullName 'report.html') }
