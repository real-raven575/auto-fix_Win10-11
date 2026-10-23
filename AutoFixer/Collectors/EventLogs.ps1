# Event log collectors: System, Application, and Setup plus Windows Update.
# All read-only. Get-WinEvent throws when nothing matches, which is not an error here.

function ConvertTo-AfEventEvidence {
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string] $Source)

    $message = ''
    try { $message = [string]$Record.Message } catch { $message = '' }
    if (-not $message) { $message = '(no message text for event {0})' -f $Record.Id }

    New-AfEvidence -Source $Source -TimeCreated $Record.TimeCreated -Provider $Record.ProviderName `
        -EventId $Record.Id -Level $Record.Level -Message $message -Path $Record.LogName
}

function Get-AfWinEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogName,
        [Parameter(Mandatory)] [datetime] $Since,
        [int[]] $Level = @(1, 2, 3),
        [int] $MaxEvents = 5000
    )

    $filter = @{ LogName = $LogName; StartTime = $Since; Level = $Level }
    try {
        Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
    }
    catch {
        # "No events were found" and a missing log both mean: nothing to report.
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound|NoMatchingLogsFound') { return }
        if ($_.Exception.Message -match 'No events were found|There is not an event log') { return }
        throw
    }
}

function Get-AfSystemLogEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)
    Get-AfWinEvent -LogName 'System' -Since $Since | ForEach-Object { ConvertTo-AfEventEvidence -Record $_ -Source 'System' }
}

function Get-AfApplicationLogEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)
    Get-AfWinEvent -LogName 'Application' -Since $Since | ForEach-Object { ConvertTo-AfEventEvidence -Record $_ -Source 'Application' }
}

function Get-AfUpdateLogEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)
    Get-AfWinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -Since $Since -Level @(1, 2) |
        ForEach-Object { ConvertTo-AfEventEvidence -Record $_ -Source 'WindowsUpdate' }
    Get-AfWinEvent -LogName 'Setup' -Since $Since -Level @(1, 2) |
        ForEach-Object { ConvertTo-AfEventEvidence -Record $_ -Source 'Setup' }
}
