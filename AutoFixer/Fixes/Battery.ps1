# Battery health (Reports menu, plan 2026-11-18): Windows' own battery report, plus a plain summary.
#   - read-only: powercfg /batteryreport only writes its report file; nothing on the PC is changed
#   - the full report (battery-report.html) goes in this PC's logs folder and opens locally, never uploaded
#   - the summary shows the battery's model (to search for a replacement) but never its serial:
#     the serial is hidden on screen and in the log, and the XML copy that holds it is deleted after reading
#   - a PC with no battery gets one clear line, and nothing runs

$script:AfBatteryGoodPercent = 80
$script:AfBatteryWornPercent = 60

function Get-AfBatteryCount {
    <#
    .SYNOPSIS
        How many batteries Windows sees (Win32_Battery), or -1 when that can't be read.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([scriptblock] $GetBatteries = { Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop })

    try { return @(& $GetBatteries | Where-Object { $_ }).Count }
    catch {
        Write-Verbose ('Win32_Battery: {0}' -f $_.Exception.Message)
        return -1
    }
}

function ConvertFrom-AfBatteryXml {
    <#
    .SYNOPSIS
        Each battery in powercfg's XML battery report: Name, Manufacturer, Chemistry, Serial,
        DesignCapacity, FullChargeCapacity (mWh, or relative units when Relative is true)
        and CycleCount ($null when not reported). Reads by element name, whatever the namespace.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Xml)

    if (-not $Xml.Trim()) { return @() }
    $doc = [xml]$Xml
    $read = {
        param($Node, $Name)
        $n = $Node.SelectSingleNode(('*[local-name()="{0}"]' -f $Name))
        if ($n) { return ([string]$n.InnerText).Trim() }
        return ''
    }
    $number = {
        param($Text)
        $v = [long]0
        if ([long]::TryParse($Text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
        return $null
    }
    $list = foreach ($b in @($doc.SelectNodes('//*[local-name()="Batteries"]/*[local-name()="Battery"]'))) {
        $cycles = & $number (& $read $b 'CycleCount')
        [pscustomobject]@{
            Name               = (& $read $b 'Id')
            Manufacturer       = (& $read $b 'Manufacturer')
            Chemistry          = (& $read $b 'Chemistry')
            Serial             = (& $read $b 'SerialNumber')
            DesignCapacity     = (& $number (& $read $b 'DesignCapacity'))
            FullChargeCapacity = (& $number (& $read $b 'FullChargeCapacity'))
            # Some batteries report 0 cycles when they don't count them at all.
            CycleCount         = $(if ($cycles -gt 0) { $cycles } else { $null })
            Relative           = ((& $read $b 'RelativeCapacity') -eq '1')
        }
    }
    return @($list)
}

function Get-AfBatteryHealth {
    <#
    .SYNOPSIS
        Health (full charge as a % of design), Wear (100 - health, never below 0) and a
        Verdict: Good (80% or more), Worn (60-79%), ReplaceSoon (under 60%) or Unknown.
    #>
    [CmdletBinding()]
    param([AllowNull()] $DesignCapacity, [AllowNull()] $FullChargeCapacity)

    if ($null -eq $DesignCapacity -or $null -eq $FullChargeCapacity -or [long]$DesignCapacity -le 0 -or [long]$FullChargeCapacity -lt 0) {
        return [pscustomobject]@{ HealthPercent = $null; WearPercent = $null; Verdict = 'Unknown' }
    }
    $health = [math]::Round(([long]$FullChargeCapacity / [double]$DesignCapacity) * 100, 1)
    $verdict = 'ReplaceSoon'
    if ($health -ge $script:AfBatteryGoodPercent) { $verdict = 'Good' }
    elseif ($health -ge $script:AfBatteryWornPercent) { $verdict = 'Worn' }
    return [pscustomobject]@{ HealthPercent = $health; WearPercent = [math]::Max(0, [math]::Round(100 - $health, 1)); Verdict = $verdict }
}

function Get-AfBatteryModelText {
    # 'SMP DELL 7FHHV16': manufacturer, then the battery's name, with extra spaces taken out.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Manufacturer, [AllowEmptyString()] [string] $Name)

    $m = ($Manufacturer -replace '\s+', ' ').Trim()
    $n = ($Name -replace '\s+', ' ').Trim()
    if ($m -and $n -and $n.StartsWith($m, [StringComparison]::OrdinalIgnoreCase)) { $m = '' }
    $text = ('{0} {1}' -f $m, $n).Trim()
    if (-not $text) { return 'not reported by the battery' }
    return $text
}

function Get-AfBatteryText {
    <#
    .SYNOPSIS
        The battery summary as lines: Text and Color. The same lines go to the log.
        Never includes a serial number.
    #>
    [CmdletBinding()]
    param([object[]] $Batteries)

    $out = [System.Collections.ArrayList]::new()
    $add = { param($Text, $Color = 'Gray') $null = $out.Add([pscustomobject]@{ Text = $Text; Color = $Color }) }
    $Batteries = @($Batteries | Where-Object { $_ })
    if ($Batteries.Count -eq 0) {
        & $add 'The battery report lists no batteries.' 'Yellow'
        return $out.ToArray()
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $n = 0
    foreach ($b in $Batteries) {
        $n++
        $title = 'Battery'
        if ($Batteries.Count -gt 1) { $title = 'Battery {0}' -f $n }
        & $add $title 'DarkCyan'
        & $add ('  Model to search for : {0}' -f (Get-AfBatteryModelText -Manufacturer $b.Manufacturer -Name $b.Name)) 'White'
        $chem = $b.Chemistry
        if (-not $chem) { $chem = 'not reported' }
        & $add ('  Chemistry           : {0}' -f $chem)
        & $add '  Serial              : hidden (it is in the full report only)' 'DarkGray'
        $unit = ' mWh'
        if ($b.Relative) { $unit = ' (relative units)' }
        $cap = { param($v) if ($null -eq $v) { 'not reported' } else { ([long]$v).ToString('N0', $inv) + $unit } }
        & $add ('  Design capacity     : {0}' -f (& $cap $b.DesignCapacity))
        & $add ('  Full charge capacity: {0}' -f (& $cap $b.FullChargeCapacity))
        $cycles = 'not reported'
        if ($null -ne $b.CycleCount) { $cycles = ([long]$b.CycleCount).ToString('N0', $inv) }
        & $add ('  Charge cycles       : {0}' -f $cycles)
        $h = Get-AfBatteryHealth -DesignCapacity $b.DesignCapacity -FullChargeCapacity $b.FullChargeCapacity
        if ($h.Verdict -eq 'Unknown') {
            & $add '  Health              : not known (the battery does not report its capacity).' 'Yellow'
            continue
        }
        & $add ('  Health              : {0}% of its design capacity {1}  Wear: {2}%' -f $h.HealthPercent.ToString('0.#', $inv), (Format-AfUsageBar -Percent $h.HealthPercent), $h.WearPercent.ToString('0.#', $inv))
        switch ($h.Verdict) {
            'Good' { & $add '  Verdict             : Good. No need to replace it.' 'Green' }
            'Worn' { & $add '  Verdict             : Worn. Plan a replacement.' 'Yellow' }
            'ReplaceSoon' { & $add '  Verdict             : Replace soon. It holds well under its design charge.' 'Warning' }
        }
    }
    & $add ''
    & $add 'Search tip: search for the model line plus this PC''s make and model, best at the PC maker''s parts site.' 'DarkGray'
    return $out.ToArray()
}

function Invoke-AfPowercfg {
    # Runs powercfg.exe with -Arguments. Returns ExitCode and Output (text).
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $output = & (Get-AfSystemToolPath 'powercfg.exe') @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}

function Show-AfBatteryReport {
    <#
    .SYNOPSIS
        Battery health: runs Windows' battery report into this PC's logs folder, shows a
        plain summary and asks before opening the full report in the web browser.
        Read-only. Returns ReportPath ($null when none was made) and Batteries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [string] $Mode = 'Standard',
        [scriptblock] $GetBatteries = { Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop },
        # Called with the argument list; returns ExitCode and Output.
        [scriptblock] $RunPowercfg = { param($Arguments) Invoke-AfPowercfg -Arguments $Arguments },
        # Called with the report's .html path.
        [scriptblock] $OpenAction = { param($Path) Invoke-Item -LiteralPath $Path },
        [string] $TempFolder = [IO.Path]::GetTempPath(),
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        # The window asks its own question, after the run.
        [switch] $NoOpen
    )

    $result = [pscustomobject]@{ ReportPath = $null; Batteries = @(); NoBattery = $false }
    Write-Host ''
    Write-Host '  Battery health. Read-only: nothing is changed.' -ForegroundColor Cyan
    Write-Host ''
    $count = Get-AfBatteryCount -GetBatteries $GetBatteries
    if ($count -eq 0) {
        Write-Host '  This PC has no battery (a desktop, or the battery is not detected). Nothing to report.' -ForegroundColor Yellow
        $result.NoBattery = $true
        return $result
    }

    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'battery' -Redactor $redactor -Task 'Battery health'
    $stem = New-AfLogStem -OutputRoot $OutputRoot -Kind 'battery' -Extension 'html'
    $htmlPath = '{0}.html' -f $stem
    $xmlPath = Join-Path $TempFolder ('AF-battery-{0}.xml' -f [guid]::NewGuid().ToString('N'))
    $view = Open-AfProgressView -Title 'Battery report' -Mode $Mode
    $batteries = @()
    $failed = $null
    try {
        Update-AfProgressView -View $view -Lines @('Windows battery report (powercfg): the full report') -Percent 10
        $html = & $RunPowercfg @('/batteryreport', '/output', $htmlPath)
        if ($html.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $htmlPath)) { $failed = $html }
        else { $result.ReportPath = $htmlPath }
        Update-AfProgressView -View $view -Lines @('Windows battery report (powercfg): reading the numbers') -Percent 55
        $xml = & $RunPowercfg @('/batteryreport', '/xml', '/output', $xmlPath)
        if ($xml.ExitCode -eq 0 -and (Test-Path -LiteralPath $xmlPath)) {
            try { $batteries = @(ConvertFrom-AfBatteryXml -Xml (Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8)) }
            catch { Write-Verbose ('Battery XML: {0}' -f $_.Exception.Message) }
        }
        elseif (-not $failed) { $failed = $xml }
        Update-AfProgressView -View $view -Lines @('Done') -Percent 100
    }
    finally {
        Close-AfProgressView -View $view
        # The XML holds the serial: it is never kept.
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }

    # Serials are hidden in the log too, whatever the screen setting.
    $redactor.Serials = @(@($redactor.Serials) + @($batteries | ForEach-Object { $_.Serial } | Where-Object { $_ -and $_.Length -gt 3 }) | Sort-Object -Unique | Sort-Object Length -Descending)
    $result.Batteries = $batteries
    if ($failed) {
        $line = 'Windows battery report failed: exit code {0}. Windows could not read the battery or write the report.' -f $failed.ExitCode
        Write-Host ('  {0}' -f $line) -ForegroundColor White -BackgroundColor DarkRed
        Write-AfToolLog $toolLog $line
        if ($failed.Output) {
            $said = Protect-AfText -Redactor $redactor -Text ([string]$failed.Output)
            Write-Host ('  powercfg said: {0}' -f $said) -ForegroundColor Gray
            Write-AfToolLog $toolLog ('powercfg said: {0}' -f $said)
        }
        Write-Host ''
    }
    if ($batteries.Count -gt 0 -or -not $failed) {
        foreach ($l in @(Get-AfBatteryText -Batteries $batteries)) {
            $text = Protect-AfText -Redactor $redactor -Text $l.Text
            if ($l.Color -eq 'Warning') { Write-Host ('  {0}' -f $text) -ForegroundColor Black -BackgroundColor Yellow }
            else { Write-Host ('  {0}' -f $text) -ForegroundColor $l.Color }
            Write-AfToolLog $toolLog $l.Text
        }
    }
    Write-Host ''
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    if (-not $result.ReportPath) { return $result }

    Write-AfToolLog $toolLog ('Full report: {0}' -f $htmlPath)
    Write-Host ('  Full report: {0}' -f (Protect-AfText -Redactor $redactor -Text $htmlPath)) -ForegroundColor DarkGray
    Write-Host '  The full report shows this PC''s name and the battery serial. Check it before you share it.' -ForegroundColor Yellow
    if ($NoOpen) { return $result }
    Write-Host ''
    if ((Read-AfYesNo -Prompt 'Open the full battery report in your web browser?' -ReadKey $ReadKey) -eq $true) {
        try { & $OpenAction $htmlPath }
        catch { Write-Host ('  The report did not open: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    }
    return $result
}
