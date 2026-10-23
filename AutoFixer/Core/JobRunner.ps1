# The Job Runner drives every step of a run and reports what it is doing through
# events. Front ends (the M2 menu CLI, the M5 GUI) only listen to these events,
# so they never need to know what a step actually does.
#
# Event shape: @{ Type; Step; Index; Total; Status; Percent; SecondsLeft; Elapsed; Summary; Error }
#   Type is StepStarted or StepCompleted. Status is Running, Done, Skipped or Failed.

function New-AfStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Action,
        [hashtable] $Parameters = @{},
        [double] $EstimatedSeconds = 5,
        [switch] $RequiresAdmin
    )

    [pscustomobject]@{
        PSTypeName       = 'AutoFixer.Step'
        Id               = $Id
        Name             = $Name
        Action           = $Action
        Parameters       = $Parameters
        EstimatedSeconds = [math]::Max(0.1, $EstimatedSeconds)
        RequiresAdmin    = [bool]$RequiresAdmin
    }
}

function Get-AfProgress {
    # Overall progress is weighted by expected time, not step count, so one slow
    # step does not make the bar jump at the end.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Steps,
        [Parameter(Mandatory)] [int] $CompletedCount
    )

    $total = ($Steps | Measure-Object -Property EstimatedSeconds -Sum).Sum
    $done = 0
    if ($CompletedCount -gt 0) {
        $done = ($Steps | Select-Object -First $CompletedCount | Measure-Object -Property EstimatedSeconds -Sum).Sum
    }
    [pscustomobject]@{
        Percent     = [int][math]::Floor(100 * $done / $total)
        SecondsLeft = [int][math]::Ceiling($total - $done)
    }
}

function Invoke-AfSteps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Steps,
        [scriptblock] $OnEvent = { param($e) },
        [bool] $IsAdmin = (Test-AfIsAdmin)
    )

    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        $progress = Get-AfProgress -Steps $Steps -CompletedCount $i
        & $OnEvent @{
            Type = 'StepStarted'; Step = $step.Name; Index = $i; Total = $Steps.Count
            Status = 'Running'; Percent = $progress.Percent; SecondsLeft = $progress.SecondsLeft
        }

        $watch = [Diagnostics.Stopwatch]::StartNew()
        $output = @()
        $errorText = $null
        if ($step.RequiresAdmin -and -not $IsAdmin) {
            $status = 'Skipped'
            $summary = 'Needs administrator rights'
        }
        else {
            try {
                $params = $step.Parameters
                $output = @(& $step.Action @params)
                $status = 'Done'
                $summary = '{0} item(s)' -f $output.Count
            }
            catch {
                $status = 'Failed'
                $errorText = $_.Exception.Message
                $summary = $errorText
            }
        }
        $watch.Stop()

        $result = [pscustomobject]@{
            Id       = $step.Id
            Name     = $step.Name
            Status   = $status
            Seconds  = [math]::Round($watch.Elapsed.TotalSeconds, 2)
            Count    = $output.Count
            Summary  = $summary
            Error    = $errorText
            Output   = $output
        }
        $results.Add($result)

        $progress = Get-AfProgress -Steps $Steps -CompletedCount ($i + 1)
        & $OnEvent @{
            Type = 'StepCompleted'; Step = $step.Name; Index = $i; Total = $Steps.Count
            Status = $status; Percent = $progress.Percent; SecondsLeft = $progress.SecondsLeft
            Elapsed = $result.Seconds; Summary = $summary; Error = $errorText
        }
    }
    return $results.ToArray()
}

function Write-AfConsoleEvent {
    # Plain M1 reporter: Write-Progress for the bar plus one activity line per step.
    # The M2 menu CLI replaces this with its own ASCII renderer.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $ProgressEvent)

    $activity = 'Auto-Fixer scan'
    if ($ProgressEvent.Type -eq 'StepStarted') {
        $status = '{0} ({1} of {2}) - about {3}s left' -f $ProgressEvent.Step, ($ProgressEvent.Index + 1), $ProgressEvent.Total, $ProgressEvent.SecondsLeft
        Write-Progress -Activity $activity -Status $status -PercentComplete $ProgressEvent.Percent
        return
    }

    $colors = @{ Done = 'Green'; Skipped = 'Yellow'; Failed = 'Red' }
    $line = '[{0,-7}] {1} - {2} ({3} s)' -f $ProgressEvent.Status.ToLower(), $ProgressEvent.Step, $ProgressEvent.Summary, $ProgressEvent.Elapsed
    Write-Host $line -ForegroundColor $colors[$ProgressEvent.Status]
    if ($ProgressEvent.Index + 1 -eq $ProgressEvent.Total) {
        Write-Progress -Activity $activity -Completed
    }
}
