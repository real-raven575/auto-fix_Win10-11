# Sensitive data is redacted in every output (screen, results.json, report.html)
# unless the technician turns that off. Values are "scrambled" into stable
# placeholders such as <IP-1> or <EMAIL-2>: the same value gets the same
# placeholder within a run, so evidence can still be compared, but the real
# value cannot be recovered. The mapping is never written anywhere.

# Applied in this order: these patterns, then known names, then profile paths.
# Patterns go first so a name inside an email address does not break the match;
# profile paths go last so C:\Users\<name> reuses the name's placeholder.
# MAC comes before IPv6 because both use colons.
$script:AfRedactionRules = @(
    @{ Kind = 'KEY'; Pattern = '\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b' }
    @{ Kind = 'EMAIL'; Pattern = '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b' }
    @{ Kind = 'SID'; Pattern = '\bS-1-5-21(?:-\d+){3,4}\b' }
    @{ Kind = 'MAC'; Pattern = '\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b' }
    @{ Kind = 'IP'; Pattern = '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b' }
    @{ Kind = 'IP'; Pattern = '(?i)\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b|(?i)\bfe80::[0-9a-f:%]+' }
)

# C:\Users\<name>\... - the profile folder name is usually a user's name.
$script:AfProfileRule = @{ Kind = 'USER'; Pattern = '(?i)(?<=\b[A-Z]:\\Users\\)(?!<|Public\b|Default\b|All Users\b)[^\\/\s"''<>]+' }

function New-AfRedactor {
    <#
    .SYNOPSIS
        Creates the redactor for one run. -Disabled passes text through unchanged.
    #>
    [CmdletBinding()]
    param(
        # Exact values to hide: by default this PC's user, machine and domain names.
        [string[]] $Names = @([Environment]::UserName, [Environment]::MachineName, [Environment]::UserDomainName),
        [switch] $Disabled
    )

    # Short names (2 characters or fewer) would wreck normal words, so they are skipped.
    $known = @($Names | Where-Object { $_ -and $_.Length -gt 2 } | Sort-Object -Unique | Sort-Object Length -Descending)
    [pscustomobject]@{
        PSTypeName = 'AutoFixer.Redactor'
        Enabled    = -not $Disabled
        Names      = $known
        Map        = @{}
        Counters   = @{}
    }
}

function Get-AfRedactionToken {
    param([Parameter(Mandatory)] $Redactor, [Parameter(Mandatory)] [string] $Kind, [Parameter(Mandatory)] [string] $Value)

    $key = '{0}|{1}' -f $Kind, $Value.ToLowerInvariant()
    if (-not $Redactor.Map.ContainsKey($key)) {
        $next = 1
        if ($Redactor.Counters.ContainsKey($Kind)) { $next = $Redactor.Counters[$Kind] + 1 }
        $Redactor.Counters[$Kind] = $next
        $Redactor.Map[$key] = '<{0}-{1}>' -f $Kind, $next
    }
    return $Redactor.Map[$key]
}

function Invoke-AfRedactionRule {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Redactor', Justification = 'Used inside the MatchEvaluator script block.')]
    param($Redactor, [hashtable] $Rule, [string] $Text)
    $kind = $Rule.Kind
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        Get-AfRedactionToken -Redactor $Redactor -Kind $kind -Value $m.Value
    }
    return [regex]::Replace($Text, $Rule.Pattern, $evaluator)
}

function Protect-AfText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Redactor,
        [AllowNull()] [AllowEmptyString()] [string] $Text
    )

    if (-not $Text -or $null -eq $Redactor -or -not $Redactor.Enabled) { return $Text }

    foreach ($rule in $script:AfRedactionRules) {
        $Text = Invoke-AfRedactionRule -Redactor $Redactor -Rule $rule -Text $Text
    }
    foreach ($name in $Redactor.Names) {
        $token = Get-AfRedactionToken -Redactor $Redactor -Kind 'NAME' -Value $name
        $Text = [regex]::Replace($Text, [regex]::Escape($name), $token, 'IgnoreCase')
    }
    $Text = Invoke-AfRedactionRule -Redactor $Redactor -Rule $script:AfProfileRule -Text $Text
    return $Text
}

function Confirm-AfSaveSensitive {
    <#
    .SYNOPSIS
        The "are you sure?" gate before unredacted data is written to disk.
        Returns $true only when the technician types YES.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Answer)

    if (-not $PSBoundParameters.ContainsKey('Answer')) {
        Write-Host ''
        Write-Host '  WARNING: you are about to SAVE reports WITHOUT redaction.' -ForegroundColor Red
        Write-Host '  User names, PC names, IP and MAC addresses, emails and file paths will be' -ForegroundColor Red
        Write-Host '  readable by anyone who gets the report files.' -ForegroundColor Red
        $Answer = Read-Host '  Are you sure? Type YES to save unredacted, anything else to keep redaction on'
    }
    return ($Answer -ceq 'YES')
}
