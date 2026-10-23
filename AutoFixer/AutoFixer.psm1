# Loads every part of Auto-Fixer. Order matters: Core types first, then the
# collectors and report that use them.

$script:AfModuleRoot = $PSScriptRoot

foreach ($folder in 'Core', 'Collectors', 'Report') {
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
)
