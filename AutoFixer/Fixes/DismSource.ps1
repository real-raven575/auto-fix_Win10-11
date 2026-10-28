# DISM version and repair-source check. Read-only and offline: it reads the Windows
# build, the DISM that Auto-Fixer runs, the repair-source policy, WSUS and the last
# error DISM wrote to its own log, then says which cause fits and what to do next.
# Most "DISM version mismatch" failures are really a repair SOURCE that is older than
# the PC (an ISO without the monthly updates) or one that a policy blocks. Windows
# Update always has files for this exact build. See
# learn.microsoft.com/windows-hardware/manufacture/desktop/configure-a-windows-repair-source

# Cause groups decide the next step; the text is what the screen and log say.
$script:AfDismCodes = [ordered]@{
    '0x800F081F' = @{ Cause = 'source'; Text = 'The clean files DISM needs were not in the repair source.' }
    '0x800F0915' = @{ Cause = 'nowhere'; Text = 'The repair content could not be found anywhere, not even on Windows Update.' }
    '0x800F0906' = @{ Cause = 'download'; Text = 'DISM could not download the clean files.' }
    '0x800F0954' = @{ Cause = 'blocked'; Text = 'The repair source is blocked, often by WSUS or Group Policy.' }
    '0x800F0922' = @{ Cause = 'pending'; Text = 'Windows could not finish servicing. Usual causes: a pending restart, a full System Reserved partition, or a VPN blocking updates.' }
    '0x800F082F' = @{ Cause = 'pending'; Text = 'Changes are waiting for a restart.' }
    '0x800F0831' = @{ Cause = 'store'; Text = 'An update package that the component store needs is missing.' }
}

# Builds that are an enablement package or a preview on top of another keep that base
# build's dism.exe (25H2 26200 and 26H2/Insider 26300 run DISM 10.0.26100.x), so a
# different file build is normal there and not a mismatch.
$script:AfDismBaseBuild = @{
    19042 = 19041; 19043 = 19041; 19044 = 19041; 19045 = 19041
    22631 = 22621; 22635 = 22621
    26120 = 26100; 26200 = 26100; 26220 = 26100; 26300 = 26100
}

function Get-AfDismBaseBuild {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [int] $Build)
    if ($script:AfDismBaseBuild.ContainsKey($Build)) { return [int]$script:AfDismBaseBuild[$Build] }
    return $Build
}

function Get-AfWindowsRoot {
    $windows = $env:windir
    if (-not $windows) { $windows = 'C:\Windows' }
    return $windows.TrimEnd('\')
}

function Get-AfOsBuild {
    # Windows 11 still says "Windows 10" in ProductName, so the build decides the name.
    [CmdletBinding()]
    param([scriptblock] $ReadRegistry = { param($Path) Get-ItemProperty -LiteralPath $Path -ErrorAction Stop })

    try { $cv = & $ReadRegistry 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
    catch { return $null }
    $build = 0
    if (-not [int]::TryParse([string]$cv.CurrentBuild, [ref] $build)) { return $null }
    $name = 'Windows 10'
    if ($build -ge 22000) { $name = 'Windows 11' }
    $release = [string]$cv.DisplayVersion
    if (-not $release) { $release = [string]$cv.ReleaseId }
    # Windows Insider PCs name their channel here; other PCs have no such key.
    $insider = ''
    try { $insider = [string](& $ReadRegistry 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability').BranchName } catch { Write-Verbose 'Not a Windows Insider PC.' }
    $text = '{0} {1}, build {2}.{3}, {4}' -f $name, $release, $build, [int]$cv.UBR, $cv.EditionID
    if ($insider) { $text += ', Windows Insider ({0})' -f $insider }
    [pscustomobject]@{
        Name    = $name
        Release = $release
        Build   = $build
        Ubr     = [int]$cv.UBR
        Edition = [string]$cv.EditionID
        Insider = $insider
        Text    = $text
    }
}

function Get-AfDismBuild {
    # The same path the repair steps run (System32, or Sysnative from a 32-bit PowerShell).
    [CmdletBinding()]
    param(
        [string] $Path = (Get-AfSystemToolPath 'dism.exe'),
        [scriptblock] $GetVersion = { param($Path) [Diagnostics.FileVersionInfo]::GetVersionInfo($Path) }
    )

    try {
        $v = & $GetVersion $Path
        [pscustomobject]@{ Path = $Path; Build = [int]$v.FileBuildPart; Text = ('{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart) }
    }
    catch { [pscustomobject]@{ Path = $Path; Build = $null; Text = 'not found' } }
}

function Get-AfRepairSourcePolicy {
    # Group Policy "Specify settings for optional component installation and component repair"
    # writes the Servicing key; UseWUServer = 1 means a WSUS server gives this PC its updates.
    [CmdletBinding()]
    param([scriptblock] $ReadRegistry = { param($Path) Get-ItemProperty -LiteralPath $Path -ErrorAction Stop })

    $servicing = $null
    $au = $null
    try { $servicing = & $ReadRegistry 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' } catch { Write-Verbose 'No repair-source policy.' }
    try { $au = & $ReadRegistry 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' } catch { Write-Verbose 'No Windows Update policy.' }
    [pscustomobject]@{
        # Only whether a path is set: a network path can name a company server.
        LocalSource         = [bool]($servicing -and [string]$servicing.LocalSourcePath)
        NeverWindowsUpdate  = [bool]($servicing -and [int]$servicing.UseWindowsUpdate -eq 2)
        DirectWindowsUpdate = [bool]($servicing -and [int]$servicing.RepairContentServerSource -eq 2)
        Wsus                = [bool]($au -and [int]$au.UseWUServer -eq 1)
    }
}

function Get-AfDismLogLastError {
    # Reads only; dism.log is a log the tool reads, so it is never moved or cleared.
    [CmdletBinding()]
    param(
        [string] $Path = (Join-Path (Get-AfWindowsRoot) 'Logs\DISM\dism.log'),
        [int] $Tail = 4000
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $lines = @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop) }
    catch { return $null }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($lines[$i], '0x800f0[0-9a-f]{3}', 'IgnoreCase')
        if ($m.Success) {
            $when = ''
            if ($lines[$i] -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') { $when = $Matches[1] }
            return [pscustomobject]@{ Code = $m.Value.ToUpper().Replace('0X', '0x'); When = $when }
        }
    }
    return $null
}

function Get-AfDismSourceVerdict {
    <#
    .SYNOPSIS
        Turns what the check read into findings: Level (OK, NOTE or WARN), Text and Next.
        Pure logic, so every cause can be tested without Windows.
    #>
    [CmdletBinding()]
    param(
        $Os,
        $Dism,
        $Policy,
        # Such as 0x800F081F: from the step that just failed, or the last one in dism.log.
        [string] $LastCode,
        [bool] $Online
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $add = { param($Level, $Text, $Next) $findings.Add([pscustomobject]@{ Level = $Level; Text = $Text; Next = $Next }) }

    if (-not $Dism -or $null -eq $Dism.Build) {
        & $add 'WARN' 'dism.exe was not found where Windows keeps it.' 'Run S (SFC). If DISM is still missing, an in-place repair install of Windows is the fix.'
    }
    elseif ($Os -and (Get-AfDismBaseBuild $Dism.Build) -ne (Get-AfDismBaseBuild $Os.Build)) {
        & $add 'WARN' ('DISM is build {0} but Windows is build {1}.' -f $Dism.Build, $Os.Build) 'Install the waiting Windows updates and restart, then check again. If they still differ, an in-place repair install fixes it.'
    }
    elseif ($Os) { & $add 'OK' ('DISM {0} is the right one for Windows build {1}.' -f $Dism.Build, $Os.Build) $null }
    if ($Os -and $Os.Insider) {
        & $add 'NOTE' 'This is a Windows Insider build. Windows Update often has no repair files for Insider builds, and no public ISO matches them.' $null
    }

    if ($Policy) {
        if ($Policy.NeverWindowsUpdate) { & $add 'WARN' 'Group Policy stops repairs from using Windows Update.' 'Ask whoever manages this PC, or use a matching Windows ISO as the source (Technician mode).' }
        if ($Policy.LocalSource) { & $add 'NOTE' 'Group Policy sets a repair source path. DISM tries it first; it must be the same build and edition, and up to date.' $null }
        if ($Policy.Wsus -and -not $Policy.DirectWindowsUpdate) { & $add 'NOTE' 'This PC gets updates from a company update server (WSUS). Many WSUS servers do not have repair files.' $null }
    }
    if (-not $Online) { & $add 'NOTE' 'The Online switch is off, so RestoreHealth uses only the files already on this PC.' $null }

    if ($LastCode -and $script:AfDismCodes.Contains($LastCode)) {
        $code = $script:AfDismCodes[$LastCode]
        $next = switch ($code.Cause) {
            'source' {
                if (-not $Online) { 'Turn on "Go online when a step needs it" in Settings and run R again. Windows Update has the files for this exact build.' }
                elseif ($Policy -and ($Policy.NeverWindowsUpdate -or ($Policy.Wsus -and -not $Policy.DirectWindowsUpdate))) { 'A policy keeps DISM away from Windows Update. Ask whoever manages this PC, or use a matching Windows ISO (Technician mode).' }
                else { 'Windows Update did not have them either. Next: a matching Windows ISO (Technician mode), or an in-place repair install.' }
            }
            'nowhere' { 'Open Settings > System > Recovery > "Fix problems using Windows Update" (Reinstall now). It reinstalls this exact build from Windows Update and keeps files and apps. It takes about an hour or two.' }
            'download' { 'Check the internet connection, VPN and proxy, then run R again.' }
            'blocked' { 'Ask whoever manages this PC to allow repairs from Windows Update, or use a matching Windows ISO (Technician mode).' }
            'pending' { 'Restart Windows, then run R again.' }
            'store' { 'Install the latest Windows update, restart, then run R again.' }
        }
        & $add 'WARN' ('{0}: {1}' -f $LastCode, $code.Text) $next
    }
    return $findings.ToArray()
}

function Get-AfDismSourceCheck {
    # Everything the check reads, plus the findings. Nothing here changes the PC.
    [CmdletBinding()]
    param(
        [bool] $Online,
        # Leave empty to use the last error in dism.log.
        [string] $LastCode,
        [scriptblock] $ReadRegistry = { param($Path) Get-ItemProperty -LiteralPath $Path -ErrorAction Stop },
        [string] $LogPath = (Join-Path (Get-AfWindowsRoot) 'Logs\DISM\dism.log')
    )

    $os = Get-AfOsBuild -ReadRegistry $ReadRegistry
    $dism = Get-AfDismBuild
    $policy = Get-AfRepairSourcePolicy -ReadRegistry $ReadRegistry
    $last = $null
    if ($LastCode) { $last = [pscustomobject]@{ Code = $LastCode; When = '' } }
    else { $last = Get-AfDismLogLastError -Path $LogPath }
    $code = $null
    if ($last) { $code = $last.Code }
    [pscustomobject]@{
        Os       = $os
        Dism     = $dism
        Policy   = $policy
        Last     = $last
        Findings = @(Get-AfDismSourceVerdict -Os $os -Dism $dism -Policy $policy -LastCode $code -Online $Online)
    }
}

function Format-AfDismSourceCheck {
    # The lines the screen and the log share.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Check)

    $lines = New-Object System.Collections.Generic.List[string]
    $osText = 'unknown'
    if ($Check.Os) { $osText = $Check.Os.Text }
    $lines.Add(('Windows   : {0}' -f $osText))
    $lines.Add(('DISM      : {0} ({1})' -f $Check.Dism.Text, $Check.Dism.Path))
    $source = @()
    if ($Check.Policy.NeverWindowsUpdate) { $source += 'Windows Update blocked by policy' } else { $source += 'Windows Update allowed' }
    if ($Check.Policy.Wsus) { $source += 'WSUS in use' }
    if ($Check.Policy.LocalSource) { $source += 'policy repair path set' }
    $lines.Add(('Source    : {0}' -f ($source -join '; ')))
    if ($Check.Last) {
        $when = ''
        if ($Check.Last.When) { $when = ' at {0}' -f $Check.Last.When }
        $lines.Add(('Last error: {0}{1}' -f $Check.Last.Code, $when))
    }
    foreach ($f in $Check.Findings) {
        $lines.Add(('{0,-5} {1}' -f $f.Level, $f.Text))
        if ($f.Next) { $lines.Add(('      Next: {0}' -f $f.Next)) }
    }
    return $lines.ToArray()
}

function ConvertFrom-AfWimInfo {
    # Reads "dism /English /Get-WimInfo" output: one object per Index block.
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Text = @())

    $images = New-Object System.Collections.Generic.List[object]
    $current = $null
    $inLanguages = $false
    foreach ($line in $Text) {
        if ($line -match '^\s*Index\s*:\s*(\d+)') {
            $current = [pscustomobject]@{ Index = [int]$Matches[1]; Name = ''; Build = $null; Ubr = $null; Edition = ''; Languages = @() }
            $images.Add($current)
            $inLanguages = $false
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\s*Name\s*:\s*(.+)$') { $current.Name = $Matches[1].Trim(); $inLanguages = $false }
        elseif ($line -match '^\s*Version\s*:\s*\d+\.\d+\.(\d+)') { $current.Build = [int]$Matches[1]; $inLanguages = $false }
        elseif ($line -match '^\s*ServicePack Build\s*:\s*(\d+)') { $current.Ubr = [int]$Matches[1]; $inLanguages = $false }
        elseif ($line -match '^\s*Edition\s*:\s*(\S+)') { $current.Edition = $Matches[1]; $inLanguages = $false }
        elseif ($line -match '^\s*Languages\s*:') { $inLanguages = $true }
        elseif ($inLanguages -and $line -match '^\s+([a-z]{2,3}-[A-Za-z0-9-]+)') { $current.Languages += $Matches[1] }
        elseif ($line -match '^\s*\S[^:]*:') { $inLanguages = $false }
    }
    return $images.ToArray()
}

function Resolve-AfWimPath {
    # Accepts a mounted ISO's drive (E: or E:\), its sources folder, or the file itself.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Path)

    $p = $Path.Trim().Trim('"')
    if (-not $p) { return $null }
    if ($p -match '^[A-Za-z]:\\?$') { $p = $p.Substring(0, 2) + '\sources' }
    if (Test-Path -LiteralPath $p -PathType Container) {
        foreach ($name in 'install.wim', 'install.esd') {
            $file = Join-Path $p $name
            if (Test-Path -LiteralPath $file -PathType Leaf) { return $file }
        }
        return $null
    }
    if ((Test-Path -LiteralPath $p -PathType Leaf) -and $p -match '\.(wim|esd)$') { return $p }
    return $null
}

function Get-AfWimInfo {
    # Lists the editions in a Windows image with their build. Reads only.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        # Runs dism.exe with these arguments and returns its output lines.
        [scriptblock] $RunDism = { param([string[]] $Arguments) & (Get-AfSystemToolPath 'dism.exe') @Arguments 2>&1 | ForEach-Object { [string]$_ } }
    )

    $list = @(ConvertFrom-AfWimInfo -Text @(& $RunDism @('/English', '/Get-WimInfo', "/WimFile:$Path")))
    $images = foreach ($item in $list) {
        $detail = @(ConvertFrom-AfWimInfo -Text @(& $RunDism @('/English', '/Get-WimInfo', "/WimFile:$Path", "/Index:$($item.Index)")))
        if ($detail.Count -gt 0) { $detail[0] } else { $item }
    }
    return @($images)
}

function Compare-AfWimToOs {
    <#
    .SYNOPSIS
        Picks the image that matches this PC's edition and says whether it can work:
        MATCH, OLDER (same build, fewer updates: Microsoft says repairs may fail),
        OTHERBUILD or NOEDITION.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Images = @(),
        [Parameter(Mandatory)] $Os
    )

    $same = @($Images | Where-Object { $_.Edition -eq $Os.Edition })
    if ($same.Count -eq 0) {
        $have = (@($Images | ForEach-Object { $_.Edition }) | Select-Object -Unique) -join ', '
        return [pscustomobject]@{ Verdict = 'NOEDITION'; Image = $null; Text = ('No {0} edition in this image (it has: {1}).' -f $Os.Edition, $have) }
    }
    $image = $same[0]
    if ($image.Build -ne $Os.Build) {
        return [pscustomobject]@{ Verdict = 'OTHERBUILD'; Image = $image; Text = ('The image is build {0}; this PC is build {1}. DISM cannot repair from it.' -f $image.Build, $Os.Build) }
    }
    if ($null -ne $image.Ubr -and $image.Ubr -lt $Os.Ubr) {
        return [pscustomobject]@{ Verdict = 'OLDER'; Image = $image; Text = ('The image is {0}.{1}; this PC is {0}.{2}. It is older than the PC''s updates, so the repair may still fail.' -f $Os.Build, $image.Ubr, $Os.Ubr) }
    }
    return [pscustomobject]@{ Verdict = 'MATCH'; Image = $image; Text = ('Index {0} ({1}) matches this PC: build {2}.{3}.' -f $image.Index, $image.Name, $image.Build, $image.Ubr) }
}

function Get-AfWimSourceArgument {
    # The value for /Source. Paths with spaces or quotes are refused instead of quoted,
    # because a mounted ISO (E:\sources\install.wim) never needs them.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int] $Index
    )

    if ($Path -match '[\s"]') { return $null }
    $kind = 'wim'
    if ($Path -match '\.esd$') { $kind = 'esd' }
    return ('{0}:{1}:{2}' -f $kind, $Path, $Index)
}

function Invoke-AfDismSourceScreen {
    <#
    .SYNOPSIS
        The "DISM version and source" item on the repair screen. Shows the check; in
        Technician mode it can also check a Windows ISO and return a /Source value for
        RestoreHealth (or nothing).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadLine = { Read-Host '  Drive or path' },
        [scriptblock] $Check = { param($Online) Get-AfDismSourceCheck -Online $Online },
        [scriptblock] $WimInfo = { param($Path) Get-AfWimInfo -Path $Path },
        [scriptblock] $ResolvePath = { param($Path) Resolve-AfWimPath -Path $Path }
    )

    $colors = @{ OK = 'Green'; NOTE = 'Gray'; WARN = 'Yellow' }
    $result = & $Check ([bool]$Settings.Online)
    Write-Host ''
    Write-Host '  DISM version and repair source (read-only, offline)' -ForegroundColor Cyan
    foreach ($line in (Format-AfDismSourceCheck -Check $result)) {
        $color = 'White'
        $level = ($line -split ' ')[0]
        if ($colors.ContainsKey($level)) { $color = $colors[$level] }
        if ($line -match '^\s+Next:') { $color = 'Yellow' }
        Write-Host ('  {0}' -f $line) -ForegroundColor $color
    }

    if ($Settings.Mode -ne 'Technician' -or -not $result.Os) { return $null }
    Write-Host ''
    Write-Host '  You can check a Windows ISO as a repair source. Mount it first (double-click the ISO),' -ForegroundColor White
    Write-Host '  then type its drive letter. Auto-Fixer only reads it.' -ForegroundColor White
    if ((Read-AfYesNo -Prompt 'Check a Windows ISO or install.wim?' -ReadKey $ReadKey) -ne $true) { return $null }
    $path = & $ResolvePath ([string](& $ReadLine))
    if (-not $path) {
        Write-Host '  No install.wim or install.esd found there. Nothing was changed.' -ForegroundColor Yellow
        return $null
    }
    Write-Host ('  Reading {0} ...' -f $path) -ForegroundColor DarkGray
    $images = @(& $WimInfo $path)
    foreach ($image in $images) { Write-Host ('    Index {0,-3}{1,-34} build {2}.{3}  {4}' -f $image.Index, $image.Name, $image.Build, $image.Ubr, ($image.Languages -join ',')) }
    $match = Compare-AfWimToOs -Images $images -Os $result.Os
    $color = @{ MATCH = 'Green'; OLDER = 'Yellow' }[$match.Verdict]
    if (-not $color) { $color = 'Red' }
    Write-Host ('  {0}' -f $match.Text) -ForegroundColor $color
    if ($match.Verdict -notin 'MATCH', 'OLDER') { return $null }

    $source = Get-AfWimSourceArgument -Path $path -Index $match.Image.Index
    if (-not $source) {
        Write-Host '  That path has a space in it. Mount the ISO and use its drive letter instead.' -ForegroundColor Yellow
        return $null
    }
    Write-Host ('  RestoreHealth would read clean files from index {0} of this image and not go online.' -f $match.Image.Index) -ForegroundColor White
    if ((Read-AfYesNo -Prompt 'Run DISM RestoreHealth with this image as the source?' -ReadKey $ReadKey) -ne $true) { return $null }
    return $source
}
