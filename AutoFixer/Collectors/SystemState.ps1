# Collectors that read machine state rather than logs: Reliability Monitor,
# crash dump files and devices with a problem code.

function Get-AfReliabilityEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)

    # The stability index (1 to 10) is a quick health score for the report header.
    $metric = Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction Stop |
        Sort-Object TimeGenerated -Descending | Select-Object -First 1
    if ($metric) {
        New-AfEvidence -Source 'Reliability' -TimeCreated $metric.TimeGenerated -Provider 'StabilityIndex' `
            -Message ('Stability index {0:N1} of 10' -f $metric.SystemStabilityIndex) `
            -Fields @{ StabilityIndex = [double]$metric.SystemStabilityIndex }
    }

    # Reliability records are the only reliable source of update installs and install
    # failures on some Windows 10 PCs, where the WindowsUpdateClient log keeps only
    # download and scan failures. WMI wants the time in DMTF format, in UTC.
    $dmtf = $Since.ToUniversalTime().ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture) + '.000000+000'
    $records = Get-CimInstance -ClassName Win32_ReliabilityRecords -Filter "TimeGenerated >= '$dmtf'" -ErrorAction Stop
    foreach ($record in $records) {
        New-AfEvidence -Source 'Reliability' -TimeCreated $record.TimeGenerated -Provider $record.SourceName `
            -EventId ([int]$record.EventIdentifier) -Message $record.Message `
            -Fields @{ ProductName = $record.ProductName }
    }
}

function Get-AfCrashDumpEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $Since,
        [string] $WindowsRoot = $env:SystemRoot
    )

    $paths = @(
        (Join-Path $WindowsRoot 'Minidump\*.dmp'),
        (Join-Path $WindowsRoot 'MEMORY.DMP')
    )
    foreach ($file in (Get-ChildItem -Path $paths -File -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTime -lt $Since) { continue }
        New-AfEvidence -Source 'Minidump' -TimeCreated $file.LastWriteTime -Provider 'CrashDump' `
            -Level 1 -Message ('Crash dump {0} ({1:N0} KB)' -f $file.Name, ($file.Length / 1KB)) -Path $file.FullName
    }

    # Live kernel reports are dumps of hangs Windows recovered from without a blue
    # screen, filed by component (WATCHDOG = graphics timeouts, USBXHCI, NDIS, PoW).
    $live = Join-Path $WindowsRoot 'LiveKernelReports'
    foreach ($file in (Get-ChildItem -Path $live -Filter '*.dmp' -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTime -lt $Since) { continue }
        $component = $file.Directory.Name
        New-AfEvidence -Source 'LiveKernel' -TimeCreated $file.LastWriteTime -Provider $component `
            -Level 2 -Message ('Recovered {0} hang, dump {1}' -f $component, $file.Name) -Path $file.FullName `
            -Fields @{ Component = $component }
    }
}

function Get-AfDeviceEvidence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Since', Justification = 'Every collector takes -Since; this one reads current state.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [datetime] $Since)

    # ConfigManagerErrorCode 0 is "working"; 10 is "cannot start", 43 is "stopped after reporting problems".
    $devices = Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop
    foreach ($device in $devices) {
        # Code 22 is "disabled by the user" - a choice, not a fault.
        if ($device.ConfigManagerErrorCode -eq 22) { continue }
        New-AfEvidence -Source 'PnP' -Provider 'PnP' -EventId ([int]$device.ConfigManagerErrorCode) -Level 2 `
            -Message ('{0} has problem code {1}' -f $device.Name, $device.ConfigManagerErrorCode) `
            -Path $device.PNPDeviceID -Fields @{ DeviceName = $device.Name; InstanceId = $device.PNPDeviceID }
    }
}
