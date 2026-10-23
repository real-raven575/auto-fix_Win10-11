# Scan = run every collector as a Job Runner step, then diagnose what they found.

function Get-AfCollectorSteps {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)

    # Estimates are first guesses; M2 replaces them with measured history per machine.
    $p = @{ Since = $Since }
    @(
        New-AfStep -Id 'system-log' -Name 'Read System event log' -EstimatedSeconds 6 -Parameters $p -Action { param($Since) Get-AfSystemLogEvidence -Since $Since }
        New-AfStep -Id 'application-log' -Name 'Read Application event log' -EstimatedSeconds 6 -Parameters $p -Action { param($Since) Get-AfApplicationLogEvidence -Since $Since }
        New-AfStep -Id 'channels' -Name 'Read Applications and Services logs' -EstimatedSeconds 3 -Parameters $p -Action { param($Since) Get-AfChannelEvidence -Since $Since }
        New-AfStep -Id 'update-log' -Name 'Read Setup and Windows Update logs' -EstimatedSeconds 3 -Parameters $p -Action { param($Since) Get-AfUpdateLogEvidence -Since $Since }
        New-AfStep -Id 'reliability' -Name 'Read Reliability Monitor' -EstimatedSeconds 8 -Parameters $p -Action { param($Since) Get-AfReliabilityEvidence -Since $Since }
        New-AfStep -Id 'crash-dumps' -Name 'Look for crash dumps and live kernel reports' -EstimatedSeconds 1 -RequiresAdmin -Parameters $p -Action { param($Since) Get-AfCrashDumpEvidence -Since $Since }
        New-AfStep -Id 'wer' -Name 'Read Windows Error Reporting' -EstimatedSeconds 4 -Parameters $p -Action { param($Since) Get-AfWerEvidence -Since $Since }
        New-AfStep -Id 'servicing-logs' -Name 'Scan CBS and DISM logs' -EstimatedSeconds 5 -RequiresAdmin -Parameters $p -Action { param($Since) Get-AfServicingLogEvidence -Since $Since }
        New-AfStep -Id 'setupapi' -Name 'Scan device install log' -EstimatedSeconds 2 -RequiresAdmin -Parameters $p -Action { param($Since) Get-AfSetupApiEvidence -Since $Since }
        New-AfStep -Id 'devices' -Name 'Check devices for problem codes' -EstimatedSeconds 2 -Parameters $p -Action { param($Since) Get-AfDeviceEvidence -Since $Since }
    )
}

function Invoke-AutoFixerScan {
    <#
    .SYNOPSIS
        Reads this PC's logs, matches them against issue signatures and returns the results.
        Read-only: nothing on the machine is changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Redactor', Justification = 'Used by the default OnEvent script block.')]
    [CmdletBinding()]
    param(
        [ValidateRange(1, 90)] [int] $Days = 14,
        [string] $SignaturePath = (Join-Path $script:AfModuleRoot 'Signatures'),
        # Redacts what the default console reporter prints. Pass New-AfRedactor -Disabled to show real values.
        $Redactor = (New-AfRedactor),
        [scriptblock] $OnEvent,
        [object[]] $Steps
    )

    if (-not $OnEvent) {
        # Runs inside Invoke-AfSteps, which is called from here, so $Redactor resolves to this function's value.
        $OnEvent = { param($e) Write-AfConsoleEvent -ProgressEvent $e -Redactor $Redactor }
    }

    $started = Get-Date
    $since = $started.AddDays(-$Days)
    if (-not $Steps) { $Steps = Get-AfCollectorSteps -Since $since }

    $stepResults = Invoke-AfSteps -Steps $Steps -OnEvent $OnEvent
    $evidence = @($stepResults | ForEach-Object { $_.Output })
    $signatures = @(Import-AfSignature -Path $SignaturePath)
    $findings = Invoke-AfDiagnosis -Evidence $evidence -Signatures $signatures -Now $started -DefaultWithinDays $Days

    $stability = $evidence | Where-Object { $_.Source -eq 'Reliability' -and $_.Fields.ContainsKey('StabilityIndex') } |
        Select-Object -First 1

    [pscustomobject]@{
        PSTypeName     = 'AutoFixer.ScanResult'
        RunId          = $started.ToString('yyyyMMdd-HHmmss')
        StartedAt      = $started
        FinishedAt     = Get-Date
        Days           = $Days
        Machine        = Get-AfMachineInfo
        StabilityIndex = $(if ($stability) { $stability.Fields.StabilityIndex } else { $null })
        Steps          = @($stepResults | Select-Object Id, Name, Status, Seconds, Count, Summary, Error)
        EvidenceCount  = $evidence.Count
        Findings       = $findings
    }
}

function Get-AfMachineInfo {
    [CmdletBinding()]
    param()

    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { $os = $null }
    [pscustomobject]@{
        ComputerName = [Environment]::MachineName
        UserName     = [Environment]::UserName
        Domain       = [Environment]::UserDomainName
        OS           = $(if ($os) { '{0} ({1})' -f $os.Caption, $os.Version } else { [Environment]::OSVersion.VersionString })
        PowerShell   = $PSVersionTable.PSVersion.ToString()
        IsAdmin      = Test-AfIsAdmin
    }
}
