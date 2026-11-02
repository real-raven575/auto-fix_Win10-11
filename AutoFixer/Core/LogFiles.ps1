# Where Auto-Fixer keeps its own logs and reports: one folder per PC, and every file
# named with a PC id plus the UTC date and time, such as
#   Runs\PC-K7Q2M9\AF-K7Q2M9-20261029-233547Z-repair.log
# The PC id is random, made once and kept in ProgramData, so it says nothing about the
# PC (no name, serial, user or Windows id) yet stays the same for every copy of the tool.
# Windows' own logs are never moved or renamed; old per-run folders are left as they are.

# Letters and digits that can't be mixed up when read aloud or typed (no 0/O, 1/I).
$script:AfPcIdAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
$script:AfPcIdPath = $(if ($env:ProgramData) { Join-Path $env:ProgramData 'AutoFixer\pc-id.txt' } else { $null })
$script:AfPcId = $null

function New-AfPcIdText {
    # 6 characters from a cryptographic random source. 256 is a multiple of 32, so each is equally likely.
    [OutputType([string])]
    param()

    $bytes = New-Object byte[] 6
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join @($bytes | ForEach-Object { $script:AfPcIdAlphabet[$_ % 32] })
}

function Get-AfPcId {
    <#
    .SYNOPSIS
        This PC's id. Read from pc-id.txt, or made and saved there on first use. If the
        file can't be written the id still works for this session and the next start makes a new one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path = $script:AfPcIdPath)

    if ($script:AfPcId -and $Path -eq $script:AfPcIdPath) { return $script:AfPcId }
    $id = $null
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $saved = ([string](Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)).Trim()
        if ($saved -cmatch '^[A-HJ-NP-Z2-9]{6}$') { $id = $saved }
    }
    if (-not $id) {
        $id = New-AfPcIdText
        if ($Path) {
            try {
                $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop
                Set-Content -LiteralPath $Path -Value $id -Encoding ASCII -ErrorAction Stop
            }
            catch { Write-Verbose ('pc-id.txt not saved: {0}' -f $_.Exception.Message) }
        }
    }
    if ($Path -eq $script:AfPcIdPath) { $script:AfPcId = $id }
    return $id
}

function Get-AfPcFolder {
    # Runs\PC-<id>, made if missing unless -NoCreate. Every log and report for this PC goes here.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $OutputRoot, [switch] $NoCreate)

    $folder = Join-Path $OutputRoot ('PC-{0}' -f (Get-AfPcId))
    if (-not $NoCreate) { $null = New-Item -ItemType Directory -Path $folder -Force }
    return $folder
}

function Get-AfLogStamp {
    # 20261029-233547Z: UTC, so files from PCs in different time zones sort and compare correctly.
    [OutputType([string])]
    param([datetime] $Time = (Get-Date))
    $Time.ToUniversalTime().ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
}

function New-AfLogStem {
    <#
    .SYNOPSIS
        A full path without extension, such as ...\PC-K7Q2M9\AF-K7Q2M9-20261029-233547Z-scan.
        When any of the -Extension files already exists, -2, -3 and so on go after the
        time, so a file is never overwritten.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        # scan, repair, network, domain.
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string[]] $Extension,
        [string] $Stamp = (Get-AfLogStamp)
    )

    $folder = Get-AfPcFolder -OutputRoot $OutputRoot
    $id = Get-AfPcId
    for ($n = 1; ; $n++) {
        $suffix = $(if ($n -gt 1) { '-{0}' -f $n } else { '' })
        $stem = Join-Path $folder ('AF-{0}-{1}{2}-{3}' -f $id, $Stamp, $suffix, $Kind)
        if (-not @($Extension | Where-Object { Test-Path -LiteralPath ('{0}.{1}' -f $stem, $_) })) { return $stem }
    }
}

function Get-AfHistoryPath {
    <#
    .SYNOPSIS
        repair-history.csv (time estimates) for this PC. Menus only read, so until this PC's
        folder has one they read an older one in the Runs folder. -Prepare, used before a
        repair writes to it, makes the folder and copies the older file in once (never moves it).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $OutputRoot, [switch] $Prepare)

    $path = Join-Path (Get-AfPcFolder -OutputRoot $OutputRoot -NoCreate:(-not $Prepare)) 'repair-history.csv'
    $old = Join-Path $OutputRoot 'repair-history.csv'
    if ((Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath $old)) { return $path }
    if (-not $Prepare) { return $old }
    try { Copy-Item -LiteralPath $old -Destination $path -ErrorAction Stop }
    catch { Write-Verbose ('Older repair history not copied: {0}' -f $_.Exception.Message) }
    return $path
}

function Open-AfLogFolder {
    <#
    .SYNOPSIS
        Opens this PC's logs folder (Runs\PC-<id>) in File Explorer and returns one short
        line for the menu to show. The folder is made first if it isn't there yet, the
        same folder the next scan or repair would make. Nothing else is changed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        # Called with the folder path. The default starts File Explorer there.
        [scriptblock] $OpenAction = { param($Path) Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop }
    )

    # Lines stay under 77 characters so they fit the menu screen's message row.
    try { $folder = Get-AfPcFolder -OutputRoot $OutputRoot }
    catch { return ('The logs folder could not be made: {0}' -f $_.Exception.Message) }
    $empty = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue).Count -eq 0
    try { & $OpenAction $folder }
    catch {
        Write-Verbose ('Explorer did not open: {0}' -f $_.Exception.Message)
        return ('Explorer did not open. Logs folder: {0}' -f $folder)
    }
    # Older versions saved each run in its own folder straight under Runs.
    $older = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'PC-*' })
    if ($older.Count -gt 0) { return 'Opened the logs folder. Older runs are one folder up, in Runs.' }
    if ($empty) { return 'Opened the logs folder. It stays empty until the first scan or repair.' }
    return ('Opened the logs folder: {0}' -f $folder)
}
