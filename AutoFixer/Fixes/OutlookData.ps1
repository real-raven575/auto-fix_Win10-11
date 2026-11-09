# Outlook data files (WORK-0033 step 1, raven575 yes 2026-11-09 19:07 UTC). Both tools are
# read-only and work in both modes. Based on TEAM 9to5's kit v5 (scripts 1 and 9), rebuilt
# in Auto-Fixer's shape:
#   - Inventory: every .ost/.pst for the Windows account running Auto-Fixer, its size, last
#     change, which Outlook profile points to it and whether it is open now. Changes nothing.
#   - Mail dates: oldest and newest mail and the mail count in each PST, read from TEMP COPIES
#     through classic Outlook. The originals are never opened. Outlook must be closed first,
#     because an administrator window cannot talk to an Outlook the user started.
#   - Classic Outlook only. New Outlook (olk.exe) has no profiles, OST or PST.
#   - Names are redacted on screen (unless Show sensitive is on) and always in the log.
#     No email address, account name or server name is ever printed.

# 9to5's warning point: a PST over 45 GB is near Outlook's 50 GB default limit.
$script:AfPstWarnBytes = 45GB

function Get-AfOutlookPathFromText {
    <#
    .SYNOPSIS
        Finds .ost and .pst paths inside a registry value's text: drive paths and network paths.
        Returns them lower-case and without duplicates.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] [AllowEmptyString()] [string] $Text)

    if (-not $Text) { return @() }
    $found = foreach ($m in [regex]::Matches($Text, '(?i)(?:[A-Z]:\\|\\\\)[^\x00<>|"*?\r\n]*?\.(?:ost|pst)\b')) { $m.Value.ToLowerInvariant() }
    return @($found | Sort-Object -Unique)
}

function ConvertTo-AfRegistryText {
    # Profile values are often binary Unicode text; other values are read as they are.
    param($Value)
    if ($Value -is [byte[]]) { return [Text.Encoding]::Unicode.GetString($Value) }
    return [string]$Value
}

function Get-AfOutlookProfileData {
    <#
    .SYNOPSIS
        Reads the Outlook profiles of the Windows account running Auto-Fixer (read-only):
        default profile per Office version, how many accounts of each kind each profile has,
        and which profiles point to each .ost/.pst path. Account names are never returned.
    #>
    [CmdletBinding()]
    param(
        # The Office key; tests point it at a test registry.
        [string] $OfficeKey = 'HKCU:\Software\Microsoft\Office',
        [string[]] $Version = @('16.0', '15.0')
    )

    $defaults = New-Object System.Collections.Generic.List[string]
    $accounts = [ordered]@{}
    $paths = @{}
    foreach ($ver in $Version) {
        $base = Join-Path $OfficeKey ('{0}\Outlook' -f $ver)
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $default = (Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue).DefaultProfile
        if ($default) { $defaults.Add(('{0} (Office {1})' -f $default, $ver)) }
        $profileRoot = Join-Path $base 'Profiles'
        if (-not (Test-Path -LiteralPath $profileRoot)) { continue }
        foreach ($p in @(Get-ChildItem -LiteralPath $profileRoot -ErrorAction SilentlyContinue)) {
            $name = $p.PSChildName
            foreach ($k in @(Get-ChildItem -LiteralPath $p.PSPath -Recurse -ErrorAction SilentlyContinue)) {
                $names = @($k.GetValueNames())
                $kind = $null
                if ($names -contains 'POP3 Server') { $kind = 'POP3 (mail lives only in a PST)' }
                elseif ($names -contains 'IMAP Server') { $kind = 'IMAP' }
                elseif ($names -contains 'Account Name') { $kind = 'Exchange, Microsoft 365 or other' }
                if ($kind) {
                    $key = '{0} : {1}' -f $name, $kind
                    if ($accounts.Contains($key)) { $accounts[$key]++ } else { $accounts[$key] = 1 }
                }
                foreach ($n in $names) {
                    foreach ($path in @(Get-AfOutlookPathFromText -Text (ConvertTo-AfRegistryText $k.GetValue($n)))) {
                        if (-not $paths.ContainsKey($path)) { $paths[$path] = New-Object System.Collections.Generic.List[string] }
                        if (-not $paths[$path].Contains($name)) { $paths[$path].Add($name) }
                    }
                }
            }
        }
    }
    return [pscustomobject]@{ Defaults = $defaults.ToArray(); Accounts = $accounts; Paths = $paths }
}

function Get-AfOutlookFileStatus {
    <#
    .SYNOPSIS
        ACTIVE: a profile points to it and it changed in the last 14 days.
        ATTACHED, idle: a profile points to it, no change for longer.
        NOT attached: no profile points to it (often an old copy).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([bool] $Attached, [int] $DaysOld)

    if ($Attached -and $DaysOld -le 14) { return 'ACTIVE' }
    if ($Attached) { return 'ATTACHED, idle' }
    return 'NOT attached'
}

function Test-AfFileInUse {
    # Opens the file for reading with no sharing and closes it at once. Changes nothing.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'None')
        $stream.Close()
        return $false
    }
    catch { return $true }
}

function Get-AfOutlookInventory {
    <#
    .SYNOPSIS
        Every .ost/.pst in the user's profile folder (hidden AppData included) plus any path a
        profile points to, with Status, Type, SizeBytes, LastWrite, DaysOld, Open, Profiles
        and Path. Read-only.
    #>
    [CmdletBinding()]
    param(
        [string] $UserProfile = $env:USERPROFILE,
        $ProfileData = (Get-AfOutlookProfileData),
        [datetime] $Now = (Get-Date),
        [scriptblock] $InUse = { param($Path) Test-AfFileInUse -Path $Path }
    )

    $files = @()
    if ($UserProfile -and (Test-Path -LiteralPath $UserProfile)) {
        $files = @(Get-ChildItem -LiteralPath $UserProfile -Recurse -Force -File -Include '*.ost', '*.pst' -ErrorAction SilentlyContinue)
    }
    foreach ($path in @($ProfileData.Paths.Keys)) {
        if (Test-Path -LiteralPath $path) { $files += Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    $files = @($files | Where-Object { $_ } | Sort-Object FullName -Unique)

    foreach ($f in $files) {
        $profiles = @()
        $key = $f.FullName.ToLowerInvariant()
        if ($ProfileData.Paths.ContainsKey($key)) { $profiles = @($ProfileData.Paths[$key]) }
        $days = [int][math]::Floor(($Now - $f.LastWriteTime).TotalDays)
        [pscustomobject]@{
            Status    = Get-AfOutlookFileStatus -Attached ($profiles.Count -gt 0) -DaysOld $days
            Type      = $f.Extension.TrimStart('.').ToUpperInvariant()
            SizeBytes = [long]$f.Length
            LastWrite = $f.LastWriteTime
            DaysOld   = $days
            Open      = [bool](& $InUse $f.FullName)
            Profiles  = $profiles
            Path      = $f.FullName
        }
    }
}

function Get-AfClassicOutlookState {
    # Read-only facts for the header: is classic Outlook installed and running, is New Outlook running.
    [CmdletBinding()]
    param()
    $appPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE'
    [pscustomobject]@{
        ClassicInstalled = [bool](Test-Path -LiteralPath $appPath)
        ClassicRunning   = [bool](Get-Process -Name 'outlook' -ErrorAction SilentlyContinue)
        NewRunning       = [bool](Get-Process -Name 'olk' -ErrorAction SilentlyContinue)
    }
}

function Invoke-AfOutlookInventory {
    <#
    .SYNOPSIS
        Shows the inventory on screen and writes the same lines to a redacted log.
        Returns the rows. Changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        $Redactor = (New-AfRedactor),
        [scriptblock] $GetState = { Get-AfClassicOutlookState },
        [scriptblock] $GetProfileData = { Get-AfOutlookProfileData },
        [scriptblock] $GetInventory = { param($ProfileData) Get-AfOutlookInventory -ProfileData $ProfileData }
    )

    $screenRedactor = $Redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'outlook' -Redactor $Redactor -Task 'Outlook data files inventory (read-only)'
    # Profile names are often a person's or company's name, so they are hidden like other names.
    $data = & $GetProfileData
    $profileNames = @($data.Paths.Values | ForEach-Object { $_ }) + @($data.Defaults | ForEach-Object { $_ -replace ' \(Office [\d.]+\)$', '' }) +
        @($data.Accounts.Keys | ForEach-Object { ($_ -split ' : ')[0] })
    # Windows' own profile names are not personal, and hiding them would also hide the word "Outlook" on screen.
    $profileNames = @($profileNames | Where-Object { $_ -notmatch '^(?i)(outlook|default outlook profile|mail|default|profile)$' })
    Add-AfRedactionName -Redactor $Redactor -Names $profileNames
    $say = {
        param([string] $Text, [string] $Color = 'Gray')
        Write-Host ('  {0}' -f (Protect-AfText -Redactor $screenRedactor -Text $Text)) -ForegroundColor $Color
        Write-AfToolLog $toolLog $Text
    }

    $state = & $GetState
    Write-Host ''
    & $say 'Outlook data files (read-only: nothing is changed)' 'White'
    & $say ('Windows account  : {0}' -f [Environment]::UserName)
    & $say ('Classic Outlook  : {0}' -f @{ $true = 'installed'; $false = 'not found' }[$state.ClassicInstalled])
    & $say ('Outlook running  : {0}' -f @{ $true = 'YES (close it for a clean "open now" check)'; $false = 'no' }[$state.ClassicRunning])
    if ($state.NewRunning) { & $say 'New Outlook      : running. New Outlook has no OST or PST files; these tools are for classic Outlook.' 'Yellow' }
    $defaultText = 'none found'
    if ($data.Defaults.Count) { $defaultText = $data.Defaults -join '; ' }
    & $say ('Default profile  : {0}' -f $defaultText)
    if ($data.Accounts.Count) {
        & $say 'Accounts by type :'
        foreach ($a in $data.Accounts.GetEnumerator()) { & $say ('  {0} x{1}' -f $a.Key, $a.Value) }
    }
    else { & $say 'Accounts by type : none found' }

    $rows = @(& $GetInventory $data)
    Write-Host ''
    if (-not $rows.Count) {
        & $say 'No .ost or .pst files were found for this Windows account.' 'Yellow'
    }
    else {
        & $say ('{0,-15}{1,-5}{2,10}  {3,-16} {4,-5} {5}' -f 'Status', 'Type', 'Size', 'Last changed', 'Open', 'Profile / path') 'White'
        foreach ($r in @($rows | Sort-Object Status, Type, LastWrite -Descending)) {
            $color = 'Gray'
            if ($r.Status -eq 'NOT attached') { $color = 'DarkYellow' }
            if ($r.SizeBytes -ge $script:AfPstWarnBytes) { $color = 'Yellow' }
            $profileText = '-'
            if ($r.Profiles.Count) { $profileText = $r.Profiles -join ', ' }
            & $say ('{0,-15}{1,-5}{2,10}  {3,-16} {4,-5} {5}' -f $r.Status, $r.Type, (Format-AfSize $r.SizeBytes), $r.LastWrite.ToString('yyyy-MM-dd HH:mm'), @{ $true = 'YES'; $false = 'no' }[$r.Open], $profileText) $color
            & $say ('{0}{1}' -f (' ' * 15), $r.Path) 'DarkGray'
        }
        $total = ($rows | Measure-Object SizeBytes -Sum).Sum
        Write-Host ''
        & $say ('Files: {0}   Total: {1}' -f $rows.Count, (Format-AfSize $total)) 'White'
        foreach ($big in @($rows | Where-Object { $_.SizeBytes -ge $script:AfPstWarnBytes })) {
            & $say ('Near the limit: a {0} is over 45 GB; Outlook''s default limit is 50 GB.' -f $big.Type) 'Yellow'
        }
    }
    & $say 'Result: OK. Nothing was changed.' 'Green'
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return $rows
}

function Test-AfTempSpace {
    # Temp copies may use at most 80% of the free space (9to5's rule), so Windows keeps room to work.
    [OutputType([bool])]
    param([long] $NeedBytes, [long] $FreeBytes)
    return ($NeedBytes -le (0.8 * $FreeBytes))
}

function Get-AfPstCandidate {
    # PSTs in Outlook's own folder and in Documents (Outlook Files lives there). Read-only.
    [CmdletBinding()]
    param([string[]] $Folder = @((Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'), [Environment]::GetFolderPath('MyDocuments')))
    $found = foreach ($f in @($Folder | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        Get-ChildItem -LiteralPath $f -Recurse -Force -File -Filter '*.pst' -ErrorAction SilentlyContinue
    }
    return @($found | Where-Object { $_ } | Sort-Object FullName -Unique)
}

function Read-AfPstStore {
    <#
    .SYNOPSIS
        Walks every mail folder in an Outlook store (COM) and returns Mail (count), Old and New
        (received dates). Dates outside 1990-4000 are Outlook's "no date" values and are skipped.
    #>
    param([Parameter(Mandatory)] $Store)

    $r = @{ Mail = 0; Old = $null; New = $null }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Store.GetRootFolder())
    while ($stack.Count) {
        $folder = $stack.Pop()
        foreach ($sub in $folder.Folders) { $stack.Push($sub) }
        # 0 = olMailItem: mail folders only, not calendar or contacts.
        if ($folder.DefaultItemType -ne 0 -or $folder.Items.Count -eq 0) { continue }
        $items = $folder.Items
        $r.Mail += $items.Count
        $items.Sort('[ReceivedTime]')
        foreach ($x in @($items.GetFirst(), $items.GetLast())) {
            try {
                $d = $x.ReceivedTime
                if ($d -and $d.Year -gt 1990 -and $d.Year -lt 4000) {
                    if (-not $r.Old -or $d -lt $r.Old) { $r.Old = $d }
                    if (-not $r.New -or $d -gt $r.New) { $r.New = $d }
                }
            }
            catch { Write-Verbose ('Item without a received date: {0}' -f $_.Exception.Message) }
        }
    }
    return $r
}

function Invoke-AfPstMailDates {
    <#
    .SYNOPSIS
        Copies each PST to a temp folder, opens the COPY in classic Outlook for a moment, reads
        the mail count and the oldest and newest mail, closes the copy and deletes the temp
        copies. Originals are never opened. Shows the plan and asks Y/N first. Returns the rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        $Redactor = (New-AfRedactor),
        [scriptblock] $GetState = { Get-AfClassicOutlookState },
        [scriptblock] $GetPst = { Get-AfPstCandidate },
        [string] $TempRoot = (Join-Path ([IO.Path]::GetTempPath()) 'AutoFixer-pst-dates'),
        [scriptblock] $GetFreeBytes = { param($Path) ([IO.DriveInfo]([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace },
        # Gets the list of temp copies (Source, Copy); returns one result per copy: Mail, Old, New, Note.
        [scriptblock] $ReadCopies = { param($Copies) Read-AfPstCopyWithOutlook -Copies $Copies }
    )

    $screenRedactor = $Redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $show = { param([string] $Text) Protect-AfText -Redactor $screenRedactor -Text $Text }

    $state = & $GetState
    if (-not $state.ClassicInstalled) {
        Write-Host '  Classic Outlook was not found. Mail dates needs classic Outlook to read a PST.' -ForegroundColor Yellow
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return @()
    }
    if ($state.ClassicRunning) {
        Write-Host '  Outlook is open. Please close Outlook, then run this again.' -ForegroundColor Yellow
        Write-Host '  (An administrator window cannot read from an Outlook you started yourself.)' -ForegroundColor DarkGray
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return @()
    }
    $psts = @(& $GetPst)
    if (-not $psts.Count) {
        Write-Host '  No PST files were found in Outlook''s folder or in Documents. Nothing was changed.' -ForegroundColor Yellow
        return @()
    }
    $need = [long](($psts | Measure-Object Length -Sum).Sum)
    $free = [long](& $GetFreeBytes $TempRoot)
    if (-not (Test-AfTempSpace -NeedBytes $need -FreeBytes $free)) {
        Write-Host ('  Not enough free space for the temp copies: {0} needed, {1} free. Nothing was changed.' -f (Format-AfSize $need), (Format-AfSize $free)) -ForegroundColor Red
        return @()
    }

    Write-Host ''
    Write-Host ('  This will read {0} PST file(s), {1} in all:' -f $psts.Count, (Format-AfSize $need)) -ForegroundColor White
    foreach ($p in $psts) { Write-Host ('    {0}' -f (& $show $p.FullName)) }
    Write-Host ''
    Write-Host '  1. Copy each one to a temp folder (your originals are never opened).' -ForegroundColor Gray
    Write-Host '  2. Start classic Outlook in the background and open each COPY for a moment.' -ForegroundColor Gray
    Write-Host '  3. Read the mail count and the oldest and newest mail, then close the copy.' -ForegroundColor Gray
    Write-Host '  4. Close Outlook and delete the temp copies.' -ForegroundColor Gray
    Write-Host '  Large files take a while to copy. Do not open Outlook until it finishes.' -ForegroundColor Yellow
    if ((Read-AfYesNo -Prompt 'Read the mail dates?' -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        return @()
    }

    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'outlook' -Redactor $Redactor -Task 'PST mail dates (read-only, temp copies)'
    $null = New-Item -ItemType Directory -Path $TempRoot -Force
    $copies = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($p in $psts) {
        $i++
        Write-Host ('  [{0} of {1}] copying {2}' -f $i, $psts.Count, (& $show $p.Name))
        $copy = Join-Path $TempRoot ('{0}-{1}' -f $i, $p.Name)
        try {
            Copy-Item -LiteralPath $p.FullName -Destination $copy -ErrorAction Stop
            $copies.Add([pscustomobject]@{ Source = $p; Copy = $copy; Note = '' })
        }
        catch { $copies.Add([pscustomobject]@{ Source = $p; Copy = $null; Note = 'in use by another program; skipped' }) }
    }

    $readable = @($copies | Where-Object Copy)
    $results = @{}
    if ($readable.Count) {
        try { foreach ($r in @(& $ReadCopies $readable)) { $results[$r.Copy] = $r } }
        catch {
            Write-Host ('  Outlook could not read the copies: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-AfToolLog $toolLog ('FAILED    Outlook: {0}' -f $_.Exception.Message)
        }
    }

    $rows = foreach ($c in $copies) {
        $r = $null
        if ($c.Copy -and $results.ContainsKey($c.Copy)) { $r = $results[$c.Copy] }
        $note = $c.Note
        if (-not $note) { if ($r) { $note = $r.Note } else { $note = 'not read' } }
        [pscustomobject]@{
            File      = $c.Source.Name
            SizeBytes = [long]$c.Source.Length
            Mail      = $(if ($r) { $r.Mail } else { '-' })
            Oldest    = $(if ($r -and $r.Old) { $r.Old.ToString('yyyy-MM-dd') } else { '-' })
            Newest    = $(if ($r -and $r.New) { $r.New.ToString('yyyy-MM-dd') } else { '-' })
            Note      = $note
        }
    }

    # A copy Outlook still holds is left for the user, never forced.
    $left = @()
    foreach ($c in @($copies | Where-Object Copy)) {
        try { Remove-Item -LiteralPath $c.Copy -Force -ErrorAction Stop }
        catch { $left += $c.Copy }
    }
    if (-not $left.Count) { Remove-Item -LiteralPath $TempRoot -Force -ErrorAction SilentlyContinue }

    Write-Host ''
    $line = '{0,-32}{1,10}{2,8}  {3,-11}{4,-11}{5}'
    Write-Host ('  ' + ($line -f 'File', 'Size', 'Mail', 'Oldest', 'Newest', 'Note')) -ForegroundColor White
    Write-AfToolLog $toolLog ($line -f 'File', 'Size', 'Mail', 'Oldest', 'Newest', 'Note')
    foreach ($r in @($rows | Sort-Object Oldest)) {
        $name = $r.File
        if ($name.Length -gt 30) { $name = $name.Substring(0, 27) + '...' }
        $text = $line -f $name, (Format-AfSize $r.SizeBytes), $r.Mail, $r.Oldest, $r.Newest, $r.Note
        $color = 'Gray'
        if ($r.Note -ne 'read from copy') { $color = 'Yellow' }
        Write-Host ('  {0}' -f (& $show $text)) -ForegroundColor $color
        Write-AfToolLog $toolLog $text
    }
    $okCount = @($rows | Where-Object Note -EQ 'read from copy').Count
    Write-Host ''
    $summary = 'Result: {0} of {1} read. Originals untouched.' -f $okCount, @($rows).Count
    if ($left.Count) { $summary += (' {0} temp copy(ies) still in use; delete {1} later.' -f $left.Count, $TempRoot) }
    else { $summary += ' Temp copies deleted.' }
    $color = 'Green'
    if ($okCount -lt @($rows).Count -or $left.Count) { $color = 'Yellow' }
    Write-Host ('  {0}' -f (& $show $summary)) -ForegroundColor $color
    Write-AfToolLog $toolLog $summary
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return @($rows)
}

function Read-AfPstCopyWithOutlook {
    <#
    .SYNOPSIS
        The only part that talks to Outlook (COM). Starts classic Outlook in the background with
        the default profile, adds each temp copy as a store, reads it, removes it again, then
        closes Outlook. Tested on a VM, not in CI.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Copies)

    $outlook = New-Object -ComObject Outlook.Application
    $ns = $null
    try {
        $ns = $outlook.GetNamespace('MAPI')
        # Default profile, no dialog.
        $ns.Logon('', '', $false, $false)
        foreach ($c in $Copies) {
            $store = $null
            $note = 'read from copy'
            $read = @{ Mail = '-'; Old = $null; New = $null }
            try {
                $ns.AddStore($c.Copy)
                $store = @($ns.Stores | Where-Object { $_.FilePath -eq $c.Copy })[0]
                if ($store) { $read = Read-AfPstStore -Store $store } else { $note = 'Outlook did not open the copy' }
            }
            catch { $note = 'Outlook could not open the copy (damaged or password protected?)' }
            if ($store) {
                try { $ns.RemoveStore($store.GetRootFolder()) }
                catch { $note = 'read, but the copy is still open in Outlook: right-click it > Close' }
            }
            [pscustomobject]@{ Copy = $c.Copy; Mail = $read.Mail; Old = $read.Old; New = $read.New; Note = $note }
        }
    }
    finally {
        try { $outlook.Quit() } catch { Write-Verbose ('Outlook quit: {0}' -f $_.Exception.Message) }
        if ($ns) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($ns) }
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($outlook)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        # Give Outlook a moment to let go of the copies before they are deleted.
        Start-Sleep -Seconds 3
    }
}

function Invoke-AfOutlookMenu {
    <#
    .SYNOPSIS
        Office and Outlook > Outlook data files. Both tools are read-only and in both modes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default action script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        # Each is called with the settings.
        [scriptblock] $Inventory = { param($S) $null = Invoke-AfOutlookInventory -Settings $S -OutputRoot $OutputRoot },
        [scriptblock] $MailDates = { param($S) $null = Invoke-AfPstMailDates -Settings $S -OutputRoot $OutputRoot -ReadKey $ReadKey }
    )

    $itemInfo = @{
        I = @('Lists every OST and PST for this Windows account: size, last change, which Outlook profile uses it and whether it is open.', '', 'Changes system: NO', 'Internet: never')
        D = @('Oldest and newest mail and the mail count in each PST. Reads temp copies through classic Outlook; your files are never opened.', '', 'Changes system: NO', 'Close Outlook first.', 'Asks Y/N first.')
        B = @('Back to the main menu.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $info = @('Outlook data files (OST and PST) for classic Outlook. Both tools only read.')
    $items = @(
        @{ Key = 'I'; Label = '&Inventory of OST and PST files' }
        @{ Key = 'D'; Label = 'Mail &dates in each PST'; Divider = $true }
        @{ Key = 'B'; Label = '&Back' }
        @{ Key = 'Q'; Label = '&Quit' }
    )
    while ($true) {
        $choice = Select-AfMenuItem -Title 'Office and Outlook' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -EscapeKey 'B' -ReadKey $ReadKey
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        try {
            if ($choice -eq 'I') { & $Inventory $Settings }
            else { & $MailDates $Settings }
        }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        if ($script:AfQuitRequested) { return }
        Write-Host ''
        Write-Host '  Press any key to return to Office and Outlook.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
