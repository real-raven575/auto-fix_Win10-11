# Writes a scan result to disk: results.json for tools and later runs,
# report.html for the person at the PC. Both are redacted by default (Core/Redaction.ps1).

function ConvertTo-AfReportModel {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] $Redactor)

    $r = $Redactor

    [pscustomobject]@{
        schemaVersion  = 1
        runId          = $Result.RunId
        startedAt      = $Result.StartedAt.ToString('o')
        finishedAt     = $Result.FinishedAt.ToString('o')
        days           = $Result.Days
        redacted       = [bool]$Redactor.Enabled
        machine        = [pscustomobject]@{
            computerName = Protect-AfText -Redactor $r -Text $Result.Machine.ComputerName
            os           = $Result.Machine.OS
            powerShell   = $Result.Machine.PowerShell
            isAdmin      = $Result.Machine.IsAdmin
        }
        stabilityIndex = $Result.StabilityIndex
        evidenceCount  = $Result.EvidenceCount
        steps          = @($Result.Steps | ForEach-Object {
                [pscustomobject]@{ id = $_.Id; name = $_.Name; status = $_.Status; seconds = $_.Seconds; count = $_.Count; summary = Protect-AfText -Redactor $r -Text $_.Summary }
            })
        findings       = @($Result.Findings | ForEach-Object {
                [pscustomobject]@{
                    signatureId = $_.SignatureId
                    title       = $_.Title
                    category    = $_.Category
                    severity    = $_.Severity
                    count       = $_.Count
                    firstSeen   = $_.FirstSeen.ToString('o')
                    lastSeen    = $_.LastSeen.ToString('o')
                    explanation = Protect-AfText -Redactor $r -Text $_.Explanation
                    fixes       = @($_.Fixes)
                    evidence    = @($_.Evidence | ForEach-Object {
                            [pscustomobject]@{
                                time = $_.TimeCreated.ToString('o'); source = $_.Source; provider = $_.Provider
                                eventId = $_.EventId; message = Protect-AfText -Redactor $r -Text $_.Message; path = Protect-AfText -Redactor $r -Text $_.Path
                            }
                        })
                }
            })
    }
}

function ConvertTo-AfHtml {
    param([string] $Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Get-AfHtmlReport {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Model)

    $e = { param($t) ConvertTo-AfHtml $t }
    $sb = New-Object System.Text.StringBuilder

    $findingCount = @($Model.findings).Count
    $headline = 'No known problems found in the last {0} days.' -f $Model.days
    if ($findingCount -gt 0) { $headline = '{0} problem(s) found in the last {1} days.' -f $findingCount, $Model.days }
    $redactedText = 'redacted'
    if (-not $Model.redacted) { $redactedText = 'NOT redacted - handle this file with care' }
    $stability = 'n/a'
    if ($null -ne $Model.stabilityIndex) { $stability = '{0:N1} / 10' -f $Model.stabilityIndex }

    [void]$sb.Append(@"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>auto-fix_Win report $(& $e $Model.runId)</title>
<style>
:root { --bg:#fff; --fg:#1d1d1f; --muted:#5f6368; --line:#e0e0e0; --card:#f7f7f8;
  --critical:#b3261e; --high:#d9480f; --medium:#b7791f; --low:#2b6cb0; --info:#5f6368; }
@media (prefers-color-scheme: dark) { :root { --bg:#151517; --fg:#ececec; --muted:#a0a0a8; --line:#33343a; --card:#1e1f23; } }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 "Segoe UI", system-ui, sans-serif; }
main { max-width:960px; margin:0 auto; padding:24px 16px 48px; }
h1 { font-size:24px; margin:0 0 4px; } h2 { font-size:18px; margin:32px 0 8px; }
.muted { color:var(--muted); } .card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:16px; margin:12px 0; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px; color:#fff; font-size:12px; font-weight:600; margin-right:8px; }
.Critical { background:var(--critical); } .High { background:var(--high); } .Medium { background:var(--medium); } .Low { background:var(--low); } .Info { background:var(--info); }
table { width:100%; border-collapse:collapse; font-size:13px; } th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
code { font-family:Consolas, monospace; font-size:12px; } details summary { cursor:pointer; color:var(--muted); margin-top:8px; }
.Done { color:#2f855a; } .Skipped { color:var(--medium); } .Failed { color:var(--critical); }
</style></head><body><main>
<h1>auto-fix_Win report</h1>
<p class="muted">$(& $e $Model.machine.computerName) &middot; $(& $e $Model.machine.os) &middot; run $(& $e $Model.runId)</p>
<div class="card"><strong>$(& $e $headline)</strong><br>
<span class="muted">Stability index $(& $e $stability) &middot; $(& $e $Model.evidenceCount) log entries checked &middot; administrator: $(& $e $Model.machine.isAdmin) &middot; sensitive data: $(& $e $redactedText)</span></div>
<h2>Findings</h2>
"@)

    if ($findingCount -eq 0) {
        [void]$sb.Append('<p class="muted">Nothing matched a known problem signature.</p>')
    }
    foreach ($f in $Model.findings) {
        $fixes = 'Advice only'
        if (@($f.fixes).Count -gt 0) { $fixes = (@($f.fixes) | ForEach-Object { '<code>' + (& $e $_) + '</code>' }) -join ', ' }
        [void]$sb.Append(@"
<div class="card"><span class="badge $(& $e $f.severity)">$(& $e $f.severity)</span><strong>$(& $e $f.title)</strong>
<p>$(& $e $f.explanation)</p>
<p class="muted">Suggested fixes: $fixes</p>
<details><summary>Evidence ($(& $e $f.count) entries, newest first)</summary><table><tr><th>Time</th><th>Source</th><th>Event</th><th>Message</th></tr>
"@)
        foreach ($ev in $f.evidence) {
            $msg = [string]$ev.message
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
            [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2} {3}</td><td>{4}</td></tr>' -f
                    (& $e ([datetime]$ev.time).ToString('yyyy-MM-dd HH:mm')), (& $e $ev.source), (& $e $ev.provider), (& $e $ev.eventId), (& $e $msg)))
        }
        [void]$sb.Append('</table></details></div>')
    }

    [void]$sb.Append('<h2>What was checked</h2><table><tr><th>Step</th><th>Result</th><th>Items</th><th>Time</th></tr>')
    foreach ($s in $Model.steps) {
        [void]$sb.Append(('<tr><td>{0}</td><td class="{1}">{1}: {2}</td><td>{3}</td><td>{4} s</td></tr>' -f
                (& $e $s.name), (& $e $s.status), (& $e $s.summary), (& $e $s.count), (& $e $s.seconds)))
    }
    [void]$sb.Append('</table><p class="muted">auto-fix_Win only read logs during this scan. Nothing on this PC was changed.</p></main></body></html>')
    return $sb.ToString()
}

function Export-AutoFixerReport {
    <#
    .SYNOPSIS
        Saves results.json and report.html for a scan into a per-run folder and returns that folder.
        Sensitive data is redacted unless -IncludeSensitive is given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [string] $OutputRoot = (Join-Path $env:ProgramData 'AutoFixer\Runs'),
        # Reuse the on-screen redactor so placeholders match between screen and file.
        $Redactor,
        # Saves real values. Callers must confirm with the technician first (Confirm-AfSaveSensitive).
        [switch] $IncludeSensitive
    )

    if ($IncludeSensitive) {
        $Redactor = New-AfRedactor -Disabled
    }
    elseif (-not $Redactor -or -not $Redactor.Enabled) {
        $Redactor = New-AfRedactor -Names @($Result.Machine.UserName, $Result.Machine.ComputerName, $Result.Machine.Domain)
    }

    $dir = Join-Path $OutputRoot $Result.RunId
    $null = New-Item -Path $dir -ItemType Directory -Force
    $model = ConvertTo-AfReportModel -Result $Result -Redactor $Redactor

    $model | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $dir 'results.json') -Encoding UTF8
    Get-AfHtmlReport -Model $model | Set-Content -Path (Join-Path $dir 'report.html') -Encoding UTF8
    return Get-Item -Path $dir
}
