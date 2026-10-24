@{
    RootModule           = 'AutoFixer.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6b0f6a3e-2f4b-4c8e-9a51-3d7c2e9b8f10'
    Author               = 'raven575'
    Description          = 'Reads Windows logs for crashes and failures, explains them, and (from M3) runs safe, reversible fixes.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Invoke-AutoFixerScan', 'Export-AutoFixerReport', 'Invoke-AfDiagnosis', 'Import-AfSignature', 'New-AfEvidence', 'New-AfRedactor', 'Protect-AfText', 'Confirm-AfSaveSensitive')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{ PSData = @{ Tags = @('Windows', 'Troubleshooting', 'EventLog') } }
}
