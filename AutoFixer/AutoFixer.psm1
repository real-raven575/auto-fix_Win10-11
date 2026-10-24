# Loads every part of Auto-Fixer. Order matters: Core types first, then the
# collectors, report and fixes that use them.

$script:AfModuleRoot = $PSScriptRoot
$script:AfVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'AutoFixer.psd1')).ModuleVersion

foreach ($folder in 'Core', 'Collectors', 'Report', 'Fixes') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'Invoke-AutoFixerScan'
    'Export-AutoFixerReport'
    'Invoke-AfDiagnosis'
    'Import-AfSignature'
    'New-AfEvidence'
    'New-AfRedactor'
    'Protect-AfText'
    'Confirm-AfSaveSensitive'
    'Read-AfSettings'
    'Save-AfSettings'
    'Invoke-AfMainMenu'
)
