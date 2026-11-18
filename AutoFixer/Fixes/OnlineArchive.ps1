# Office and Outlook > Online Archive (TEAM 9to5's Online Archive tool, WORK-0038, rewritten).
# Classic Outlook only. One window moves old mail to the Microsoft 365 Online Archive (Push),
# moves it back (Undo), copies a PST's mail into the archive (Import a PST) and shows this
# mailbox's archive (Status). It drives Outlook through COM, so it must run as the signed-in
# Windows user with normal rights. Auto-Fixer runs as admin, so this file also starts the
# window for that user: a temporary scheduled task (Interactive, Limited rights), removed
# afterwards. Nothing in the mailbox is deleted; every move is logged and can be undone.
# The window itself is in OnlineArchiveWindow.ps1. The helpers here hold the logic tests check.

# Exit codes the window returns. 0 and 1 are normal endings; 2 to 4 say why nothing (more) ran.
$script:AfArchiveExit = [ordered]@{
    0 = 'Done: every change was checked and found where it should be (or nothing was changed).'
    1 = 'Done with warnings: see the result lines. Nothing was deleted; Undo still works.'
    2 = 'Stopped by the user: items not reached stay where they were.'
    3 = 'Could not start: classic Outlook is not open, or this mailbox has no Online Archive.'
    4 = 'Failed: the window could not run. See the log.'
}

# Default Outlook folder names that are safe to show in a result (other folder names can be personal).
$script:AfArchiveKnownFolders = @('Inbox', 'Sent Items', 'Deleted Items', 'Archive', 'Junk Email', 'Drafts', 'Conversation History')

function Get-AfArchiveExitText {
    # One line for an exit code: '0 = Done: ...'. Unknown codes say so plainly.
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Code)
    $text = $script:AfArchiveExit[[int]$Code]
    if (-not $text) { $text = 'Unknown result code.' }
    '{0} = {1}' -f $Code, $text
}

function Get-AfArchiveRelPath {
    <#
    .SYNOPSIS
        Outlook's FolderPath '\\Mailbox name\Inbox\Clients' without the mailbox part: 'Inbox\Clients'.
        The mailbox root itself gives ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $FolderPath)
    $p = ([string]$FolderPath).TrimStart('\')
    $i = $p.IndexOf('\')
    if ($i -lt 0) { return '' }
    $p.Substring($i + 1)
}

function Get-AfArchiveFolderLabel {
    <#
    .SYNOPSIS
        A result label that never shows a personal folder name: '[2] Inbox\..' or '[3] Folder'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Index, [AllowEmptyString()] [string] $RelPath)
    $top = ([string]$RelPath -split '\\')[0]
    $t = 'Folder'
    if ($script:AfArchiveKnownFolders -contains $top) { $t = $top }
    if ($RelPath -ne $top) { $t += '\..' }
    '[{0}] {1}' -f $Index, $t
}

function Test-AfArchivePick {
    <#
    .SYNOPSIS
        True when one mail item should move: received before the cut-off, and not skipped
        for being unread or flagged (Outlook FlagStatus 2 = flagged).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] $Received,
        [Parameter(Mandatory)] [datetime] $Cutoff,
        [bool] $UnRead,
        [int] $FlagStatus,
        [bool] $SkipUnread,
        [bool] $SkipFlagged
    )
    if ($null -eq $Received -or -not ([datetime]$Received -lt $Cutoff)) { return $false }
    if ($SkipUnread -and $UnRead) { return $false }
    if ($SkipFlagged -and $FlagStatus -eq 2) { return $false }
    $true
}

function Get-AfArchiveHash12 {
    # First 12 hex characters of SHA-256: enough to match one email, and it cannot be read back.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (-join @($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 12) }
    finally { $sha.Dispose() }
}

function Get-AfArchiveMessageKey {
    <#
    .SYNOPSIS
        The same email in the PST and in the archive gives the same key. Uses the Internet
        message id when there is one, else the received time plus the subject. Both are hashed,
        so the inventory file holds no subjects or addresses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $MessageId, [AllowNull()] $Received, [AllowEmptyString()] [string] $Subject)
    if ($MessageId -and $MessageId.Trim()) { return 'M' + (Get-AfArchiveHash12 $MessageId.Trim()) }
    $when = 'nodate'
    if ($Received) { $when = ([datetime]$Received).ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture) }
    'T' + $when + (Get-AfArchiveHash12 ([string]$Subject))
}

function Compare-AfArchiveInventory {
    <#
    .SYNOPSIS
        Matches every planned key to one found key (a key that appears twice must be found twice).
        Returns Found, Missing and the received times of the missing ones.
    #>
    [CmdletBinding()]
    param([object[]] $Planned = @(), [string[]] $Found = @())
    $have = @{}
    foreach ($k in $Found) { $have[$k] = 1 + [int]$have[$k] }
    $hit = 0; $missing = New-Object System.Collections.ArrayList
    foreach ($p in $Planned) {
        if ([int]$have[$p.Key] -gt 0) { $have[$p.Key]--; $hit++ }
        else { [void]$missing.Add([string]$p.Received) }
    }
    [pscustomobject]@{ Planned = @($Planned).Count; Found = $hit; Missing = $missing.Count; MissingReceived = @($missing.ToArray()) }
}

function Get-AfArchiveUndoState {
    # 'not undone', 'undone (all back)' or 'partly undone (N back)' for one push or import log.
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Moved, [int] $Back)
    if (-not $Back) { return 'not undone' }
    if ($Back -ge $Moved) { return 'undone (all back)' }
    'partly undone ({0} back)' -f $Back
}

function Get-AfArchiveLaunchPlan {
    <#
    .SYNOPSIS
        How Auto-Fixer starts the window. Outlook runs as the signed-in user with normal rights,
        and an admin process cannot talk to it, so:
          Direct  - Auto-Fixer itself runs without admin rights: start the window as this user.
          Task    - Auto-Fixer runs as admin: a temporary scheduled task starts the window as
                    the signed-in console user, with Limited (normal) rights, then is removed.
                    This also works when the admin is a different account from the Outlook user.
          Stop    - nobody is signed in at the console, or classic Outlook is not running.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $ConsoleUser,
        [bool] $IsAdmin,
        [bool] $ClassicRunning,
        [bool] $NewRunning
    )
    if (-not $ClassicRunning) {
        $why = 'Classic Outlook is not open. Open classic Outlook for the user, then try again.'
        if ($NewRunning) { $why = 'Only New Outlook is open. This needs classic Outlook (New Outlook cannot do this). Open classic Outlook, then try again.' }
        return [pscustomobject]@{ Action = 'Stop'; Reason = $why }
    }
    if (-not $IsAdmin) { return [pscustomobject]@{ Action = 'Direct'; Reason = 'Auto-Fixer runs with normal rights, so the window opens here as this user.' } }
    if (-not $ConsoleUser) { return [pscustomobject]@{ Action = 'Stop'; Reason = 'Nobody is signed in at this PC''s screen, so there is no Outlook to use.' } }
    [pscustomobject]@{ Action = 'Task'; Reason = 'Auto-Fixer runs as admin, so a temporary scheduled task opens the window as the signed-in user with normal rights, then is removed.' }
}

function New-AfArchiveStartScript {
    <#
    .SYNOPSIS
        The text of the small script the user-side PowerShell runs: load Auto-Fixer from
        -ModulePath, open the window, save the result to -ResultPath and exit with its code.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ModulePath, [Parameter(Mandatory)] [string] $ResultPath)
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    @(
        '# Auto-Fixer: opens the Online Archive window for this user. Made and removed by Auto-Fixer.'
        '$ErrorActionPreference = ''Stop'''
        '$code = 4'
        ('try {{ Import-Module {0} -Force; $code = & (Get-Module AutoFixer) {{ param($r) Start-AfOnlineArchiveWindow -ResultPath $r }} {1} }}' -f (& $q $ModulePath), (& $q $ResultPath))
        ('catch {{ try {{ @{{ ExitCode = 4; Lines = @(''Online Archive window failed: '' + $_.Exception.Message) }} | ConvertTo-Json | Set-Content -LiteralPath {0} -Encoding UTF8 }} catch {{ $null = $_ }} }}' -f (& $q $ResultPath))
        'exit $code'
    ) -join "`r`n"
}

function Get-AfArchiveTaskArgument {
    # powershell.exe arguments for the start script: STA for the window, console hidden.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $ScriptPath)
    '-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath
}

function Read-AfArchiveResult {
    # The result the window saved: ExitCode and Lines. A missing or broken file reads as code 4.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $r = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Lines = @($r.Lines | ForEach-Object { [string]$_ }) }
    }
    catch { return [pscustomobject]@{ ExitCode = 4; Lines = @('No result came back from the window.') } }
}

function Get-AfConsoleUser {
    # DOMAIN\user signed in at the PC's screen, or '' when nobody is.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
}

function Test-AfIsAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-AfArchiveDirect {
    # Not admin: run the window in a new STA PowerShell as this user and wait for it.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [string] $ScriptPath)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-AfArchiveTaskArgument -ScriptPath $ScriptPath) -PassThru -ErrorAction Stop
    $t0 = Get-Date
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 2
        Write-Host ("`r  Online Archive window is open: {0:hh\:mm\:ss}. Close it to come back here. " -f ((Get-Date) - $t0)) -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''
    [int]$p.ExitCode
}

function Start-AfArchiveTask {
    <#
    .SYNOPSIS
        Admin: registers a temporary task that runs the start script as -User (Interactive,
        Limited rights), starts it, waits until the window closes, then removes the task.
        Returns the task's last result code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [string] $ScriptPath, [Parameter(Mandatory)] [string] $User, [Parameter(Mandatory)] [string] $TaskName)
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-AfArchiveTaskArgument -ScriptPath $ScriptPath)
    $prn = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 8) -MultipleInstances IgnoreNew
    try {
        $null = Register-ScheduledTask -TaskName $TaskName -Action $act -Principal $prn -Settings $set -Force -ErrorAction Stop
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $t0 = Get-Date
        do {
            Start-Sleep -Seconds 2
            $state = [string](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
            $el = (Get-Date) - $t0
            Write-Host ("`r  Online Archive window is open for the signed-in user: {0:hh\:mm\:ss}. Close it to come back here. " -f $el) -NoNewline -ForegroundColor DarkGray
        } while ($state -eq 'Running' -or $el.TotalSeconds -lt 6)
        Write-Host ''
        return [int](Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue).LastTaskResult
    }
    finally {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Write-Host ('  Temporary task NOT removed: {0}. Remove it in Task Scheduler.' -f $TaskName) -ForegroundColor Yellow
        }
        else { Write-Host '  Temporary task removed.' -ForegroundColor DarkGray }
    }
}

function Invoke-AfOnlineArchive {
    <#
    .SYNOPSIS
        Office and Outlook > Online Archive. Explains, checks, asks Y/N, opens the window for the
        signed-in user, then shows and logs the window's result with its exit code. Returns the code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfKey },
        $Redactor = (New-AfRedactor),
        [scriptblock] $GetState = { Get-AfClassicOutlookState },
        [scriptblock] $GetConsoleUser = { Get-AfConsoleUser },
        [scriptblock] $IsAdmin = { Test-AfIsAdmin },
        # Called with the start script path (and the user for Task); returns the process or task code.
        [scriptblock] $RunDirect = { param($ScriptPath) Start-AfArchiveDirect -ScriptPath $ScriptPath },
        [scriptblock] $RunTask = { param($ScriptPath, $User, $TaskName) Start-AfArchiveTask -ScriptPath $ScriptPath -User $User -TaskName $TaskName },
        [string] $WorkRoot = $(if ($env:ProgramData) { Join-Path $env:ProgramData 'AutoFixer\OnlineArchive-run' } else { Join-Path ([IO.Path]::GetTempPath()) 'AutoFixer-OnlineArchive-run' })
    )

    $screenRedactor = $Redactor
    if ($Settings.ShowSensitive) { $screenRedactor = New-AfRedactor -Disabled }
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'archive' -Redactor $Redactor -Task 'Office and Outlook > Online Archive'
    $say = {
        param([string] $Text, [string] $Color = 'Gray')
        Write-Host ('  {0}' -f (Protect-AfText -Redactor $screenRedactor -Text $Text)) -ForegroundColor $Color
        Write-AfToolLog $toolLog $Text
    }

    Write-Host ''
    & $say 'Online Archive (classic Outlook, Microsoft 365)' 'White'
    & $say 'Opens a window for the signed-in user. In it you can:'
    & $say '  Push    : move mail older than a date to the same folders in the Online Archive.'
    & $say '  Undo    : move a push back, or move a PST import to the archive''s Deleted Items.'
    & $say '  Import  : back up a PST, then copy its mail into the Online Archive.'
    & $say '  Status  : this mailbox''s archive and sizes (read from Outlook).'
    & $say 'Every change previews first and asks Yes in the window. Nothing in the mailbox is deleted.'
    & $say 'Every move is logged in the user''s own folder and can be undone. Internet: only Outlook''s own sync.'

    $state = & $GetState
    $admin = [bool](& $IsAdmin)
    $user = [string](& $GetConsoleUser)
    $plan = Get-AfArchiveLaunchPlan -ConsoleUser $user -IsAdmin $admin -ClassicRunning ([bool]$state.ClassicRunning) -NewRunning ([bool]$state.NewRunning)
    & $say ('How it opens: {0}' -f $plan.Reason) 'DarkGray'
    if ($plan.Action -eq 'Stop') {
        & $say ('Result: {0}' -f (Get-AfArchiveExitText 3)) 'Yellow'
        & $say $plan.Reason 'Yellow'
        Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
        return 3
    }
    if ($plan.Action -eq 'Task') {
        & $say 'Changes system: a temporary scheduled task and a temporary copy of Auto-Fixer in ProgramData, both removed afterwards.' 'Yellow'
    }
    if (-not (Read-AfYesNo -Prompt 'Open the Online Archive window?' -ReadKey $ReadKey)) {
        & $say 'Nothing was opened or changed.'
        return 0
    }

    # Without admin rights the window's files go in this user's own temp folder.
    if ($plan.Action -eq 'Direct' -and -not $PSBoundParameters.ContainsKey('WorkRoot')) { $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'AutoFixer-OnlineArchive-run' }
    $stamp = Get-AfLogStamp
    $run = Join-Path $WorkRoot $stamp
    $code = 4
    $result = $null
    try {
        $null = New-Item -ItemType Directory -Path $run -Force -ErrorAction Stop
        $modulePath = Join-Path $script:AfModuleRoot 'AutoFixer.psd1'
        if ($plan.Action -eq 'Task') {
            # The user may not be able to read the admin's folder, so the window runs from a copy.
            Copy-Item -LiteralPath $script:AfModuleRoot -Destination $run -Recurse -Force -ErrorAction Stop
            $modulePath = Join-Path $run 'AutoFixer\AutoFixer.psd1'
            # The user-side run writes its result here (the folder was made by an admin).
            $null = & icacls.exe $run /grant ('{0}:(OI)(CI)M' -f $user) /Q
        }
        $resultPath = Join-Path $run 'result.json'
        $scriptPath = Join-Path $run 'start.ps1'
        Set-Content -LiteralPath $scriptPath -Value (New-AfArchiveStartScript -ModulePath $modulePath -ResultPath $resultPath) -Encoding ASCII -ErrorAction Stop
        Write-AfToolLog $toolLog ('Opened: {0}' -f $plan.Action)
        if ($plan.Action -eq 'Task') { $null = & $RunTask $scriptPath $user ('AutoFixer-OnlineArchive-{0}' -f $stamp) }
        else { $null = & $RunDirect $scriptPath }
        $result = Read-AfArchiveResult -Path $resultPath
        $code = $result.ExitCode
    }
    catch {
        $result = [pscustomobject]@{ ExitCode = 4; Lines = @('Could not open the window: ' + $_.Exception.Message) }
        $code = 4
    }
    finally {
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $run) { Write-Host ('  Temporary folder NOT removed: {0}' -f $run) -ForegroundColor Yellow }
    }

    Write-Host ''
    $color = @{ 0 = 'Green'; 1 = 'Yellow'; 2 = 'Yellow'; 3 = 'Yellow'; 4 = 'Red' }[$code]
    if (-not $color) { $color = 'Red' }
    foreach ($line in $result.Lines) { & $say $line }
    & $say ('Result: {0}' -f (Get-AfArchiveExitText $code)) $color
    Write-Host ('  Log: {0}' -f (Protect-AfText -Redactor $Redactor -Text $toolLog.Path)) -ForegroundColor DarkGray
    return $code
}
