# Evidence is the one record type every collector emits. The diagnose step only
# ever looks at these fields, so a new collector needs nothing else to plug in.

function New-AfEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [datetime] $TimeCreated = (Get-Date),
        [string] $Provider = '',
        [int] $EventId = 0,
        # 1 Critical, 2 Error, 3 Warning, 4 Information (same scale as the event log)
        [int] $Level = 0,
        [string] $Message = '',
        [string] $Path = '',
        [hashtable] $Fields = @{}
    )

    # Windows puts invisible direction marks (U+200E, U+200F, U+202A-U+202E) around dates in
    # some event text, e.g. "Incident Time". They break searching and copy-paste, so drop them.
    $Message = $Message -replace '[\u200E\u200F\u202A-\u202E]', ''

    [pscustomobject]@{
        PSTypeName  = 'AutoFixer.Evidence'
        Source      = $Source
        TimeCreated = $TimeCreated
        Provider    = $Provider
        EventId     = $EventId
        Level       = $Level
        Message     = $Message
        Path        = $Path
        Fields      = $Fields
    }
}

function Test-AfIsAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
