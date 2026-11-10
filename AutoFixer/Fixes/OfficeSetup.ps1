# Remove or install Office (WORK-0018 / FIXW-0024, TEAM 9to5's Office-Remove-Install-MENU, rewritten).
# Technician only. Classic Office (Click-to-Run, Microsoft 365 Apps, Visio, Project); Teams is always kept.
# Stock Windows steps: backup, Office's own uninstaller, add-in hooks, licence and cache folders, ISO
# install, licence status. ONLINE ADD-ONS (only with Settings > Online add-ons on, each asks Y/N):
# the Office Deployment Tool fallback, Microsoft's Get Help scrub, activation, and a download link.
# Product keys are read hidden and never shown, logged or saved.

$script:AfOfficeApps = @('winword', 'excel', 'outlook', 'powerpnt', 'onenote', 'msaccess', 'mspub', 'visio', 'winproj', 'lync', 'ms-teams', 'teams')
$script:AfOfficeAddinApps = @('Outlook', 'Word', 'Excel', 'PowerPoint', 'OneNote', 'Access', 'Publisher', 'Visio', 'MS Project')
$script:AfOdtPage = 'https://www.microsoft.com/en-us/download/details.aspx?id=49117'
$script:AfGetHelpUrl = 'https://aka.ms/SaRA_EnterpriseVersionFiles'
$script:AfOfficeUninstallKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')

# ---------- pure helpers (tested) ----------

function Split-AfUninstallCommand {
    # '"C:\...\OfficeClickToRun.exe" scenario=install ...' -> Exe + Arguments (with DisplayLevel=False). $null if not that shape.
    [CmdletBinding()]
    param([string] $Command)
    if ($Command -notmatch '^\s*"([^"]+)"\s*(.*)$') { return $null }
    return [pscustomobject]@{ Exe = $Matches[1]; Arguments = ($Matches[2].Trim() + ' DisplayLevel=False').Trim() }
}

function ConvertTo-AfProductKey {
    # Normalises typed key text to XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, or '' when it is not 25 letters/numbers.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Text)
    $k = ([string]$Text).Trim().ToUpperInvariant() -replace '[\s-]', ''
    if ($k -notmatch '^[A-Z0-9]{25}$') { return '' }
    return (($k -split '(.{5})' | Where-Object { $_ }) -join '-')
}

function Read-AfOsppStatus {
    # OSPP.VBS /dstatus text -> one row per installed key: Last5, Status, Error, Name. Never the full key.
    [CmdletBinding()]
    param([string] $Text)
    foreach ($b in ([string]$Text -split '-{20,}')) {
        if ($b -match 'LICENSE NAME:\s*(.+)') {
            $name = $Matches[1].Trim()
            $status = '?'; $last5 = '?'; $err = ''
            if ($b -match 'LICENSE STATUS:\s*(.+)') { $status = $Matches[1].Trim() }
            if ($b -match 'Last 5 characters of installed product key:\s*(\S+)') { $last5 = $Matches[1].Trim() }
            if ($b -match 'ERROR CODE:\s*(\S+)') { $err = $Matches[1].Trim() }
            [pscustomobject]@{ Last5 = $last5; Status = $status; Error = $err; Name = $name; Licensed = ($status -match '---LICENSED---') }
        }
    }
}

function Get-AfInstallerKind {
    # First bytes of a download: 'exe' (MZ), 'iso' (CD001/BEA01/NSR02 at byte 32769) or 'other'.
    [CmdletBinding()]
    [OutputType([string])]
    param([byte[]] $Bytes)
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x4D -and $Bytes[1] -eq 0x5A) { return 'exe' }
    if ($Bytes.Length -ge 32774 -and [Text.Encoding]::ASCII.GetString($Bytes, 32769, 5) -in 'CD001', 'BEA01', 'NSR02') { return 'iso' }
    return 'other'
}

function Get-AfOdtLink {
    # The Office Deployment Tool's real download link from Microsoft's download page (the old fwlink returns a page).
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Html)
    return ([regex]'https://download\.microsoft\.com/[^"]*officedeploymenttool[^"]*\.exe').Match([string]$Html).Value
}

function Get-AfGetHelpVerdict {
    # Get Help returns 0 even on bad arguments, so its text is checked. Returns '' when fine, else the issue.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Text, [int] $ExitCode)
    if ($Text -match 'Error:|Invalid command') { return 'Get Help scrub reported an error (see its log folder)' }
    if ($ExitCode -notin 0, 66, 68) { return ('Get Help scrub returned {0} (6 = apps open, 8/9 = failed, 10 = not admin)' -f $ExitCode) }
    return ''
}

# ---------- PC readers ----------

function Test-AfMsSigned {
    # $true only for a valid Microsoft Corporation signature.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Path)
    $s = Get-AuthenticodeSignature -FilePath $Path
    return ([bool]($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation'))
}

function Get-AfOfficeListed {
    # Office-family entries in the machine uninstall list (Teams excluded).
    [CmdletBinding()]
    param()
    return @(Get-ItemProperty -Path $script:AfOfficeUninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Microsoft (365|Office)|Visio|Project' -and $_.DisplayName -notmatch 'Teams' })
}

function Get-AfTeamsState {
    # New Teams (store app) and classic Teams. -AllUsers throws off-domain, so the install folder is the fallback.
    [CmdletBinding()]
    param()
    $new = $false
    try { $new = [bool](Get-AppxPackage -AllUsers -Name MSTeams -ErrorAction Stop) }
    catch { $new = [bool](Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Directory -Filter 'MSTeams_*' -ErrorAction SilentlyContinue) }
    $classic = [bool](Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users\*\AppData\Local\Microsoft\Teams\current\Teams.exe') -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ NewTeams = $new; ClassicTeams = $classic }
}

function Get-AfSignedInOfficeUser {
    # Users whose registry is loaded (signed in), with their profile folder.
    [CmdletBinding()]
    param()
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { $null = New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script }
    foreach ($k in @(Get-ChildItem -Path 'HKU:\' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
        $prof = (Get-ItemProperty -Path ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{0}' -f $k.PSChildName) -ErrorAction SilentlyContinue).ProfileImagePath
        if ($prof) { [pscustomobject]@{ Sid = $k.PSChildName; Profile = $prof } }
    }
}

function Get-AfOsppPath {
    [CmdletBinding()]
    param()
    return (@((Join-Path $env:ProgramFiles 'Microsoft Office\Office16\OSPP.VBS'), (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\Office16\OSPP.VBS')) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

function Invoke-AfOspp {
    # Runs OSPP.VBS with cscript.exe and returns its text. The key, if any, is masked before it is returned.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Ospp, [Parameter(Mandatory)] [string] $Argument, [string] $Key)
    $ErrorActionPreference = 'Continue'
    $text = (& cscript.exe //nologo $Ospp $Argument 2>&1 | Out-String)
    if ($Key) { $text = $text -replace [regex]::Escape($Key), '*****' }
    return $text
}

# ---------- removal ----------

function Invoke-AfOfficeRemove {
    <#
    .SYNOPSIS
        Test run (backup + list, no changes) or real removal of Click-to-Run Office, Teams kept.
        Returns 0 OK, 1 issues, 2 New Teams missing afterwards, 3 stopped before any change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Test', 'Remove')] [string] $Mode,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [bool] $AddonsOn = $false,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [string] $WorkRoot = (Join-Path $env:ProgramData 'AutoFixer\Office')
    )

    $dry = ($Mode -eq 'Test')
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path $WorkRoot ('backup-{0}' -f $stamp)
    $tools = Join-Path $WorkRoot 'tools'
    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'office' -Redactor $redactor -Task ('Office {0}' -f @{ $true = 'test run (no changes)'; $false = 'removal' }[$dry])
    $issues = New-Object System.Collections.ArrayList
    $say = {
        param([string] $Text, [string] $Color = 'Gray')
        Write-Host ('  {0}' -f (Protect-AfText -Redactor $redactor -Text $Text)) -ForegroundColor $Color
        Write-AfToolLog $toolLog $Text
    }
    $issue = { param([string] $Text) $null = $issues.Add($Text); & $say ('ISSUE  {0}' -f $Text) 'Yellow' }
    # One step: in a test run it is only listed; a failed step is an issue and the run goes on.
    $step = {
        param([string] $What, [scriptblock] $Do)
        if ($dry) { & $say ('Would: {0}' -f $What); return $true }
        & $say $What
        try { & $Do; return $true }
        catch { & $issue ('{0} FAILED: {1}' -f $What, $_.Exception.Message); return $false }
    }
    $native = { param([scriptblock] $Sb) $ErrorActionPreference = 'Continue'; & $Sb }

    & $say ('Mode: {0}' -f @{ $true = 'TEST RUN - nothing is changed'; $false = 'REMOVE OFFICE' }[$dry]) 'White'
    $users = @(Get-AfSignedInOfficeUser)
    & $say ('Signed-in users found: {0}' -f $users.Count)
    if (-not $users.Count) { & $issue 'No signed-in user: per-user clean-up is skipped. Have the user sign in, then run again.' }

    # Backup, also in a test run. No backup = stop before any change.
    $null = New-Item -ItemType Directory -Path $backup, $tools -Force
    & $native { reg.exe export 'HKLM\SOFTWARE\Microsoft\Office' (Join-Path $backup 'HKLM-Office.reg') /y 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) {
        & $say 'Stopped: the Office registry backup failed, so nothing was changed.' 'Red'
        return 3
    }
    & $native { reg.exe export 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Office' (Join-Path $backup 'HKLM-Office-x86.reg') /y 2>&1 | Out-Null }
    $n = 0
    foreach ($u in $users) {
        $n++
        & $native { reg.exe export ('HKU\{0}\Software\Microsoft\Office' -f $u.Sid) (Join-Path $backup ('User{0}-Office.reg' -f $n)) /y 2>&1 | Out-Null }
        foreach ($f in 'Templates', 'Signatures', 'UProof', 'AddIns', 'Office') {
            $src = Join-Path $u.Profile ('AppData\Roaming\Microsoft\{0}' -f $f)
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup ('User{0}-APPDATA-{1}' -f $n, $f)) -Recurse -Force }
        }
    }
    $teamsBefore = Get-AfTeamsState
    & $say ('Backup: {0} ({1} files)' -f $backup, @(Get-ChildItem -LiteralPath $backup -Recurse -File).Count) 'Green'

    $null = & $step 'Close Office apps and Teams (Teams is not removed)' { foreach ($p in $script:AfOfficeApps) { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force } }

    # Way 1: Office's own uninstaller (the one Windows Settings runs), made silent. No download.
    $c2r = @(Get-ItemProperty -Path $script:AfOfficeUninstallKeys[0] -ErrorAction SilentlyContinue |
            Where-Object { $_.UninstallString -match 'OfficeClickToRun\.exe' -and $_.DisplayName -notmatch 'Teams' })
    if (-not $c2r.Count) { & $say 'No Click-to-Run Office found.' }
    foreach ($prod in $c2r) {
        $cmd = Split-AfUninstallCommand -Command $prod.UninstallString
        $null = & $step ('Uninstall {0} (Office''s own uninstaller, silent)' -f $prod.DisplayName) {
            if (-not $cmd) { throw 'unexpected uninstall command' }
            if (-not (Test-AfMsSigned -Path $cmd.Exe)) { throw 'the uninstaller is not signed by Microsoft' }
            $p = Start-Process -FilePath $cmd.Exe -ArgumentList $cmd.Arguments -Wait -PassThru
            & $say ('Uninstaller exit code: {0}' -f $p.ExitCode)
            if ($p.ExitCode -ne 0) { & $issue ('Office uninstaller exit code {0}' -f $p.ExitCode) }
        }
    }

    # Way 2, only if Office is still listed: Office Deployment Tool, Remove All. Online add-on.
    if (-not $dry -and @(Get-AfOfficeListed | Where-Object { $_.UninstallString -match 'OfficeClickToRun' }).Count) {
        if (-not $AddonsOn) { & $issue 'Office is still listed. The Office Deployment Tool fallback is an online add-on: turn on Settings > Online add-ons and run again.' }
        elseif (Confirm-AfDownload -What 'download Microsoft''s Office Deployment Tool and run Remove All' -Where 'www.microsoft.com, download.microsoft.com' -ReadKey $ReadKey) {
            $null = & $step 'Office Deployment Tool: Remove All' {
                $url = Get-AfOdtLink -Html (Invoke-WebRequest -Uri $script:AfOdtPage -UseBasicParsing).Content
                if (-not $url) { throw 'the download link was not found on Microsoft''s page' }
                $odt = Join-Path $tools 'odt.exe'
                Invoke-WebRequest -Uri $url -OutFile $odt -UseBasicParsing
                if (-not (Test-AfMsSigned -Path $odt)) { throw 'the download is not signed by Microsoft' }
                Start-Process -FilePath $odt -ArgumentList ('/quiet /extract:"{0}"' -f (Join-Path $tools 'odt')) -Wait
                $setup = Join-Path $tools 'odt\setup.exe'
                if (-not (Test-AfMsSigned -Path $setup)) { throw 'setup.exe is not signed by Microsoft' }
                $xml = Join-Path $tools 'odt\remove-all.xml'
                '<Configuration><Remove All="TRUE" /><Display Level="None" AcceptEULA="TRUE" /></Configuration>' | Set-Content -LiteralPath $xml -Encoding ASCII
                $p = Start-Process -FilePath $setup -ArgumentList ('/configure "{0}"' -f $xml) -Wait -PassThru
                & $say ('Office Deployment Tool exit code: {0}' -f $p.ExitCode)
                if ($p.ExitCode -ne 0) { & $issue ('Office Deployment Tool exit code {0} (its logs: C:\Windows\Temp)' -f $p.ExitCode) }
            }
        }
    }

    # Get Help scrub (MSI Office and leftovers). Online add-on.
    if ($dry) { & $say ('Would: Microsoft Get Help scrub (online add-on: {0})' -f @{ $true = 'On'; $false = 'Off, would be skipped' }[$AddonsOn]) }
    elseif (-not $AddonsOn) { & $say 'Skipped: Microsoft Get Help scrub (an online add-on; Settings > Online add-ons is Off).' 'DarkGray' }
    elseif (Confirm-AfDownload -What 'download Microsoft''s Get Help tool and run its Office scrub' -Where 'aka.ms and the Microsoft server it forwards to' -ReadKey $ReadKey) {
        $null = & $step 'Microsoft Get Help scrub (MSI Office and leftovers)' {
            $zip = Join-Path $tools 'GetHelp.zip'
            Invoke-WebRequest -Uri $script:AfGetHelpUrl -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tools 'GetHelp') -Force
            $gh = Get-ChildItem -LiteralPath (Join-Path $tools 'GetHelp') -Recurse -Filter 'GetHelpCmd.exe' | Select-Object -First 1
            if (-not $gh) { throw 'GetHelpCmd was not in the download' }
            if (-not (Test-AfMsSigned -Path $gh.FullName)) { throw 'GetHelpCmd is not signed by Microsoft' }
            $ghLog = Join-Path $WorkRoot ('GetHelp-{0}' -f $stamp)
            $null = New-Item -ItemType Directory -Path $ghLog -Force
            $o = & $native { & $gh.FullName -S OfficeScrubScenario -AcceptEula -LogFolder $ghLog 2>&1 }
            $verdict = Get-AfGetHelpVerdict -Text ($o | Out-String) -ExitCode $LASTEXITCODE
            & $say ('Get Help log folder: {0}' -f $ghLog)
            if ($verdict) { & $issue $verdict }
        }
    }

    # Add-in hooks (machine and signed-in users), Teams kept. Third-party programs stay installed.
    $roots = @('HKLM:\Software\Microsoft\Office', 'HKLM:\Software\WOW6432Node\Microsoft\Office') + @($users | ForEach-Object { 'HKU:\{0}\Software\Microsoft\Office' -f $_.Sid })
    foreach ($r in $roots) {
        foreach ($a in $script:AfOfficeAddinApps) {
            foreach ($k in @(Get-ChildItem -Path ('{0}\{1}\Addins' -f $r, $a) -ErrorAction SilentlyContinue | Where-Object PSChildName -NotMatch 'Teams')) {
                $path = $k.PSPath
                $null = & $step ('Remove add-in hook {0} ({1})' -f $k.PSChildName, $a) { Remove-Item -Path $path -Recurse -Force }
            }
        }
    }

    # Per-user sign-in key; licence and cache folders are renamed, not deleted.
    foreach ($u in $users) {
        $id = 'HKU:\{0}\Software\Microsoft\Office\16.0\Common\Identity' -f $u.Sid
        if (Test-Path -Path $id) { $null = & $step 'Remove the Office sign-in (Identity) key (in the backup)' { Remove-Item -Path $id -Recurse -Force } }
        $la = Join-Path $u.Profile 'AppData\Local\Microsoft\Office'
        foreach ($d in @((Join-Path $la 'Licenses'), (Join-Path $la '16.0\Licensing'), (Join-Path $la '16.0\Wef'), (Join-Path $la '16.0\OfficeFileCache'), (Join-Path $la 'OTele'))) {
            if (Test-Path -LiteralPath $d) {
                $newName = '{0}.AutoFixer-old-{1}' -f (Split-Path $d -Leaf), $stamp
                $null = & $step ('Rename {0} to {1}' -f (Split-Path $d -Leaf), $newName) { Rename-Item -LiteralPath $d -NewName $newName }
            }
        }
    }

    $left = @(Get-AfOfficeListed)
    $teamsAfter = Get-AfTeamsState
    & $say ('Teams before: New={0} Classic={1}   after: New={2} Classic={3}' -f $teamsBefore.NewTeams, $teamsBefore.ClassicTeams, $teamsAfter.NewTeams, $teamsAfter.ClassicTeams)
    $teamsLost = $false
    if ($dry) { & $say ('Office products found: {0}' -f $left.Count); foreach ($l in $left) { & $say ('  {0}' -f $l.DisplayName) } }
    else {
        if ($left.Count) { & $issue ('Office still listed: {0}' -f (($left.DisplayName | Select-Object -Unique) -join '; ')) }
        if ($teamsBefore.NewTeams -and -not $teamsAfter.NewTeams) { $teamsLost = $true; & $issue 'New Teams is MISSING after removal. Reinstall it with Microsoft''s Teams bootstrapper.' }
    }

    Write-Host ''
    if ($dry) {
        $head = @{ $true = 'Result: TEST RUN OK. Nothing was changed.'; $false = ('Result: TEST RUN found {0} issue(s). Nothing was changed.' -f $issues.Count) }[$issues.Count -eq 0]
    }
    else {
        $head = @{ $true = 'Result: Office removed, Teams kept. Restart the PC before installing.'; $false = ('Result: finished with {0} issue(s). Read them before restarting.' -f $issues.Count) }[$issues.Count -eq 0]
    }
    & $say $head (@{ $true = 'Green'; $false = 'Yellow' }[$issues.Count -eq 0])
    & $say ('Backup: {0}' -f $backup) 'DarkGray'
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    if ($teamsLost) { return 2 }
    if ($issues.Count) { return 1 }
    return 0
}

# ---------- install ----------

function Get-AfOfficeIsoFolder {
    # Where ISOs usually are: every user's Downloads, Documents, Desktop (and OneDrive), plus common shared folders.
    [CmdletBinding()]
    param([string] $UsersRoot = (Join-Path $env:SystemDrive 'Users'))
    $list = foreach ($u in @(Get-ChildItem -LiteralPath $UsersRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -NotIn 'Public', 'Default', 'Default User', 'All Users')) {
        foreach ($sub in 'Downloads', 'Documents', 'Desktop', 'OneDrive\Documents', 'OneDrive\Desktop') { Join-Path $u.FullName $sub }
    }
    $list = @($list) + @((Join-Path $env:SystemDrive 'temp'), (Join-Path $UsersRoot 'Public\Downloads'), (Join-Path $UsersRoot 'Public\Documents'), (Join-Path $env:SystemDrive 'Install'), (Join-Path $env:SystemDrive 'Software'))
    return @($list | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

function Get-AfOfficeDrive {
    # A drive with an Office setup.exe at its root, or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Letter)
    $root = '{0}:\' -f $Letter
    $setup = Join-Path $root 'setup.exe'
    if (-not (Test-Path -LiteralPath $setup -ErrorAction SilentlyContinue)) { return $null }
    $builds = @(Get-ChildItem -LiteralPath (Join-Path $root 'Office\Data') -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^\d+\.\d+\.\d+\.\d+$').Name -join ', '
    return [pscustomobject]@{ Letter = $Letter; Setup = $setup; Builds = $builds; Signed = (Test-AfMsSigned -Path $setup); MountedIso = $null }
}

function Mount-AfOfficeIso {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
    $mounted = $null
    if (-not $img.Attached) {
        Mount-DiskImage -ImagePath $Path -StorageType ISO -ErrorAction Stop | Out-Null
        $mounted = $Path
        Start-Sleep -Seconds 2
    }
    $letter = @((Get-DiskImage -ImagePath $Path | Get-Volume).DriveLetter | Where-Object { $_ })[0]
    if (-not $letter) { throw 'Windows gave the ISO no drive letter' }
    $d = Get-AfOfficeDrive -Letter $letter
    if (-not $d) { throw ('{0}: has no setup.exe, so it is not an Office installer' -f $letter) }
    $d.MountedIso = $mounted
    return $d
}

function Select-AfOfficeSource {
    # Picks an Office installer: a mounted disc, or an ISO from the usual folders or a typed path. Returns a drive or $null.
    [CmdletBinding()]
    param([scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) })

    $drives = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { Get-AfOfficeDrive -Letter $_.Name } | Where-Object { $_ })
    $isos = @(foreach ($f in (Get-AfOfficeIsoFolder)) { Get-ChildItem -LiteralPath $f -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.iso', '.img' } })
    $isos = @($isos | Sort-Object FullName -Unique)
    $choices = @($drives | ForEach-Object { [pscustomobject]@{ Text = ('Mounted {0}:  build {1}  signed={2}' -f $_.Letter, $_.Builds, $_.Signed); Drive = $_; Iso = $null } }) +
        @($isos | ForEach-Object { [pscustomobject]@{ Text = ('{0}  ({1:N0} MB, {2:yyyy-MM-dd})' -f $_.FullName, ($_.Length / 1MB), $_.LastWriteTime); Drive = $null; Iso = $_.FullName } })
    Write-Host ''
    if ($choices.Count) {
        Write-Host '  Office installers found:' -ForegroundColor White
        for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host ('    {0}. {1}' -f ($i + 1), $choices[$i].Text) }
    }
    else { Write-Host '  No mounted Office disc or .iso was found in the usual folders.' -ForegroundColor Yellow }
    $ans = ([string](& $ReadText 'Number, or a full .iso path (Enter = back)')).Trim().Trim('"')
    if (-not $ans) { return $null }
    if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $choices.Count) {
        $c = $choices[[int]$ans - 1]
        if ($c.Drive) { return $c.Drive }
        $ans = $c.Iso
    }
    if (-not (Test-Path -LiteralPath $ans -PathType Leaf) -or $ans -notmatch '\.(iso|img)$') { Write-Host '  That is not an .iso or .img file.' -ForegroundColor Yellow; return $null }
    try { return (Mount-AfOfficeIso -Path $ans) }
    catch { Write-Host ('  Could not use it: {0}' -f $_.Exception.Message) -ForegroundColor Red; return $null }
}

function Read-AfProductKeyHidden {
    # Up to 3 tries; returns a normalised key or ''. The key is never shown, only its last 5 characters.
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock] $ReadSecret = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) -AsSecureString })
    for ($try = 1; $try -le 3; $try++) {
        $sec = & $ReadSecret 'Product key (typing is hidden; Enter = skip)'
        if (-not $sec -or $sec.Length -eq 0) { return '' }
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $k = ConvertTo-AfProductKey -Text ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
        if ($k) { Write-Host ('  Key format OK (ends in {0}).' -f $k.Substring(24)); return $k }
        Write-Host ('  That is not 25 letters and numbers in 5 groups. Try again ({0} of 3).' -f $try) -ForegroundColor Yellow
    }
    return ''
}

function Invoke-AfOfficeActivate {
    # Online add-on: enters a key (if given) and activates with Microsoft. Returns $true when a key shows LICENSED.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Ospp, [string] $Key, [scriptblock] $ReadKey = { Read-AfMenuKey })
    if (-not (Confirm-AfDownload -What 'activate Office with Microsoft' -Where 'Microsoft''s Office activation servers' -ReadKey $ReadKey)) { return $false }
    if ($Key) { $null = Invoke-AfOspp -Ospp $Ospp -Argument ('/inpkey:{0}' -f $Key) -Key $Key }
    $out = Invoke-AfOspp -Ospp $Ospp -Argument '/act' -Key $Key
    $rows = @(Read-AfOsppStatus -Text (Invoke-AfOspp -Ospp $Ospp -Argument '/dstatus'))
    Show-AfOfficeLicense -Rows $rows
    $ok = @($rows | Where-Object { $_.Licensed -and (-not $Key -or $_.Last5 -eq $Key.Substring(24)) }).Count -gt 0
    if (-not $ok -and $out -match '0x[0-9A-Fa-f]{8}') {
        Write-Host ('  Error {0}. Common: 0xC004C008 key used too often, 0xC004C003 key blocked, 0xC004F050 invalid key, 0xC004F074 no activation server or internet.' -f $Matches[0]) -ForegroundColor Yellow
    }
    return $ok
}

function Show-AfOfficeLicense {
    [CmdletBinding()]
    param([object[]] $Rows)
    if (-not $Rows.Count) { Write-Host '  No Office product keys are installed.'; return }
    foreach ($r in $Rows) {
        Write-Host ('  key ...{0}  {1}  {2}  {3}' -f $r.Last5, $r.Status, $r.Error, $r.Name) -ForegroundColor (@{ $true = 'Green'; $false = 'Yellow' }[[bool]$r.Licensed])
    }
}

function Install-AfOffice {
    <#
    .SYNOPSIS
        Installs Office from a picked disc or ISO whose setup.exe Microsoft signed, after a Y/N. With the
        online add-ons on, it then offers a hidden product key and activation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [bool] $AddonsOn = $false,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadSecret = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) -AsSecureString }
    )

    if (-not $Source.Signed) { Write-Host '  Stopped: that setup.exe is not signed by Microsoft. Nothing was installed.' -ForegroundColor Red; return }
    if (-not (Test-Path -LiteralPath $Source.Setup)) { Write-Host '  Stopped: the installer is gone (ISO unmounted?). Pick it again.' -ForegroundColor Red; return }
    $now = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($now) { Write-Host ('  Office is still installed ({0}). Remove it and restart first.' -f $now.ProductReleaseIds) -ForegroundColor Yellow }
    Write-Host ('  Installer: {0}  build {1}  Microsoft-signed' -f $Source.Setup, $Source.Builds)
    Write-Host '  Setup takes 10-30 minutes.' -ForegroundColor DarkGray
    if ((Read-AfYesNo -Prompt 'Install Office now?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was installed.' -ForegroundColor Yellow; return }

    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'office' -Redactor $redactor -Task 'Office install'
    $p = Start-Process -FilePath $Source.Setup -WorkingDirectory (Split-Path $Source.Setup) -Wait -PassThru
    $after = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    $lines = @(('setup.exe exit code: {0} (0 = OK)' -f $p.ExitCode))
    if ($after) { $lines += ('OK      installed {0} version {1}' -f $after.ProductReleaseIds, $after.VersionToReport) }
    else { $lines += 'ISSUE   Office is not showing as installed. See C:\Windows\Temp\*.log (Click-to-Run logs).' }
    foreach ($l in $lines) { Write-Host ('  {0}' -f $l) -ForegroundColor (@{ $true = 'Yellow'; $false = 'Gray' }[$l.StartsWith('ISSUE')]); Write-AfToolLog $toolLog $l }
    if ($after) {
        if (-not $AddonsOn) { Write-Host '  Activation is an online add-on (Settings > Online add-ons). Otherwise Office asks for its key when the user opens an app.' -ForegroundColor DarkGray }
        else {
            $ospp = Get-AfOsppPath
            $key = Read-AfProductKeyHidden -ReadSecret $ReadSecret
            if ($ospp -and $key) {
                $ok = Invoke-AfOfficeActivate -Ospp $ospp -Key $key -ReadKey $ReadKey
                $msg = @{ $true = 'OK      Office is activated.'; $false = 'ISSUE   installed but not activated. Use Licence and activation to try again.' }[$ok]
                Write-Host ('  {0}' -f $msg) -ForegroundColor (@{ $true = 'Green'; $false = 'Yellow' }[$ok]); Write-AfToolLog $toolLog $msg
            }
            $key = $null
        }
    }
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
}

function Get-AfOfficeFromLink {
    <#
    .SYNOPSIS
        Online add-on: downloads an Office installer from an https link the technician types, announced
        first. A setup .exe must be signed by Microsoft; an ISO is mounted and its setup.exe checked.
    #>
    [CmdletBinding()]
    param(
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [string] $Folder = (Join-Path $env:ProgramData 'AutoFixer\Office\downloads')
    )
    $u = ([string](& $ReadText 'Paste the https:// download link (Enter = back)')).Trim().Trim('"')
    if (-not $u) { return $null }
    if ($u -notmatch '^https://[^\s/]+') { Write-Host '  The link must start with https://. Nothing was downloaded.' -ForegroundColor Yellow; return $null }
    $uri = [Uri]$u
    if (-not (Confirm-AfDownload -What 'download this installer (a full Office ISO is 3-5 GB)' -Where $uri.Host -ReadKey $ReadKey)) { return $null }
    $null = New-Item -ItemType Directory -Path $Folder -Force
    $name = ([IO.Path]::GetFileName($uri.AbsolutePath) -replace '[^\w\.\-]', '_')
    if (-not $name) { $name = 'download.bin' }
    $out = Join-Path $Folder $name
    try {
        $ProgressPreference = 'SilentlyContinue'
        if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
        Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing -ErrorAction Stop
    }
    catch { Write-Host ('  Download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red; return $null }
    $buf = New-Object byte[] 32774
    $fs = [IO.File]::OpenRead($out)
    try { $read = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Close() }
    $kind = Get-AfInstallerKind -Bytes ($buf[0..([Math]::Max(0, $read - 1))])
    Write-Host ('  Downloaded {0:N0} MB, SHA256 {1}' -f ((Get-Item -LiteralPath $out).Length / 1MB), (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash)
    if ($kind -eq 'iso') {
        if ($out -notmatch '\.(iso|img)$') { Move-Item -LiteralPath $out -Destination "$out.iso" -Force; $out = "$out.iso" }
        try { return (Mount-AfOfficeIso -Path $out) }
        catch { Write-Host ('  Could not use it: {0}' -f $_.Exception.Message) -ForegroundColor Red; return $null }
    }
    if ($kind -eq 'exe') {
        if ($out -notmatch '\.exe$') { Move-Item -LiteralPath $out -Destination "$out.exe" -Force; $out = "$out.exe" }
        if (-not (Test-AfMsSigned -Path $out)) { Write-Host '  Stopped: not signed by Microsoft, so it will not be used.' -ForegroundColor Red; return $null }
        return [pscustomobject]@{ Letter = $null; Setup = $out; Builds = 'latest from Microsoft (online setup)'; Signed = $true; MountedIso = $null }
    }
    Write-Host '  That is neither an ISO nor a setup program (often the link opened a web page). Use the direct file link.' -ForegroundColor Yellow
    return $null
}

function Invoke-AfOfficeLicense {
    # Licence status (stock Windows); re-activate or a new key are online add-ons.
    [CmdletBinding()]
    param([bool] $AddonsOn = $false, [scriptblock] $ReadKey = { Read-AfMenuKey }, [scriptblock] $ReadSecret = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) -AsSecureString })
    $ospp = Get-AfOsppPath
    if (-not $ospp) { Write-Host '  Office (OSPP.VBS) was not found. Install Office first.' -ForegroundColor Yellow; return }
    $rows = @(Read-AfOsppStatus -Text (Invoke-AfOspp -Ospp $ospp -Argument '/dstatus'))
    Show-AfOfficeLicense -Rows $rows
    if (-not $AddonsOn) { Write-Host '  Activating or changing the key is an online add-on (Settings > Online add-ons).' -ForegroundColor DarkGray; return }
    Write-Host '  R = activate again with the installed key   N = enter a new key   other key = back'
    $pick = [string](& $ReadKey)
    if ($pick -eq 'R') { $null = Invoke-AfOfficeActivate -Ospp $ospp -ReadKey $ReadKey; return }
    if ($pick -ne 'N') { return }
    $key = Read-AfProductKeyHidden -ReadSecret $ReadSecret
    if (-not $key) { return }
    if (Invoke-AfOfficeActivate -Ospp $ospp -Key $key -ReadKey $ReadKey) {
        foreach ($r in @($rows | Where-Object { $_.Last5 -ne $key.Substring(24) -and $_.Last5 -ne '?' })) {
            if ((Read-AfYesNo -Prompt ('Remove the old key ending {0}?' -f $r.Last5) -ReadKey $ReadKey) -eq $true) { $null = Invoke-AfOspp -Ospp $ospp -Argument ('/unpkey:{0}' -f $r.Last5) }
        }
    }
    elseif ((Read-AfYesNo -Prompt ('Remove the failed key ending {0}?' -f $key.Substring(24)) -ReadKey $ReadKey) -eq $true) {
        $null = Invoke-AfOspp -Ospp $ospp -Argument ('/unpkey:{0}' -f $key.Substring(24))
    }
    $key = $null
}

# ---------- menu ----------

function Invoke-AfOfficeSetupMenu {
    <#
    .SYNOPSIS
        Office and Outlook > Remove or install Office (Technician). D and activation are online add-ons.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default action script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $OpenSettings,
        # Each is called with the settings (and the picked source for Install).
        [scriptblock] $TestRun = { param($S) $null = Invoke-AfOfficeRemove -Mode Test -OutputRoot $OutputRoot -AddonsOn (Test-AfOnlineAddonsOn -Settings $S) -ReadKey $ReadKey },
        [scriptblock] $Remove = { param($S) $null = Invoke-AfOfficeRemove -Mode Remove -OutputRoot $OutputRoot -AddonsOn (Test-AfOnlineAddonsOn -Settings $S) -ReadKey $ReadKey },
        [scriptblock] $PickSource = { Select-AfOfficeSource },
        [scriptblock] $Download = { Get-AfOfficeFromLink -ReadKey $ReadKey },
        [scriptblock] $Install = { param($S, $Src) Install-AfOffice -Source $Src -OutputRoot $OutputRoot -AddonsOn (Test-AfOnlineAddonsOn -Settings $S) -ReadKey $ReadKey },
        [scriptblock] $License = { param($S) Invoke-AfOfficeLicense -AddonsOn (Test-AfOnlineAddonsOn -Settings $S) -ReadKey $ReadKey }
    )

    $itemInfo = @{
        T = @('Backs up the Office registry and the users'' Office settings, then lists what removal would do.', '', 'Changes system: NO (writes the backup)', 'Internet: never')
        R = @('Uninstalls Click-to-Run Office (Microsoft 365, Visio, Project) with Office''s own uninstaller. Teams is kept.', '', 'Changes system: YES', 'Backup first. Asks twice.', 'ODT fallback and Get Help scrub: online add-ons.')
        S = @('Picks the installer: a mounted Office disc, or an ISO from Downloads, Documents, Desktop, C:\temp or a typed path.', '', 'Mounts the ISO. Internet: never')
        D = @('Downloads an Office ISO or setup program from an https link you type. A setup program must be signed by Microsoft.', '', 'Online add-on.')
        I = @('Installs Office from the picked source, after Y/N. setup.exe must be signed by Microsoft.', '', 'Changes system: YES', 'Product key and activation: online add-on.')
        U = @('Unmounts the ISO this menu mounted.')
        L = @('Shows the installed Office keys (last 5 characters) and their licence status.', '', 'Activate again or a new key: online add-on.')
        B = @('Back to Office and Outlook.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $source = $null
    $notice = $null
    while ($true) {
        $srcText = 'none picked'
        if ($source) { $srcText = $source.Setup }
        $info = @('Removes or installs classic Office. Teams is always kept.', ('Installer: {0}' -f $srcText),
            ('Online add-ons: {0} (Settings > Online add-ons).' -f @{ $true = 'On'; $false = 'Off' }[(Test-AfOnlineAddonsOn -Settings $Settings)]))
        $items = @(
            @{ Key = 'T'; Label = '&Test run (no changes)' }
            @{ Key = 'R'; Label = '&Remove Office'; Tags = '[CHG]'; Divider = $true }
            @{ Key = 'S'; Label = 'Pick the installer (&source)' }
            @{ Key = 'D'; Label = '&Download an installer'; Tags = '[ADD-ON]' }
            @{ Key = 'I'; Label = '&Install Office'; Tags = '[CHG]' }
            @{ Key = 'U'; Label = '&Unmount the ISO'; Divider = $true }
            @{ Key = 'L'; Label = '&Licence and activation' }
            @{ Key = 'B'; Label = '&Back' }
            @{ Key = 'Q'; Label = '&Quit' }
        )
        $choice = Select-AfMenuItem -Title 'Remove or install Office' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        # A notice is shown on the menu itself, so no "Press any key" after it.
        try {
            switch ($choice) {
                'T' { & $TestRun $Settings }
                'R' {
                    Write-Host ''
                    Write-Host '  This UNINSTALLS every Office app on this PC (Microsoft 365, Visio, Project). Teams is kept.' -ForegroundColor Red
                    Write-Host '  A backup is made first. Undoing it means installing Office again.' -ForegroundColor Red
                    if ((Read-AfYesNo -Prompt 'Remove Office?' -ReadKey $ReadKey) -eq $true -and (Read-AfYesNo -Prompt 'Are you sure?' -ReadKey $ReadKey) -eq $true) { & $Remove $Settings }
                    else { Write-Host '  Nothing was changed.' -ForegroundColor Yellow }
                }
                'S' { $r = & $PickSource; if ($r) { $source = $r } }
                'D' {
                    if ((Test-AfOnlineAddonsOn -Settings $Settings) -or (Show-AfAddonOffNote -Settings $Settings -Needs 'a download' -OpenSettings $OpenSettings -ReadKey $ReadKey)) {
                        $r = & $Download; if ($r) { $source = $r }
                    }
                }
                'I' {
                    if (-not $source) { $notice = 'Pick the installer first (S).' }
                    else { & $Install $Settings $source }
                }
                'U' {
                    if ($source -and $source.MountedIso) {
                        Dismount-DiskImage -ImagePath $source.MountedIso | Out-Null
                        Write-Host '  Unmounted.' -ForegroundColor Green
                        $source = $null
                    }
                    else { $notice = 'This menu has not mounted an ISO.' }
                }
                'L' { & $License $Settings }
            }
        }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        if ($script:AfQuitRequested) { return }
        if ($notice) { continue }
        Write-Host ''
        Write-Host '  Press any key to return to Remove or install Office.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
