# Loads every part of Auto-Fixer. Order matters: Core types first, then the
# collectors, report and fixes that use them.

$script:AfModuleRoot = $PSScriptRoot
# Read from the manifest so the screen and logs always match it. Import-PowerShellDataFile
# is missing when Windows PowerShell 5.1 starts from PowerShell 7, so this reads the line.
$script:AfVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AutoFixer.psd1') -Raw), "ModuleVersion\s*=\s*'([^']+)'").Groups[1].Value

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
