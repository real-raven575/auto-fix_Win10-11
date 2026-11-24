# Debloat damage check (Repair menu, raven575 2026-11-24): finds what "debloat" tools
# often leave behind that breaks Windows Update or the Microsoft Store, and puts each
# item back to the Windows default, one at a time.
#   - the check is read-only and runs in both modes
#   - every change is shown first and asks Y/N; a restore point is offered first
#   - each change is read back, so the screen and log say what really happened
#   - privacy choices (diagnostic data off) are shown as information and left alone
#   - on a work PC (domain or Entra joined) policy values are left to the IT team

# Services that updates and the Store need. Start is the Windows default for sc.exe:
# demand = Manual (Windows starts it when needed), delayed-auto, auto.
$script:AfDebloatServices = @(
    @{ Name = 'wuauserv'; What = 'Windows Update'; Start = 'demand' }
    @{ Name = 'BITS'; What = 'Background Intelligent Transfer (update and Store downloads)'; Start = 'demand' }
    @{ Name = 'UsoSvc'; What = 'Update Orchestrator (schedules updates)'; Start = 'delayed-auto' }
    @{ Name = 'WaaSMedicSvc'; What = 'Windows Update Medic (repairs Windows Update)'; Start = 'demand' }
    @{ Name = 'DoSvc'; What = 'Delivery Optimization (update and Store downloads)'; Start = 'delayed-auto' }
    @{ Name = 'CryptSvc'; What = 'Cryptographic Services (checks update signatures)'; Start = 'auto' }
    @{ Name = 'TrustedInstaller'; What = 'Windows Modules Installer (installs updates)'; Start = 'demand' }
    @{ Name = 'ClipSVC'; What = 'Client License Service (Store app licenses)'; Start = 'demand' }
    @{ Name = 'LicenseManager'; What = 'Windows License Manager (Store licenses)'; Start = 'demand' }
    @{ Name = 'InstallService'; What = 'Microsoft Store Install Service'; Start = 'demand' }
    @{ Name = 'AppXSvc'; What = 'AppX Deployment (installs and updates Store apps)'; Start = 'demand' }
    @{ Name = 'wlidsvc'; What = 'Microsoft Account Sign-in Assistant (Store sign-in)'; Start = 'demand' }
)

# Policy values debloat tools set. Bad is the value that turns the feature off; the fix
# removes only that one value, which is the Windows default (no policy).
$script:AfDebloatPolicies = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Value = 'DisableAntiSpyware'; Bad = 1; What = 'Microsoft Defender Antivirus turned off by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Value = 'DisableRealtimeMonitoring'; Bad = 1; What = 'Defender real-time protection turned off by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Value = 'NoAutoUpdate'; Bad = 1; What = 'Automatic updates turned off by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Value = 'DisableWindowsUpdateAccess'; Bad = 1; What = 'Windows Update blocked by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Value = 'DoNotConnectToWindowsUpdateInternetLocations'; Bad = 1; What = 'Windows Update kept off Microsoft''s servers by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Value = 'RemoveWindowsStore'; Bad = 1; What = 'Microsoft Store blocked by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; Value = 'DisableStoreApps'; Bad = 1; What = 'Store apps blocked by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Value = 'EnableSmartScreen'; Bad = 0; What = 'SmartScreen turned off by a policy' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Value = 'AllowTelemetry'; Bad = 0; What = 'Diagnostic data set to the lowest level'; InfoOnly = $true }
)

# The Store apps checked for the account running Auto-Fixer.
$script:AfDebloatApps = @(
    @{ Name = 'Microsoft.WindowsStore'; What = 'Microsoft Store' }
    @{ Name = 'Microsoft.DesktopAppInstaller'; What = 'App Installer (winget and app installs)' }
)

# Hosts-file names that Windows Update and the Store must reach. A blocking line for any
# of these (or a name under them) breaks updates or Store downloads.
$script:AfDebloatHostNames = @(
    'windowsupdate.com', 'update.microsoft.com', 'windowsupdate.microsoft.com', 'delivery.mp.microsoft.com',
    'displaycatalog.mp.microsoft.com', 'licensing.mp.microsoft.com', 'storeedgefd.dsx.mp.microsoft.com', 'login.live.com'
)

# SystemRoot is always set on Windows; the fallback only lets the module load elsewhere (tests).
$script:AfHostsPath = '{0}\System32\drivers\etc\hosts' -f $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' })

function Get-AfDebloatHostsLine {
    <#
    .SYNOPSIS
        The hosts-file lines that block a Windows Update or Store name: Index (0-based),
        Line and Names. Comments and blank lines are ignored. Read-only.
    #>
    [CmdletBinding()]
    param([string[]] $Lines = @(), [string[]] $Names = $script:AfDebloatHostNames)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $text = ([string]$Lines[$i] -split '#', 2)[0].Trim()
        if (-not $text) { continue }
        $parts = @($text -split '\s+')
        if ($parts.Count -lt 2) { continue }
        $hit = @(foreach ($h in $parts[1..($parts.Count - 1)]) {
                $low = $h.ToLowerInvariant()
                foreach ($n in $Names) { if ($low -eq $n -or $low.EndsWith('.' + $n)) { $h; break } }
            })
        if ($hit.Count) { [pscustomobject]@{ Index = $i; Line = [string]$Lines[$i]; Names = $hit } }
    }
}

function Get-AfDebloatOps {
    # The real Windows calls, in one table so tests can replace each one.
    [CmdletBinding()]
    param()

    return @{
        # Name -> StartMode (Auto, Manual, Disabled) for the services that exist.
        GetServices     = {
            param([string[]] $Names)
            $map = @{}
            foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) { if ($Names -contains $s.Name) { $map[$s.Name] = [string]$s.StartMode } }
            $map
        }
        # Returns sc.exe's exit code (0 = done, 5 = access denied).
        SetServiceStart = { param([string] $Name, [string] $Start) $null = & (Get-AfSystemToolPath 'sc.exe') config $Name start= $Start; $LASTEXITCODE }
        GetPolicy       = {
            param([string] $Path, [string] $Value)
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValue($Value, $null)
        }
        RemovePolicy    = { param([string] $Path, [string] $Value) Remove-ItemProperty -LiteralPath $Path -Name $Value -ErrorAction Stop }
        # $true when the app is installed for this account.
        HasApp          = { param([string] $Name) [bool]@(Get-AppxPackage -Name $Name -ErrorAction Stop).Count }
        # The app's folder on this PC (installed for another account or left on disk), or $null. Needs admin.
        FindApp         = {
            param([string] $Name)
            $p = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.InstallLocation -and (Test-Path -LiteralPath (Join-Path $_.InstallLocation 'AppxManifest.xml')) }) |
                Sort-Object Version | Select-Object -Last 1
            if ($p) { $p.InstallLocation } else { $null }
        }
        RegisterApp     = { param([string] $Folder) Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $Folder 'AppxManifest.xml') -ErrorAction Stop }
        ReadHosts       = { if (Test-Path -LiteralPath $script:AfHostsPath) { @(Get-Content -LiteralPath $script:AfHostsPath -ErrorAction Stop) } else { @() } }
        WriteHosts      = { param([string[]] $Lines) [IO.File]::WriteAllLines($script:AfHostsPath, $Lines) }
        # Copies the hosts file next to the logs; returns the copy's path.
        BackupHosts     = {
            param([string] $OutputRoot)
            $copy = '{0}.txt' -f (New-AfLogStem -OutputRoot $OutputRoot -Kind 'hosts-backup' -Extension 'txt')
            Copy-Item -LiteralPath $script:AfHostsPath -Destination $copy -ErrorAction Stop
            $copy
        }
        # $true on a domain or Entra joined PC, $false on a home PC, $null when Windows can't tell.
        IsManaged       = { $j = Get-AfDeviceJoinState; if ($null -eq $j) { $null } else { $j.AzureAd -or $j.Domain } }
        IsAdmin         = { Test-AfIsAdmin }
        RestorePoint    = { New-AfRestorePoint -Description 'Auto-Fixer: before putting back Windows defaults' }
    }
}

function Get-AfDebloatFinding {
    <#
    .SYNOPSIS
        The read-only check. Returns findings: Area, Name, Detail, Fixable, Change (the
        exact change, in words) and the fields the fix needs. Changes nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Ops, [bool] $IsAdmin = $true)

    $managed = & $Ops.IsManaged
    $new = { param($Area, $Name, $Detail, $Fixable, $Change, $Data) [pscustomobject]@{ Area = $Area; Name = $Name; Detail = $Detail; Fixable = [bool]$Fixable; Change = $Change; Data = $Data } }

    $modes = & $Ops.GetServices @($script:AfDebloatServices.Name + 'DiagTrack')
    foreach ($s in $script:AfDebloatServices) {
        if (-not $modes.ContainsKey($s.Name)) {
            & $new 'Service' $s.What ('{0} is missing from this PC. Auto-Fixer cannot add a service back; try Repair Windows files (DISM RestoreHealth), or a Windows repair install.' -f $s.Name) $false $null $null
        }
        elseif ($modes[$s.Name] -eq 'Disabled') {
            $word = @{ 'demand' = 'Manual'; 'delayed-auto' = 'Automatic (delayed start)'; 'auto' = 'Automatic' }[$s.Start]
            & $new 'Service' $s.What ('{0} is Disabled; the Windows default is {1}.' -f $s.Name, $word) $true ('Set service {0} to {1} (sc.exe config {0} start= {2})' -f $s.Name, $word, $s.Start) $s
        }
    }
    if ($modes['DiagTrack'] -eq 'Disabled') {
        & $new 'Info' 'Connected User Experiences and Telemetry' 'DiagTrack is Disabled. This is a privacy choice and does not break updates, so Auto-Fixer leaves it as it is.' $false $null $null
    }

    foreach ($p in $script:AfDebloatPolicies) {
        $value = & $Ops.GetPolicy $p.Path $p.Value
        if ($null -eq $value -or [string]$value -ne [string]$p.Bad) { continue }
        $where = '{0}\{1} = {2}' -f ($p.Path -replace '^HKLM:', 'HKLM'), $p.Value, $value
        if ($p.InfoOnly) { & $new 'Info' $p.What ('{0}. A privacy choice; left as it is.' -f $where) $false $null $null }
        elseif ($managed -eq $true) { & $new 'Policy' $p.What ('{0}. This is a work PC, so your organization may have set it on purpose. Ask your IT team; Auto-Fixer leaves it.' -f $where) $false $null $null }
        else { & $new 'Policy' $p.What $where $true ('Remove the policy value {0}' -f $where) $p }
    }

    foreach ($a in $script:AfDebloatApps) {
        if (& $Ops.HasApp $a.Name) { continue }
        $folder = $null
        if ($IsAdmin) { $folder = & $Ops.FindApp $a.Name }
        if ($folder) { & $new 'Store' $a.What ('{0} is not installed for this account, but its files are still on this PC.' -f $a.Name) $true ('Register {0} again from {1}' -f $a.Name, $folder) @{ Name = $a.Name; Folder = $folder } }
        else { & $new 'Store' $a.What ('{0} is not installed for this account and its files were not found. To get it back: run wsreset -i (downloads it from Microsoft), or Repair Windows files.' -f $a.Name) $false $null $null }
    }

    $hits = @(Get-AfDebloatHostsLine -Lines (& $Ops.ReadHosts))
    if ($hits.Count) {
        $names = @($hits | ForEach-Object { $_.Names }) | Select-Object -Unique
        & $new 'Hosts' 'Hosts file blocks Windows Update or the Store' ('{0} line(s) in the hosts file block: {1}' -f $hits.Count, ($names -join ', ')) $true ('Back up the hosts file, then turn {0} blocking line(s) into comments' -f $hits.Count) @{ Lines = $hits }
    }
}

function Invoke-AfDebloatItemFix {
    # Puts one finding back and reads it back. Returns Tag (OK or FAILED) and Detail.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Finding, [Parameter(Mandatory)] [hashtable] $Ops, [Parameter(Mandatory)] [string] $OutputRoot)

    $d = $Finding.Data
    try {
        switch ($Finding.Area) {
            'Service' {
                $code = & $Ops.SetServiceStart $d.Name $d.Start
                $now = (& $Ops.GetServices @($d.Name))[$d.Name]
                if ($now -and $now -ne 'Disabled') { return [pscustomobject]@{ Tag = 'OK'; Detail = ('{0} is now {1}. It starts when Windows needs it, or after a restart.' -f $d.Name, $now) } }
                $why = @{ 5 = ' (access denied: Windows protects this service; a Windows repair install puts it back)' }[[int]$code]
                return [pscustomobject]@{ Tag = 'FAILED'; Detail = ('{0} is still Disabled. sc.exe exit code {1}{2}.' -f $d.Name, $code, $why) }
            }
            'Policy' {
                & $Ops.RemovePolicy $d.Path $d.Value
                if ($null -eq (& $Ops.GetPolicy $d.Path $d.Value)) { return [pscustomobject]@{ Tag = 'OK'; Detail = ('Policy value {0} removed. Windows uses its default again.' -f $d.Value) } }
                return [pscustomobject]@{ Tag = 'FAILED'; Detail = ('Policy value {0} is still there. Group Policy or management software may set it again.' -f $d.Value) }
            }
            'Store' {
                & $Ops.RegisterApp $d.Folder
                if (& $Ops.HasApp $d.Name) { return [pscustomobject]@{ Tag = 'OK'; Detail = ('{0} is registered again for this account.' -f $d.Name) } }
                return [pscustomobject]@{ Tag = 'FAILED'; Detail = ('{0} still does not show for this account.' -f $d.Name) }
            }
            'Hosts' {
                $copy = & $Ops.BackupHosts $OutputRoot
                $lines = [System.Collections.Generic.List[string]]::new()
                foreach ($l in @(& $Ops.ReadHosts)) { $lines.Add([string]$l) }
                foreach ($h in $d.Lines) { if ($h.Index -lt $lines.Count -and $lines[$h.Index] -eq $h.Line) { $lines[$h.Index] = '# Auto-Fixer put back: ' + $h.Line } }
                & $Ops.WriteHosts $lines.ToArray()
                $left = @(Get-AfDebloatHostsLine -Lines (& $Ops.ReadHosts))
                if (-not $left.Count) { return [pscustomobject]@{ Tag = 'OK'; Detail = ('Blocking lines are now comments. Backup: {0}' -f $copy) } }
                return [pscustomobject]@{ Tag = 'FAILED'; Detail = ('{0} blocking line(s) are still active (the file may have changed, or security software restored it). Backup: {1}' -f $left.Count, $copy) }
            }
        }
        return [pscustomobject]@{ Tag = 'FAILED'; Detail = 'Nothing to put back for this item.' }
    }
    catch { return [pscustomobject]@{ Tag = 'FAILED'; Detail = ('The change failed: {0}' -f $_.Exception.Message) } }
}

function Invoke-AfDebloatFix {
    <#
    .SYNOPSIS
        Debloat damage check: the read-only check, then each item that can be put back
        asks Y/N, with a restore point offered first. Returns Tag (OK, FAILED,
        CANCELLED, NOTHING) and the counts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [hashtable] $Ops = (Get-AfDebloatOps),
        $Redactor = (New-AfRedactor)
    )

    $show = { param([string] $Text) Protect-AfText -Redactor $Redactor -Text $Text }
    $isAdmin = [bool](& $Ops.IsAdmin)
    Write-Host ''
    Write-Host '  Debloat damage check (read-only)' -ForegroundColor Cyan
    Write-Host '  Looks for update and Store services turned off, blocking policies, a missing' -ForegroundColor DarkGray
    Write-Host '  Microsoft Store and hosts-file blocks: things "debloat" tools often leave behind.' -ForegroundColor DarkGray
    Write-Host ''

    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'debloat' -Redactor $Redactor -Task 'debloat damage check'
    $log = { param([string] $Text) Write-AfToolLog $toolLog $Text }
    & $log ('Mode      : {0}; admin {1}' -f $Settings.Mode, @{ $true = 'yes'; $false = 'no' }[$isAdmin])

    $findings = @(Get-AfDebloatFinding -Ops $Ops -IsAdmin $isAdmin)
    $fixable = @($findings | Where-Object Fixable)
    foreach ($f in $findings) {
        $tag = @{ $true = 'FOUND'; $false = 'INFO' }[$f.Fixable]
        Write-Host ('  {0,-7}{1}' -f $tag, $f.Name) -ForegroundColor @{ $true = 'Yellow'; $false = 'Gray' }[$f.Fixable]
        Write-Host ('         {0}' -f (& $show $f.Detail)) -ForegroundColor DarkGray
        & $log ('{0,-7}{1}: {2}' -f $tag, $f.Name, $f.Detail)
    }
    $result = [pscustomobject]@{ Tag = 'NOTHING'; Found = $fixable.Count; Fixed = 0; Failed = 0; LogPath = $toolLog.Path }
    if (-not $fixable.Count) {
        Write-Host ('  OK     Nothing to put back. {0} services, {1} policies, the Store and the hosts file look like Windows defaults.' -f $script:AfDebloatServices.Count, $script:AfDebloatPolicies.Count) -ForegroundColor Green
        & $log 'Result  : nothing to put back.'
        Write-Host ('  Log: {0}' -f (& $show $toolLog.Path)) -ForegroundColor DarkGray
        return $result
    }
    if (-not $isAdmin) {
        Write-Host ''
        Write-Host '  Putting these back needs administrator rights. Start Auto-Fixer with AutoFix.bat and say Yes to the Windows prompt.' -ForegroundColor Yellow
        & $log 'Result  : not admin, nothing changed.'
        $result.Tag = 'CANCELLED'
        return $result
    }

    Write-Host ''
    Write-Host ('  {0} item(s) can be put back to the Windows default. Each one asks Y/N:' -f $fixable.Count) -ForegroundColor White
    foreach ($f in $fixable) { Write-Host ('    - {0}' -f (& $show $f.Change)) }
    Write-Host ''
    if ((Read-AfYesNo -Prompt 'Go through them now?' -ReadKey $ReadKey) -ne $true) {
        Write-Host '  Nothing was changed.' -ForegroundColor Yellow
        & $log 'Result  : cancelled, nothing changed.'
        $result.Tag = 'CANCELLED'
        return $result
    }

    # A restore point first (raven575's rule: Technician gets a warning and goes on; Standard is asked).
    Write-Host '  Making a restore point first...' -ForegroundColor DarkGray
    $point = & $Ops.RestorePoint
    if ($point.Ok) { Write-Host '  OK     Restore point made.' -ForegroundColor Green; & $log 'OK     Restore point made.' }
    else {
        Write-Host ('  WARN   No restore point: {0}' -f $point.Reason) -ForegroundColor Yellow
        & $log ('WARN   No restore point: {0}' -f $point.Reason)
        if ($Settings.Mode -ne 'Technician' -and (Read-AfYesNo -Prompt 'Continue without a restore point?' -ReadKey $ReadKey) -ne $true) {
            Write-Host '  Nothing was changed.' -ForegroundColor Yellow
            & $log 'Result  : stopped without a restore point, nothing changed.'
            $result.Tag = 'CANCELLED'
            return $result
        }
    }

    foreach ($f in $fixable) {
        Write-Host ''
        Write-Host ('  {0}' -f $f.Name) -ForegroundColor White
        Write-Host ('  Change: {0}' -f (& $show $f.Change)) -ForegroundColor DarkGray
        if ((Read-AfYesNo -Prompt 'Put this back?' -ReadKey $ReadKey) -ne $true) {
            Write-Host '  Skipped.' -ForegroundColor Yellow
            & $log ('SKIPPED {0} (user said No)' -f $f.Name)
            continue
        }
        & $log ('Change  : {0}' -f $f.Change)
        $r = Invoke-AfDebloatItemFix -Finding $f -Ops $Ops -OutputRoot $OutputRoot
        if ($r.Tag -eq 'OK') { $result.Fixed++ } else { $result.Failed++ }
        Write-Host ('  {0,-7}{1}' -f $r.Tag, (& $show $r.Detail)) -ForegroundColor @{ $true = 'Green'; $false = 'Red' }[$r.Tag -eq 'OK']
        & $log ('{0,-7}{1}' -f $r.Tag, $r.Detail)
    }

    $result.Tag = @{ $true = 'OK'; $false = 'FAILED' }[$result.Failed -eq 0]
    Write-Host ''
    Write-Host ('  Done: {0} put back, {1} failed, {2} skipped.' -f $result.Fixed, $result.Failed, ($fixable.Count - $result.Fixed - $result.Failed)) -ForegroundColor White
    if ($result.Fixed) { Write-Host '  Restart the PC, then try Windows Update or the Store again.' -ForegroundColor Yellow }
    & $log ('Result  : {0} put back, {1} failed' -f $result.Fixed, $result.Failed)
    Write-Host ('  Log: {0}' -f (& $show $toolLog.Path)) -ForegroundColor DarkGray
    return $result
}
