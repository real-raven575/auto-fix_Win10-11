# The reference copy of the SFC + DISM Repair Tool v1.1 must stay byte-for-byte
# as delivered. auto-fix_Win's own fixes change; these files never do.

Describe 'SFC + DISM Repair Tool v1.1 reference copy' {
    It '<Name> is unchanged' -ForEach @(
        @{ Name = 'SfcDismTool.ps1'; Sha256 = 'EF51FBA8FBE5D1AF8E20F4B9933B4781B6BD60ED6316F5B70B5A51F1A7F541A2' }
        @{ Name = 'Run-SfcDismTool.bat'; Sha256 = '7CA53BDCFEAC1A8723FECBEFC467E34CE0B6E0DC1AEBEF1CE87E2EF69CE6B57E' }
    ) {
        $path = Join-Path $PSScriptRoot "..\reference\sfc-dism-v1.1\$Name"
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash | Should -Be $Sha256
    }
}
