<#
.SYNOPSIS
    Scans this PC's logs for crashes and failures and writes a report.

.DESCRIPTION
    Opens a menu (Scan, Repair, Network and domain, View the last report, Settings, About,
    Quit). On first
    launch it asks for the mode: Standard (default) or Technician. The choice, the
    screen style and the on/off switches are saved in settings.json next to this
    script. -NoMenu runs one scan straight away
    using only the options given on the command line. -ShowLastReport prints the
    newest saved scan as plain text, for remote shells with no browser or menu keys.

    The scan only reads logs and never changes the machine. Run it as administrator
    to include crash dumps, CBS/DISM and device install logs.

    Sensitive data (user and PC names, serial numbers and service tags, profile paths,
    emails, IP and MAC addresses, SIDs, product keys) is redacted on screen and in saved reports by default.

.EXAMPLE
    .\Start-AutoFixer.ps1                              # menu
    .\Start-AutoFixer.ps1 -Plain                       # menu without the Branded art, this run only
    .\Start-AutoFixer.ps1 -NoMenu -Days 30 -Open
    .\Start-AutoFixer.ps1 -NoMenu -ShowSensitive       # real values on screen, files stay redacted
    .\Start-AutoFixer.ps1 -ShowLastReport              # newest saved scan as text, then exit
    .\Start-AutoFixer.ps1 -ShowLastReport -RunId 20261029-233547Z
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 90)] [int] $Days = 14,
    [string] $OutputRoot = (Join-Path $env:ProgramData 'AutoFixer\Runs'),
    # Shows real values on screen. No prompt: nothing is written to disk by this switch.
    [switch] $ShowSensitive,
    # Saves real values in the report files, after a one-key Y/N "are you sure?" warning.
    [switch] $SaveSensitive,
    # Opens the saved report in the browser when the scan finishes.
    [switch] $Open,
    # One scan, no menu and no settings.json. For scripts and CI.
    [switch] $NoMenu,
    # Default: settings.json next to this script.
    [string] $SettingsPath,
    # The Plain look for this run: the same screens without the Branded art. Not saved.
    [switch] $Plain,
    # Prints the newest saved scan (or -RunId) as plain text and exits. Reads the saved scan file only.
    [switch] $ShowLastReport,
    # With -ShowLastReport: the run folder name, such as 20261028-140300.
    [string] $RunId
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty in param defaults under -File, so set it here.
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot 'settings.json' }
Import-Module (Join-Path $PSScriptRoot 'AutoFixer\AutoFixer.psd1') -Force

function Invoke-Scan([bool] $ShowOnScreen, [bool] $SaveUnredacted, [int] $ScanDays, [string] $ReportRoot, [bool] $OpenReport) {
    # One redactor for screen and file, so placeholders such as <IP-1> match in both.
    $redactor = New-AfRedactor -Disabled:$ShowOnScreen

    Write-Host ''
    Write-Host '  Auto-Fixer - scan only, nothing will be changed' -ForegroundColor Cyan
    $screenState = 'redacted'
    if ($ShowOnScreen) { $screenState = 'SHOWN on screen' }
    $fileState = 'redacted'
    if ($SaveUnredacted) { $fileState = 'NOT redacted' }
    Write-Host ('  Sensitive data: {0}; saved reports: {1}' -f $screenState, $fileState) -ForegroundColor DarkGray
    Write-Host ''

    $result = Invoke-AutoFixerScan -Days $ScanDays -Redactor $redactor
    $fileRedactor = $redactor
    if (-not $redactor.Enabled) { $fileRedactor = $null }
    $saved = Export-AutoFixerReport -Result $result -OutputRoot $ReportRoot -Redactor $fileRedactor -IncludeSensitive:$SaveUnredacted

    Write-Host ''
    if ($result.Findings.Count -eq 0) {
        Write-Host 'No known problems found.' -ForegroundColor Green
    }
    foreach ($finding in $result.Findings) {
        Write-Host ('[{0}] {1}' -f $finding.Severity, $finding.Title) -ForegroundColor Yellow
        Write-Host ('    {0}' -f (Protect-AfText -Redactor $redactor -Text $finding.Explanation))
    }
    Write-Host ''
    Write-Host ('Report saved to {0}' -f (Protect-AfText -Redactor $redactor -Text $saved.Html))
    if ($OpenReport) { Invoke-Item -LiteralPath $saved.Html }
}

if ($ShowLastReport) {
    try { Show-AutoFixerReport -OutputRoot $OutputRoot -RunId $RunId }
    catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Yellow; exit 1 }
    exit 0
}

# A menu needs a keyboard; with redirected input (scheduled runs, CI) scan once instead.
$interactive = $true
try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $true }

if ($NoMenu -or -not $interactive) {
    $includeSensitive = $false
    if ($SaveSensitive) {
        $includeSensitive = Confirm-AfSaveSensitive
        if (-not $includeSensitive) { Write-Host '  Keeping redaction on for saved reports.' -ForegroundColor Yellow }
    }
    Invoke-Scan -ShowOnScreen $ShowSensitive.IsPresent -SaveUnredacted $includeSensitive -ScanDays $Days -ReportRoot $OutputRoot -OpenReport $Open.IsPresent
    return
}

if ($ShowSensitive -or $SaveSensitive) {
    Write-Host '  -ShowSensitive and -SaveSensitive only apply with -NoMenu. In the menu, use Settings.' -ForegroundColor Yellow
}
Invoke-AfMainMenu -SettingsPath $SettingsPath -OutputRoot $OutputRoot -Plain:$Plain -ScanAction {
    param([bool] $ShowOnScreen, [bool] $SaveUnredacted)
    Invoke-Scan -ShowOnScreen $ShowOnScreen -SaveUnredacted $SaveUnredacted -ScanDays $Days -ReportRoot $OutputRoot -OpenReport $Open.IsPresent
}
