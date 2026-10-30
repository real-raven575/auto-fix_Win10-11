# settings.json lives in the tool's own folder. It holds only the user mode and the
# on/off switches and the screen style: never names, serial numbers, keys or
# anything read from the PC.

$script:AfModes = @('Standard', 'Technician')
$script:AfStyles = @('Branded', 'Plain')

function Get-AfDefaultSettings {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return [pscustomobject]@{
        SchemaVersion = 1
        Mode          = 'Standard'
        # Real values on screen. Off by default.
        ShowSensitive = $false
        # Real values in saved reports. Off by default; each scan still asks Y/N.
        SaveSensitive = $false
        # Master switch for anything that goes online. Off by default; only DISM RestoreHealth uses it.
        Online        = $false
        # Branded (the default) or Plain: the same screens without the art.
        Style         = 'Branded'
    }
}

function Read-AfSettings {
    <#
    .SYNOPSIS
        Reads settings.json. Returns $null when there is no usable file, which the
        menu treats as a first launch. A damaged file is renamed to .bad, never deleted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $problem = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($script:AfModes -notcontains [string]$raw.mode) { $problem = "unknown mode '$($raw.mode)'" }
        foreach ($name in 'showSensitive', 'saveSensitive', 'online') {
            if ($raw.$name -isnot [bool]) { $problem = "'$name' must be true or false" }
        }
        # Files saved before the style setting existed have no 'style': they get Branded.
        if ($null -ne $raw.style -and $script:AfStyles -notcontains [string]$raw.style) { $problem = "unknown style '$($raw.style)'" }
    }
    catch { $problem = 'it is not valid JSON' }

    if ($problem) {
        # Keep any older .bad file too.
        $bad = "$Path.bad"
        if (Test-Path -LiteralPath $bad) { $bad = '{0}.{1}.bad' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss') }
        Move-Item -LiteralPath $Path -Destination $bad
        Write-Warning ("settings.json could not be used ({0}). It was renamed to {1} and the defaults are used." -f $problem, (Split-Path $bad -Leaf))
        return $null
    }

    $settings = Get-AfDefaultSettings
    $settings.Mode = (Get-Culture).TextInfo.ToTitleCase(([string]$raw.mode).ToLowerInvariant())
    $settings.ShowSensitive = $raw.showSensitive
    $settings.SaveSensitive = $raw.saveSensitive
    $settings.Online = $raw.online
    if ($null -ne $raw.style) { $settings.Style = (Get-Culture).TextInfo.ToTitleCase(([string]$raw.style).ToLowerInvariant()) }
    return $settings
}

function Save-AfSettings {
    # Writes only the known keys, so nothing else can end up in the file.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $Path
    )

    $style = [string]$Settings.Style
    if ($script:AfStyles -notcontains $style) { $style = 'Branded' }
    $out = [ordered]@{
        schemaVersion = 1
        mode          = [string]$Settings.Mode
        showSensitive = [bool]$Settings.ShowSensitive
        saveSensitive = [bool]$Settings.SaveSensitive
        online        = [bool]$Settings.Online
        style         = $style
    }
    $out | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}
