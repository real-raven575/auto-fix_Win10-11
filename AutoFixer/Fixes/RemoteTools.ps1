# Remote access check (plan 2026-11-09): finds remote control tools and IT management
# agents that are not part of Windows, and helps remove one with the vendor's own
# uninstaller.
#   - the scan is read-only: registry, services, tasks, startup, processes, file names
#   - no internet: no signature check (it can fetch revocation lists online)
#   - never reads tool settings, connection IDs or passwords
#   - removal is one program at a time, asks first, offers a restore point and runs the
#     vendor's uninstaller with its own window; it never deletes files, stops services,
#     kills processes or edits the registry
#   - a PC that looks managed by an organization gets a warning; Standard mode then
#     offers no removal at all ("Ask your IT team")

$script:AfRemoteToolsPath = Join-Path $PSScriptRoot 'RemoteTools.json'
$script:AfRemoteKindPossible = 'Possible, check it'
# Names that suggest remote access on something not in the known list.
$script:AfRemoteGenericPattern = '(?i)\bremote\b|\bvnc\b|\brmm\b|desktop sharing|screen ?shar'
# Command shells and script hosts (by program name, without the extension) can run
# anything, so an uninstall command that starts one is never run.
$script:AfRemoteBlockedRunners = @('cmd', 'powershell', 'pwsh', 'wscript', 'cscript', 'mshta', 'conhost')

function Get-AfRemoteToolList {
    <# The known tools list: Name, Kind and Pattern for each tool. #>
    [CmdletBinding()]
    param([string] $Path = $script:AfRemoteToolsPath)
    $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    return @($data.tools | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Kind = [string]$_.kind; Pattern = '(?i)' + [string]$_.pattern } })
}

function Test-AfWindowsOwnPath {
    <# True for a path inside the Windows folder, so Windows' own parts are never flagged. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Path)
    if (-not $Path) { return $false }
    $windows = $env:SystemRoot
    if (-not $windows) { $windows = 'C:\Windows' }
    $clean = $Path.Trim().Trim('"')
    return $clean.StartsWith($windows.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-AfRemoteProgramEntry {
    <#
    .SYNOPSIS
        Read-only: installed programs from the Uninstall keys (64 and 32 bit, this user,
        and every user hive Windows has already loaded).
    #>
    [CmdletBinding()]
    param()
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    try {
        $roots += @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop |
                Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
                ForEach-Object { 'Registry::HKEY_USERS\{0}\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -f $_.PSChildName })
    }
    catch { Write-Verbose ('User hives not read: {0}' -f $_.Exception.Message) }
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            [pscustomobject]@{
                Source          = 'Installed programs'
                DisplayName     = [string]$p.DisplayName
                Publisher       = [string]$p.Publisher
                Version         = [string]$p.DisplayVersion
                InstallDate     = [string]$p.InstallDate
                InstallLocation = [string]$p.InstallLocation
                UninstallString = [string]$p.UninstallString
                SystemComponent = ([string]$p.SystemComponent -eq '1')
                KeyName         = [string]$key.PSChildName
            }
        }
    }
}

function Get-AfRemoteServiceEntry {
    <# Read-only: every service with its program path, start mode and state. #>
    [CmdletBinding()]
    param()
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
        [pscustomobject]@{ Source = 'Services'; Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; Path = [string]$s.PathName; StartMode = [string]$s.StartMode; State = [string]$s.State }
    }
}

function Get-AfRemoteTaskEntry {
    <# Read-only: scheduled tasks outside \Microsoft\ and the programs they start. #>
    [CmdletBinding()]
    param()
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })) {
        $exec = @($t.Actions | ForEach-Object { [string]$_.Execute } | Where-Object { $_ }) -join '; '
        [pscustomobject]@{ Source = 'Scheduled tasks'; Name = ('{0}{1}' -f $t.TaskPath, $t.TaskName); Path = $exec; State = [string]$t.State }
    }
}

function Get-AfRemoteStartupEntry {
    <# Read-only: Run and RunOnce keys and the Startup folders. #>
    [CmdletBinding()]
    param()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($name in @($item.GetValueNames() | Where-Object { $_ })) {
            [pscustomobject]@{ Source = 'Startup'; Name = [string]$name; Path = [string]$item.GetValue($name) }
        }
    }
    $folders = @([Environment]::GetFolderPath('CommonStartup'), [Environment]::GetFolderPath('Startup')) | Where-Object { $_ }
    foreach ($folder in $folders) {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{ Source = 'Startup'; Name = [string]$f.Name; Path = [string]$f.FullName }
        }
    }
}

function Get-AfRemoteProcessEntry {
    <# Read-only: running programs and where they run from. #>
    [CmdletBinding()]
    param()
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        [pscustomobject]@{ Source = 'Running now'; Name = [string]$p.Name; Path = [string]$p.ExecutablePath }
    }
}

function Get-AfRemoteFileEntry {
    <#
    .SYNOPSIS
        Read-only: .exe and .msi file names (no file is opened) in Downloads, Desktop, the
        user Temp folder and the top of ProgramData, two folders deep. Finds copies that
        run without being installed.
    #>
    [CmdletBinding()]
    param()
    $folders = @(
        (Join-Path $env:USERPROFILE 'Downloads')
        [Environment]::GetFolderPath('Desktop')
        $env:TEMP
        $env:ProgramData
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($folder in $folders) {
        $depth = 2
        if ($folder -eq $env:ProgramData) { $depth = 0 }
        $found = @(Get-ChildItem -LiteralPath $folder -Recurse -Depth $depth -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '.msi' })
        foreach ($f in $found) { [pscustomobject]@{ Source = 'Files (not installed)'; Name = [string]$f.Name; Path = [string]$f.FullName } }
    }
}

function Get-AfRemoteSearchText {
    <# The text a record is matched on: names and the program path. #>
    param([Parameter(Mandatory)] $Entry)
    if ($Entry.Source -eq 'Installed programs') { return ('{0} | {1} | {2}' -f $Entry.DisplayName, $Entry.Publisher, $Entry.InstallLocation) }
    return ('{0} | {1} | {2}' -f $Entry.Name, $Entry.DisplayName, $Entry.Path)
}

function Find-AfRemoteTool {
    <#
    .SYNOPSIS
        Read-only. Groups every source record that matches a known tool, plus remote-
        sounding programs not on the list, into one finding per program.
    .DESCRIPTION
        Each source is a script block so the tests pass their own records. A source
        that fails is named in Skipped; the others still run.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Catalog = (Get-AfRemoteToolList),
        [hashtable] $Sources = @{
            Programs  = { Get-AfRemoteProgramEntry }
            Services  = { Get-AfRemoteServiceEntry }
            Tasks     = { Get-AfRemoteTaskEntry }
            Startup   = { Get-AfRemoteStartupEntry }
            Processes = { Get-AfRemoteProcessEntry }
            Files     = { Get-AfRemoteFileEntry }
        }
    )

    $records = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($name in 'Programs', 'Services', 'Tasks', 'Startup', 'Processes', 'Files') {
        if (-not $Sources.ContainsKey($name)) { continue }
        try { foreach ($r in @(& $Sources[$name])) { if ($r) { $records.Add($r) } } }
        catch { $skipped.Add(('{0}: {1}' -f $name, $_.Exception.Message)) }
    }

    $groups = [ordered]@{}
    foreach ($r in $records) {
        $text = Get-AfRemoteSearchText -Entry $r
        $tool = @($Catalog | Where-Object { $text -match $_.Pattern }) | Select-Object -First 1
        if ($tool) { $key = 'K|' + $tool.Name; $toolName = $tool.Name; $kind = $tool.Kind }
        else {
            # Unknown: only names that sound remote, never Windows' own or Microsoft's parts,
            # and never loose files (Downloads is full of names like that).
            if ($r.Source -eq 'Files (not installed)') { continue }
            $own = (Test-AfWindowsOwnPath $r.Path) -or (Test-AfWindowsOwnPath $r.InstallLocation) -or ([string]$r.Publisher -match '(?i)^Microsoft')
            if ($own) { continue }
            $label = $(if ($r.Source -eq 'Installed programs') { $r.DisplayName } elseif ($r.DisplayName) { $r.DisplayName } else { $r.Name })
            if ($label -notmatch $script:AfRemoteGenericPattern) { continue }
            $key = 'P|' + $label.ToLowerInvariant(); $toolName = $label; $kind = $script:AfRemoteKindPossible
        }
        if (-not $groups.Contains($key)) { $groups[$key] = [pscustomobject]@{ Name = $toolName; Kind = $kind; Records = New-Object System.Collections.Generic.List[object] } }
        $groups[$key].Records.Add($r)
    }

    $findings = foreach ($g in $groups.Values) {
        $rec = @($g.Records)
        $programs = @($rec | Where-Object { $_.Source -eq 'Installed programs' })
        $services = @($rec | Where-Object { $_.Source -eq 'Services' })
        $inApps = @($programs | Where-Object { -not $_.SystemComponent }).Count -gt 0
        $installed = $programs.Count + $services.Count + @($rec | Where-Object { $_.Source -in 'Scheduled tasks', 'Startup' }).Count
        $paths = @($rec | ForEach-Object { if ($_.Source -eq 'Installed programs') { $_.InstallLocation } else { $_.Path } } | Where-Object { $_ } | Select-Object -Unique)
        [pscustomobject]@{
            Name              = $g.Name
            Kind              = $g.Kind
            FoundIn           = @($rec | ForEach-Object { $_.Source } | Select-Object -Unique)
            Running           = (@($rec | Where-Object { $_.Source -eq 'Running now' }).Count -gt 0) -or (@($services | Where-Object { $_.State -eq 'Running' }).Count -gt 0)
            StartsWithWindows = (@($services | Where-Object { $_.StartMode -eq 'Auto' }).Count -gt 0) -or (@($rec | Where-Object { $_.Source -in 'Scheduled tasks', 'Startup' }).Count -gt 0)
            HiddenFromApps    = (-not $inApps) -and $installed -gt 0
            Portable          = $installed -eq 0
            Programs          = $programs
            Paths             = $paths
            Version           = (@($programs | ForEach-Object { $_.Version } | Where-Object { $_ }) | Select-Object -First 1)
        }
    }
    # Known tools first, then the ones to check by hand.
    $sorted = @($findings | Sort-Object @{ Expression = { $_.Kind -eq $script:AfRemoteKindPossible } }, Name)
    return [pscustomobject]@{ Findings = $sorted; Skipped = @($skipped) }
}

function Get-AfBuiltInRemoteState {
    <#
    .SYNOPSIS
        Read-only: Windows' own remote features and whether each is on. Shown for
        information only; Auto-Fixer never offers to remove them.
    #>
    [CmdletBinding()]
    param(
        [scriptblock] $GetValue = { param($Path, $Name) (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name },
        [scriptblock] $GetService = { param($Name) Get-Service -Name $Name -ErrorAction Stop },
        # Quick Assist is a Microsoft Store app on current Windows 10 and 11.
        [scriptblock] $HasQuickAssist = { [bool](Get-AppxPackage -Name 'MicrosoftCorporationII.QuickAssist' -ErrorAction Stop) }
    )

    $read = { param($Path, $Name) try { & $GetValue $Path $Name } catch { $null } }
    $svc = {
        param($Name)
        try {
            $s = & $GetService $Name
            if (-not $s) { return 'Not installed' }
            return ('Installed, {0}, starts {1}' -f ([string]$s.Status).ToLowerInvariant(), ([string]$s.StartType).ToLowerInvariant())
        }
        catch { return 'Not installed' }
    }
    $rdp = & $read 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    $ra = & $read 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp'
    $qa = 'Not known'
    try { $qa = $(if (& $HasQuickAssist) { 'Installed (only works when you start it)' } else { 'Not installed' }) } catch { $qa = 'Not known' }
    return @(
        [pscustomobject]@{ Name = 'Remote Desktop'; State = $(if ($null -eq $rdp) { 'Not known' } elseif ([int]$rdp -eq 0) { 'ON: others can sign in remotely' } else { 'Off' }) }
        [pscustomobject]@{ Name = 'Remote Assistance'; State = $(if ($null -eq $ra) { 'Not known' } elseif ([int]$ra -eq 1) { 'On: invitations allowed' } else { 'Off' }) }
        [pscustomobject]@{ Name = 'Quick Assist'; State = $qa }
        [pscustomobject]@{ Name = 'Windows Remote Management (WinRM)'; State = (& $svc 'WinRM') }
        [pscustomobject]@{ Name = 'OpenSSH Server'; State = (& $svc 'sshd') }
    )
}

function Test-AfManagedPc {
    <#
    .SYNOPSIS
        Read-only: does this PC look managed by an organization (work or school)?
        Returns IsManaged and the reasons. Remote tools there may be approved by IT.
    #>
    [CmdletBinding()]
    param(
        [object[]] $Findings = @(),
        [scriptblock] $IsDomainJoined = { [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain },
        [scriptblock] $IsAzureAdJoined = { Test-AfAzureAdJoined },
        [scriptblock] $IsMdmEnrolled = {
            $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
            if (-not (Test-Path -LiteralPath $root)) { return $false }
            [bool](@(Get-ChildItem -LiteralPath $root -ErrorAction Stop | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).ProviderID } | Where-Object { $_ }).Count)
        }
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $check = { param($Block) try { [bool](& $Block) } catch { $false } }
    if (& $check $IsDomainJoined) { $reasons.Add('joined to a domain') }
    if (& $check $IsAzureAdJoined) { $reasons.Add('joined to Microsoft Entra (Azure AD)') }
    if (& $check $IsMdmEnrolled) { $reasons.Add('enrolled in device management (MDM)') }
    $agents = @($Findings | Where-Object { $_.Kind -eq 'IT management agent' } | ForEach-Object { $_.Name })
    if ($agents.Count) { $reasons.Add(('an IT management agent is installed ({0})' -f ($agents -join ', '))) }
    return [pscustomobject]@{ IsManaged = $reasons.Count -gt 0; Reasons = @($reasons) }
}

function Get-AfUninstallCommand {
    <#
    .SYNOPSIS
        Turns a vendor's UninstallString into a program and its arguments, without a
        command shell. MSI products become msiexec /x {code} with its own window (no
        /qn). Refuses anything that is not a vendor uninstaller that exists.
    #>
    [CmdletBinding()]
    param(
        [string] $UninstallString,
        [scriptblock] $FileExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf },
        [string] $SystemFolder = $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32' } else { 'C:\Windows\System32' })
    )

    $fail = { param($Why) [pscustomobject]@{ Ok = $false; FilePath = $null; Arguments = $null; Display = $null; Reason = $Why } }
    $text = ([string]$UninstallString).Trim()
    if (-not $text) { return (& $fail 'The program left no uninstall command.') }

    $msi = [regex]::Match($text, '(?i)^"?(?:[^"]*\\)?msiexec(?:\.exe)?"?\s.*?(\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\})')
    if ($msi.Success) {
        $file = Join-Path $SystemFolder 'msiexec.exe'
        $arguments = '/x {0}' -f $msi.Groups[1].Value.ToUpperInvariant()
        return [pscustomobject]@{ Ok = $true; FilePath = $file; Arguments = $arguments; Display = ('"{0}" {1}' -f $file, $arguments); Reason = $null }
    }

    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -lt 0) { return (& $fail 'The uninstall command could not be read (a quote is missing).') }
        $file = $text.Substring(1, $end - 1)
        $arguments = $text.Substring($end + 1).Trim()
    }
    else {
        $m = [regex]::Match($text, '(?i)^(.+?\.exe)(?:\s+(.*))?$')
        if (-not $m.Success) { return (& $fail 'The uninstall command does not start a program file.') }
        $file = $m.Groups[1].Value
        $arguments = $m.Groups[2].Value.Trim()
    }
    $file = [Environment]::ExpandEnvironmentVariables($file)
    if ($file -notmatch '(?i)\.exe$') { return (& $fail 'The uninstall command does not start a program file.') }
    if ($script:AfRemoteBlockedRunners -contains [IO.Path]::GetFileNameWithoutExtension($file).ToLowerInvariant()) {
        return (& $fail ('The uninstall command runs {0}, not the vendor''s uninstaller, so Auto-Fixer will not run it.' -f (Split-Path -Path $file -Leaf)))
    }
    if (-not (& $FileExists $file)) { return (& $fail 'The vendor''s uninstaller file is missing.') }
    $display = $(if ($arguments) { '"{0}" {1}' -f $file, $arguments } else { '"{0}"' -f $file })
    return [pscustomobject]@{ Ok = $true; FilePath = $file; Arguments = $arguments; Display = $display; Reason = $null }
}

function Get-AfUninstallExitText {
    <# Plain words for an uninstaller's exit code. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $ExitCode)
    switch ($ExitCode) {
        0 { return 'Finished without an error.' }
        1602 { return 'Cancelled in the uninstaller.' }
        1605 { return 'Windows says this product is not installed.' }
        1618 { return 'Another install or uninstall is running. Try again when it is done.' }
        1603 { return 'The uninstaller hit a fatal error.' }
        3010 { return 'Finished. A restart is needed to complete it.' }
        1641 { return 'Finished. The uninstaller started a restart.' }
        default { return ('The uninstaller returned code {0}. Its meaning is set by the vendor.' -f $ExitCode) }
    }
}

function Format-AfRemoteReport {
    <#
    .SYNOPSIS
        The results as text lines, used for the screen and the log. Paths go through the
        redactor, so user names never reach the log.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Scan,
        [object[]] $BuiltIn = @(),
        [Parameter(Mandatory)] $Managed,
        [AllowNull()] $Redactor
    )

    $p = { param($Text) Protect-AfText -Redactor $Redactor -Text $Text }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Managed.IsManaged) {
        $lines.Add('!! This PC looks managed by an organization: {0}.' -f ($Managed.Reasons -join '; '))
        $lines.Add('!! Remote tools here may be approved by your IT team. Ask them before removing anything.')
        $lines.Add('')
    }
    $found = @($Scan.Findings)
    if ($found.Count -eq 0) { $lines.Add('No remote access programs from the list were found.') }
    else { $lines.Add(('Found {0} program(s):' -f $found.Count)) }
    $n = 0
    foreach ($f in $found) {
        $n++
        $flags = @()
        if ($f.Running) { $flags += 'running now' }
        if ($f.StartsWithWindows) { $flags += 'starts with Windows' }
        if ($f.HiddenFromApps) { $flags += 'NOT IN APPS LIST' }
        if ($f.Portable) { $flags += 'copy, not installed' }
        $version = $(if ($f.Version) { ' ' + $f.Version } else { '' })
        $lines.Add(('{0,2}. {1}{2} [{3}]' -f $n, $f.Name, $version, $f.Kind))
        if ($flags.Count) { $lines.Add(('    {0}' -f ($flags -join ', '))) }
        $lines.Add(('    Found in: {0}' -f ($f.FoundIn -join ', ')))
        foreach ($path in @($f.Paths | Select-Object -First 3)) { $lines.Add(('    {0}' -f (& $p $path))) }
    }
    $lines.Add('')
    $lines.Add('Built into Windows (information only, not removed):')
    foreach ($b in $BuiltIn) { $lines.Add(('    {0}: {1}' -f $b.Name, $b.State)) }
    foreach ($s in @($Scan.Skipped)) { $lines.Add(('Not checked: {0}' -f (& $p $s))) }
    $lines.Add('')
    $lines.Add('This list finds known tools. A renamed or custom tool can still hide.')
    if (@($found | Where-Object { $_.Kind -ne 'IT management agent' }).Count) {
        $lines.Add('If you did not install one of these, disconnect the PC from the internet and ask a')
        $lines.Add('technician you trust before signing in to anything.')
    }
    return [string[]]$lines
}

function Get-AfRemovalPlan {
    <#
    .SYNOPSIS
        Decides what removal may offer for one finding: Blocked (Standard mode on a
        managed PC), Manual (no usable uninstaller) or Run (with the command).
        ExtraWarning is set for IT management agents and any managed PC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Finding,
        [Parameter(Mandatory)] $Managed,
        [string] $Mode = 'Standard',
        [scriptblock] $FileExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    )

    $extra = $Managed.IsManaged -or $Finding.Kind -eq 'IT management agent'
    if ($Managed.IsManaged -and $Mode -ne 'Technician') {
        return [pscustomobject]@{ Action = 'Blocked'; Command = $null; ExtraWarning = $true; Reason = 'This PC looks managed by an organization. Ask your IT team before removing anything.' }
    }
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($program in @($Finding.Programs)) {
        $cmd = Get-AfUninstallCommand -UninstallString $program.UninstallString -FileExists $FileExists
        if ($cmd.Ok) { return [pscustomobject]@{ Action = 'Run'; Command = $cmd; ExtraWarning = $extra; Reason = $null } }
        $reasons.Add($cmd.Reason)
    }
    $why = $(if ($reasons.Count) { $reasons[0] } elseif ($Finding.Portable) { 'This is a copy that runs without being installed, so it has no uninstaller.' } else { 'It has no uninstall entry (it hides from the Apps list).' })
    return [pscustomobject]@{ Action = 'Manual'; Command = $null; ExtraWarning = $extra; Reason = $why }
}

function Invoke-AfRemoteToolRemoval {
    <#
    .SYNOPSIS
        Removes one program with its vendor's uninstaller, after showing the command,
        offering a restore point and asking Y/N. Then checks again whether it is gone.
        Returns Blocked, Manual, Declined, or Ran with the exit code and re-check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Finding,
        [Parameter(Mandatory)] $Managed,
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [AllowNull()] $Log,
        [scriptblock] $ReadKey = { Read-AfKey },
        [scriptblock] $FileExists = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf },
        [scriptblock] $RestorePoint = { New-AfRestorePoint -Description 'Auto-Fixer: before removing a remote access program' },
        # Starts the uninstaller with its own window, waits, returns the exit code.
        [scriptblock] $RunUninstaller = {
            param($FilePath, $Arguments)
            $start = @{ FilePath = $FilePath; Wait = $true; PassThru = $true; ErrorAction = 'Stop' }
            if ($Arguments) { $start.ArgumentList = $Arguments }
            (Start-Process @start).ExitCode
        },
        [scriptblock] $OpenAppsSettings = { Start-Process -FilePath 'ms-settings:appsfeatures' -ErrorAction Stop },
        # Called with the finding's name; returns the fresh finding, or $null when gone.
        [scriptblock] $Recheck = { param($Name) @((Find-AfRemoteTool).Findings | Where-Object { $_.Name -eq $Name })[0] }
    )

    $note = { param($Text) if ($Log) { Write-AfToolLog $Log $Text } }
    $plan = Get-AfRemovalPlan -Finding $Finding -Managed $Managed -Mode $Settings.Mode -FileExists $FileExists
    Write-Host ''
    Write-Host ('  {0} [{1}]' -f $Finding.Name, $Finding.Kind) -ForegroundColor White
    Write-Host ('  Found in: {0}' -f ($Finding.FoundIn -join ', '))

    if ($plan.Action -eq 'Blocked') {
        Write-Host ('  {0}' -f $plan.Reason) -ForegroundColor Yellow
        & $note ('{0}: removal not offered (managed PC, Standard mode).' -f $Finding.Name)
        return [pscustomobject]@{ Result = 'Blocked' }
    }
    if ($plan.Action -eq 'Manual') {
        Write-Host ('  Auto-Fixer cannot remove this one for you: {0}' -f $plan.Reason) -ForegroundColor Yellow
        Write-Host '  What you can do:'
        Write-Host '    1. Look for it in Settings > Apps > Installed apps and uninstall it there.'
        Write-Host '    2. If it is not listed, use the vendor''s own removal tool or ask a technician.'
        Write-Host '    3. A copy that is not installed can be deleted from its folder by hand (shown above).'
        Write-Host '  Auto-Fixer never deletes files or stops services by itself.' -ForegroundColor DarkGray
        & $note ('{0}: no usable uninstaller ({1}). Manual steps shown.' -f $Finding.Name, $plan.Reason)
        if (Read-AfYesNo -Prompt 'Open Settings > Apps now?' -ReadKey $ReadKey) {
            try { & $OpenAppsSettings } catch { Write-Host ('  Settings did not open: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        }
        return [pscustomobject]@{ Result = 'Manual' }
    }

    Write-Host '  The vendor''s own uninstaller will open in its own window. Command:'
    Write-Host ('    {0}' -f $plan.Command.Display) -ForegroundColor Cyan
    if ($plan.ExtraWarning) {
        Write-Host ''
        Write-Host '  WARNING: this may be a tool your IT team or a support company uses to look after' -ForegroundColor Yellow
        Write-Host '  this PC. Removing it can break their support and may break your work agreement.' -ForegroundColor Yellow
        if (-not (Read-AfYesNo -Prompt 'Remove it anyway?' -ReadKey $ReadKey)) {
            & $note ('{0}: declined at the IT warning.' -f $Finding.Name)
            return [pscustomobject]@{ Result = 'Declined' }
        }
    }
    if (Read-AfYesNo -Prompt 'Make a restore point first? (recommended)' -ReadKey $ReadKey) {
        Write-Host '  Making a restore point...' -ForegroundColor DarkGray
        $rp = & $RestorePoint
        if ($rp.Ok) { Write-Host '  Restore point made.' -ForegroundColor Green; & $note 'Restore point made.' }
        else {
            Write-Host ('  No restore point: {0}' -f $rp.Reason) -ForegroundColor Yellow
            & $note ('No restore point: {0}' -f $rp.Reason)
            if (-not (Read-AfYesNo -Prompt 'Continue without one?' -ReadKey $ReadKey)) { return [pscustomobject]@{ Result = 'Declined' } }
        }
    }
    if (-not (Read-AfYesNo -Prompt ('Run the {0} uninstaller now?' -f $Finding.Name) -ReadKey $ReadKey)) {
        & $note ('{0}: declined, nothing run.' -f $Finding.Name)
        return [pscustomobject]@{ Result = 'Declined' }
    }

    & $note ('Running: {0}' -f $plan.Command.Display)
    try { $code = [int](& $RunUninstaller $plan.Command.FilePath $plan.Command.Arguments) }
    catch {
        Write-Host ('  The uninstaller did not start: {0}' -f $_.Exception.Message) -ForegroundColor Red
        & $note ('Uninstaller did not start: {0}' -f $_.Exception.Message)
        return [pscustomobject]@{ Result = 'Failed'; ExitCode = $null; StillFound = $true }
    }
    $meaning = Get-AfUninstallExitText -ExitCode $code
    Write-Host ('  The uninstaller reported: exit code {0}. {1}' -f $code, $meaning)
    & $note ('Exit code {0}: {1}' -f $code, $meaning)
    Write-Host '  Some uninstallers keep working in a second window after this.' -ForegroundColor DarkGray
    Write-Host '  When it is finished, press any key to check again.' -ForegroundColor DarkGray
    $null = & $ReadKey
    $after = & $Recheck $Finding.Name
    if ($after) {
        Write-Host ('  Re-check: still found in {0}.' -f ($after.FoundIn -join ', ')) -ForegroundColor Yellow
        Write-Host '  Leftovers are listed only; Auto-Fixer does not delete them.' -ForegroundColor DarkGray
        & $note ('Re-check: still found in {0}.' -f ($after.FoundIn -join ', '))
    }
    else {
        Write-Host '  Re-check: gone.' -ForegroundColor Green
        & $note 'Re-check: gone.'
    }
    return [pscustomobject]@{ Result = 'Ran'; ExitCode = $code; StillFound = [bool]$after }
}

function Invoke-AfRemoteAccessMenu {
    <#
    .SYNOPSIS
        Remote access check: the read-only scan, the results, then an optional pick of
        one program to remove. Both modes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $Find = { Find-AfRemoteTool },
        [scriptblock] $BuiltIn = { Get-AfBuiltInRemoteState },
        [scriptblock] $Managed = { param($Findings) Test-AfManagedPc -Findings $Findings },
        # Called with the finding, the managed facts, the settings and the log.
        [scriptblock] $Remove = { param($F, $M, $S, $L) $null = Invoke-AfRemoteToolRemoval -Finding $F -Managed $M -Settings $S -Log $L -ReadKey $ReadKey }
    )

    Write-Host ''
    Write-Host '  Checking for remote access programs. Read-only: nothing is changed.' -ForegroundColor Cyan
    $scan = & $Find
    $managedFacts = & $Managed @($scan.Findings)
    $builtInState = @(& $BuiltIn)
    $redactor = New-AfRedactor
    $screen = $redactor
    if ($Settings.ShowSensitive) { $screen = New-AfRedactor -Disabled }

    $log = $null
    try {
        $log = New-AfToolLog -OutputRoot $OutputRoot -Kind 'remote' -Redactor $redactor -Task 'check for remote access programs'
        foreach ($line in (Format-AfRemoteReport -Scan $scan -BuiltIn $builtInState -Managed $managedFacts -Redactor $redactor)) { Write-AfToolLog $log $line }
    }
    catch { Write-Host ('  The log could not be written: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }

    Write-Host ''
    foreach ($line in (Format-AfRemoteReport -Scan $scan -BuiltIn $builtInState -Managed $managedFacts -Redactor $screen)) {
        $color = 'Gray'
        if ($line.StartsWith('!!') -or $line -match 'NOT IN APPS LIST') { $color = 'Yellow' }
        elseif ($line -match '^\s*\d+\. ') { $color = 'White' }
        Write-Host ('  {0}' -f $line) -ForegroundColor $color
    }
    if ($log) { Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $screen -Text $log.Path)) -ForegroundColor DarkGray }

    $found = @($scan.Findings)
    Write-Host ''
    if ($found.Count -eq 0) {
        Write-Host '  Press any key to return to the menu.' -ForegroundColor DarkGray
        $null = & $ReadKey
        return
    }
    if ($managedFacts.IsManaged -and $Settings.Mode -ne 'Technician') {
        Write-Host '  Removal is not offered on a managed PC in Standard mode. Ask your IT team.' -ForegroundColor Yellow
        Write-Host '  Press any key to return to the menu.' -ForegroundColor DarkGray
        $null = & $ReadKey
        return
    }
    Write-Host '  Press R to choose a program to remove, or any other key to return to the menu.' -ForegroundColor DarkGray
    if ([string](& $ReadKey) -ne 'R') { return }

    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $found.Count; $i++) { $items.Add(@{ Key = ('F{0}' -f ($i + 1)); Label = ('{0} ({1})' -f $found[$i].Name, $found[$i].Kind) }) }
    $items[$items.Count - 1].Divider = $true
    $items.Add(@{ Key = 'B'; Label = '&Back' })
    $items.Add(@{ Key = 'Q'; Label = '&Quit' })
    $info = @('Pick ONE program. Nothing runs until you answer Y.')
    $choice = Select-AfMenuItem -Title 'Remove a remote access program' -Items $items.ToArray() -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info `
        -Mode $Settings.Mode -EscapeKey 'B' -ReadKey $ReadKey
    if ($choice -eq 'B') { return }
    if ($choice -eq 'Q') {
        if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true }
        return
    }
    $pick = $found[[int]$choice.Substring(1) - 1]
    try { & $Remove $pick $managedFacts $Settings $log }
    catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Press any key to return to the menu.' -ForegroundColor DarkGray
    $null = & $ReadKey
}
