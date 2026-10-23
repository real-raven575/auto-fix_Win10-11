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
        # When given, these IDs are read at any level (some useful events are Information).
        [int[]] $Id,
        [int] $MaxEvents = 5000
    )

    $filter = @{ LogName = $LogName; StartTime = $Since }
    if ($Id) { $filter.Id = $Id } else { $filter.Level = $Level }
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

# "Applications and Services" channels worth reading. Each is capped at 500
# events and filtered by ID, so the whole step stays well under a few seconds.
$script:AfChannels = @(
    # Wi-Fi: 8002 = failed to connect to a wireless network.
    @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = @(8002) }
    # Device start problems: 411 = a device had a problem starting.
    @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = @(411) }
    # Startup and shutdown slowed by a named app, driver or service (warnings 101-110).
    @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = @(101..110) }
    # Defender: 1116 threat detected, 1117 action taken, 5001 real-time protection off.
    @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1116, 1117, 5001) }
)

function Get-AfChannelEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)

    foreach ($channel in $script:AfChannels) {
        try {
            Get-AfWinEvent -LogName $channel.LogName -Since $Since -Id $channel.Id -MaxEvents 500 |
                ForEach-Object { ConvertTo-AfEventEvidence -Record $_ -Source 'Channel' }
        }
        catch {
            # Some channels need admin rights; the others are still worth reading.
            if ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception.Message -match 'unauthorized|Access is denied') {
                Write-Verbose ('Skipped {0}: access denied' -f $channel.LogName)
                continue
            }
            throw
        }
    }
}
