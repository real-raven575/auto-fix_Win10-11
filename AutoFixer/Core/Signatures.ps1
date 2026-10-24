# Issue signatures are JSON data files (see Signatures/). This file loads them
# and turns a pile of Evidence into ranked Findings.
#
# A condition can test: source, provider, eventId, level (string or list),
# messageRegex, messageNotRegex, and field = @{ name; regex } for parsed files.

$script:AfSeverityRank = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Info = 4 }

function Import-AfSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $files = Get-ChildItem -Path $Path -Filter '*.json' -File | Sort-Object Name
    foreach ($file in $files) {
        $sig = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        foreach ($required in 'id', 'title', 'severity', 'match', 'explain') {
            if (-not $sig.PSObject.Properties[$required]) {
                throw "Signature '$($file.Name)' is missing '$required'."
            }
        }
        if (-not $script:AfSeverityRank.ContainsKey([string]$sig.severity)) {
            throw "Signature '$($sig.id)' has unknown severity '$($sig.severity)'."
        }
        $sig
    }
}

function Test-AfValueIn {
    # True when the condition value (one value or a list) contains $Actual, ignoring case.
    param($Expected, $Actual)
    foreach ($value in @($Expected)) {
        if ([string]$value -eq [string]$Actual) { return $true }
    }
    return $false
}

function Test-AfCondition {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Condition,
        [Parameter(Mandatory)] $Evidence
    )

    $c = $Condition
    if ($c.PSObject.Properties['source'] -and -not (Test-AfValueIn $c.source $Evidence.Source)) { return $false }
    if ($c.PSObject.Properties['provider'] -and -not (Test-AfValueIn $c.provider $Evidence.Provider)) { return $false }
    if ($c.PSObject.Properties['eventId'] -and -not (Test-AfValueIn $c.eventId $Evidence.EventId)) { return $false }
    if ($c.PSObject.Properties['level'] -and -not (Test-AfValueIn $c.level $Evidence.Level)) { return $false }
    if ($c.PSObject.Properties['messageRegex'] -and $Evidence.Message -notmatch $c.messageRegex) { return $false }
    if ($c.PSObject.Properties['messageNotRegex'] -and $Evidence.Message -match $c.messageNotRegex) { return $false }
    if ($c.PSObject.Properties['field']) {
        $value = $null
        if ($Evidence.Fields -and $Evidence.Fields.ContainsKey($c.field.name)) { $value = $Evidence.Fields[$c.field.name] }
        if ($null -eq $value -or [string]$value -notmatch $c.field.regex) { return $false }
    }
    return $true
}

function Format-AfExplain {
    param([string] $Template, [object[]] $Matched)

    $sorted = @($Matched | Sort-Object TimeCreated)
    $values = @{
        count     = $Matched.Count
        firstSeen = $sorted[0].TimeCreated.ToString('yyyy-MM-dd HH:mm')
        lastSeen  = $sorted[-1].TimeCreated.ToString('yyyy-MM-dd HH:mm')
        provider  = $sorted[-1].Provider
    }
    $text = $Template
    foreach ($key in $values.Keys) {
        $text = $text.Replace('{' + $key + '}', [string]$values[$key])
    }
    return $text
}

function Invoke-AfDiagnosis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Evidence,
        [Parameter(Mandatory)] [object[]] $Signatures,
        # Fixed "now" so tests and re-runs on saved evidence give the same answer.
        [datetime] $Now = (Get-Date),
        [int] $DefaultWithinDays = 14,
        [int] $MaxEvidencePerFinding = 20
    )

    $findings = foreach ($sig in $Signatures) {
        $m = $sig.match
        $withinDays = $DefaultWithinDays
        if ($m.PSObject.Properties['withinDays']) { $withinDays = [int]$m.withinDays }
        $minCount = 1
        if ($m.PSObject.Properties['minCount']) { $minCount = [int]$m.minCount }

        $since = $Now.AddDays(-$withinDays)
        $inWindow = @($Evidence | Where-Object { $_.TimeCreated -ge $since -and $_.TimeCreated -le $Now })

        if ($m.PSObject.Properties['all']) {
            # Every condition must be met by at least one piece of evidence.
            $perCondition = foreach ($cond in $m.all) {
                , @($inWindow | Where-Object { Test-AfCondition -Condition $cond -Evidence $_ })
            }
            if (@($perCondition | Where-Object { $_.Count -eq 0 }).Count -gt 0) { continue }
            $conditions = @($m.all)
        }
        else {
            $conditions = @($m.any)
        }

        # Evidence that meets at least one condition counts toward the finding.
        $matched = @($inWindow | Where-Object {
                $ev = $_
                @($conditions | Where-Object { Test-AfCondition -Condition $_ -Evidence $ev }).Count -gt 0
            })

        if ($matched.Count -lt $minCount -or $matched.Count -eq 0) { continue }

        $fixes = @()
        if ($sig.PSObject.Properties['fixes']) { $fixes = @($sig.fixes) }
        $category = ''
        if ($sig.PSObject.Properties['category']) { $category = $sig.category }

        [pscustomobject]@{
            PSTypeName   = 'AutoFixer.Finding'
            SignatureId  = $sig.id
            Title        = $sig.title
            Category     = $category
            Severity     = $sig.severity
            SeverityRank = $script:AfSeverityRank[[string]$sig.severity]
            Count        = $matched.Count
            FirstSeen    = ($matched | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
            LastSeen     = ($matched | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated
            Explanation  = Format-AfExplain -Template $sig.explain -Matched $matched
            Fixes        = $fixes
            Evidence     = @($matched | Sort-Object TimeCreated -Descending | Select-Object -First $MaxEvidencePerFinding)
        }
    }

    @($findings | Sort-Object SeverityRank, @{ Expression = 'Count'; Descending = $true })
}
