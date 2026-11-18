# Back up PSTs (WORK-0033, TEAM 9to5 script 2b, rewritten). Copies every PST of one Windows
# user to a backup folder and checks each copy with SHA-256. Originals are only read. Both
# modes, stock Windows only. The Purview PST Import add-on uploads from this folder.

function Get-AfPstFolderList {
    # The places Outlook keeps PSTs for one Windows user: its own folder, Documents and OneDrive Documents.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $UserProfile)

    $list = @((Join-Path $UserProfile 'AppData\Local\Microsoft\Outlook'), (Join-Path $UserProfile 'Documents'))
    $list += @(Get-ChildItem -LiteralPath $UserProfile -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'Documents' })
    return @($list | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

function Get-AfPstBackupSource {
    <#
    .SYNOPSIS
        One row per Windows user folder in C:\Users that holds PST files: Folder, Files, Bytes.
        Read-only. Auto-Fixer runs as an administrator, so it can see every user's folder.
    #>
    [CmdletBinding()]
    param([string] $UsersRoot = (Join-Path $env:SystemDrive 'Users'))

    $skip = @('Public', 'Default', 'Default User', 'All Users')
    foreach ($u in @(Get-ChildItem -LiteralPath $UsersRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $skip -notcontains $_.Name })) {
        $files = @(foreach ($f in (Get-AfPstFolderList -UserProfile $u.FullName)) {
                # Filtered by extension: Windows PowerShell 5.1 ignores -Include together with -LiteralPath.
                Get-ChildItem -LiteralPath $f -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.pst' }
            })
        $files = @($files | Sort-Object FullName -Unique)
        if ($files.Count) {
            [pscustomobject]@{ Folder = $u.FullName; Files = $files; Bytes = [long](($files | Measure-Object Length -Sum).Sum) }
        }
    }
}

function Get-AfPstOrgName {
    # Company names from "OneDrive - <company>" folders, so the redactor can hide them.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([object[]] $Files)
    return @($Files | ForEach-Object { if ($_.FullName -match '\\OneDrive - ([^\\]+)\\') { $Matches[1] } } | Sort-Object -Unique)
}

function Get-AfPstBackupTarget {
    # The copy's file name: the original name, or name-2.pst, name-3.pst when two PSTs share a name.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Destination, [Parameter(Mandatory)] [string] $Name, [hashtable] $Used = @{})

    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    $try = $Name
    $n = 1
    while ($Used.ContainsKey($try.ToLowerInvariant()) -or (Test-Path -LiteralPath (Join-Path $Destination $try))) {
        $n++
        $try = '{0}-{1}{2}' -f $base, $n, $ext
    }
    $Used[$try.ToLowerInvariant()] = $true
    return (Join-Path $Destination $try)
}

function Invoke-AfPstBackup {
    <#
    .SYNOPSIS
        Back up PSTs: pick the Windows user, show the plan and the free space, Y/N, then copy each
        PST and compare SHA-256 of original and copy. Writes hashes-sha256.txt next to the copies.
        Returns the rows (Status, File, Bytes, Hash) or nothing when stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        $Redactor = (New-AfRedactor),
        [scriptblock] $GetState = { Get-AfClassicOutlookState },
        [scriptblock] $GetSources = { Get-AfPstBackupSource },
        [string] $DefaultDestination = (Join-Path ($env:SystemDrive + '\') ('PSTBackup-{0}' -f (Get-Date -Format 'yyyyMMdd'))),
        [scriptblock] $GetFreeBytes = { param($Path) ([IO.DriveInfo]([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace }
    )

    $screenRedactor = $Redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screenRedactor -Text $Text }

    if ((& $GetState).ClassicRunning) {
        Write-Host '  Outlook is open. Please close Outlook (the user may need to), then run this again.' -ForegroundColor Yellow
        Write-Host '  An open PST can copy half-written. Nothing was changed.' -ForegroundColor Yellow
        return
    }
    $sources = @(& $GetSources)
    if (-not $sources.Count) {
        Write-Host '  No PST files were found in any user''s Outlook folder, Documents or OneDrive Documents.' -ForegroundColor Yellow
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return
    }
    # User folder names and OneDrive company names are hidden like other names.
    Add-AfRedactionName -Redactor $Redactor -Names (@($sources | ForEach-Object { Split-Path $_.Folder -Leaf }) + (Get-AfPstOrgName -Files @($sources.Files)))

    $pick = $sources[0]
    if ($sources.Count -gt 1) {
        Write-Host ''
        Write-Host '  Windows users with PST files:' -ForegroundColor White
        for ($i = 0; $i -lt $sources.Count; $i++) {
            Write-Host ('    {0}. {1}  ({2} PST, {3})' -f ($i + 1), (& $show $sources[$i].Folder), $sources[$i].Files.Count, (Format-AfSize $sources[$i].Bytes))
        }
        $ans = [string](& $ReadText ('Number of the user to back up (Enter = stop)'))
        if ($ans -notmatch '^\d+$' -or [int]$ans -lt 1 -or [int]$ans -gt $sources.Count) {
            Write-Host '  No user picked. Nothing was changed.' -ForegroundColor Yellow
            return
        }
        $pick = $sources[[int]$ans - 1]
    }

    $dest = [string](& $ReadText ('Backup folder (Enter = {0})' -f $DefaultDestination))
    if (-not $dest.Trim()) { $dest = $DefaultDestination }
    $dest = $dest.Trim().Trim('"')
    if (-not [IO.Path]::IsPathRooted($dest)) {
        Write-Host '  Give a full path such as D:\PSTBackup. Nothing was changed.' -ForegroundColor Yellow
        return
    }
    $files = @($pick.Files | Sort-Object Length)
    $need = [long]$pick.Bytes
    $free = [long](& $GetFreeBytes $dest)
    Write-Host ''
    Write-Host ('  This will copy {0} PST file(s), {1} in all, to {2}:' -f $files.Count, (Format-AfSize $need), (& $show $dest)) -ForegroundColor White
    foreach ($f in $files) { Write-Host ('    {0,10}  {1}' -f (Format-AfSize $f.Length), (& $show $f.FullName)) }
    Write-Host ('  Free space there: {0}.' -f (Format-AfSize $free))
    # Copies may use at most 80% of the free space, so Windows keeps room to work.
    if (-not (Test-AfTempSpace -NeedBytes $need -FreeBytes $free)) {
        Write-Host ('  Not enough free space: about {0} is needed (the copies plus 20% spare). Pick another drive. Nothing was changed.' -f (Format-AfSize ([long]($need / 0.8)))) -ForegroundColor Red
        return
    }
    Write-Host '  Originals are only read. Each copy is checked against its original with SHA-256.' -ForegroundColor Gray
    Write-Host '  Undo: delete the backup folder.' -ForegroundColor DarkGray
    if ((Read-AfYesNo -Prompt 'Copy the PST files?' -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return
    }

    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'outlook' -Redactor $Redactor -Task 'Back up PSTs (copy + SHA-256 check)'
    Write-AfToolLog $toolLog ('Backup folder: {0}' -f $dest)
    $null = New-Item -ItemType Directory -Path $dest -Force
    $used = @{}
    $i = 0
    $rows = foreach ($f in $files) {
        $i++
        Write-Host ('  [{0} of {1}] {2} ({3})' -f $i, $files.Count, (& $show $f.Name), (Format-AfSize $f.Length))
        $target = Get-AfPstBackupTarget -Destination $dest -Name $f.Name -Used $used
        $status = 'FAILED'
        $hash = ''
        try {
            Copy-Item -LiteralPath $f.FullName -Destination $target -ErrorAction Stop
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
            if ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -eq $hash) { $status = 'OK' }
            else { $status = 'MISMATCH' }
        }
        catch { Write-AfToolLog $toolLog ('FAILED    {0}: {1}' -f $f.Name, $_.Exception.Message) }
        $color = @{ OK = 'Green'; MISMATCH = 'Red'; FAILED = 'Red' }[$status]
        Write-Host ('      {0}' -f @{ OK = 'copied and verified'; MISMATCH = 'copy does NOT match the original: do not use it'; FAILED = 'could not copy (in use or no access)' }[$status]) -ForegroundColor $color
        Write-AfToolLog $toolLog ('{0,-9} {1,10}  {2} -> {3}' -f $status, (Format-AfSize $f.Length), $f.FullName, (Split-Path $target -Leaf))
        [pscustomobject]@{ Status = $status; File = (Split-Path $target -Leaf); Source = $f.FullName; Bytes = [long]$f.Length; Hash = $hash }
    }
    $rows = @($rows)
    # Same layout as Get-FileHash output, so it can be checked again later.
    $hashFile = Join-Path $dest 'hashes-sha256.txt'
    @($rows | Where-Object Status -EQ 'OK' | ForEach-Object { '{0}  {1}' -f $_.Hash, $_.File }) | Set-Content -LiteralPath $hashFile -Encoding ASCII

    $ok = @($rows | Where-Object Status -EQ 'OK').Count
    $summary = 'Result: {0} of {1} OK. Backup folder: {2}. Originals untouched.' -f $ok, $rows.Count, $dest
    Write-Host ''
    Write-Host ('  {0}' -f (& $show $summary)) -ForegroundColor (@{ $true = 'Green'; $false = 'Yellow' }[$ok -eq $rows.Count])
    Write-AfToolLog $toolLog $summary
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return $rows
}
