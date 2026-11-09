# Purview PST Import (WORK-0033, TEAM 9to5 scripts 11-15, rewritten). Puts PST copies into a
# user's Online Archive through Microsoft Purview's network upload. Technician only.
# The guide and the mapping file use stock Windows. The other steps are ONLINE ADD-ONS: they
# need the Exchange Online module or Microsoft AzCopy and internet, and run only when
# Settings > Online add-ons is on. Every download asks Y/N first. The upload link (SAS URL)
# works like a password: it is read hidden, never shown, never logged and never saved.
# Source: Microsoft Learn "Use network upload to import PST files".

$script:AfPurviewWork = Join-Path ($env:SystemDrive + '\') 'PSTImport'
$script:AfPurviewRoleGroup = 'PST Import - temp'
$script:AfAzCopyUrl = 'https://aka.ms/downloadazcopy-v10-windows'
$script:AfEmailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'

function Test-AfSasUrl {
    # A Purview network upload link: https://<name>.blob.core.windows.net/ingestiondata...?...sig=...
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Url)
    return ([bool]($Url -match '^https://[a-z0-9]+\.blob\.core\.windows\.net/ingestiondata[/?][^\s]*[?&]sig=[^&\s]+'))
}

function Read-AfPstHashList {
    # hashes-sha256.txt from Back up PSTs: "<hash>  <file>" per line. Returns file -> hash.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Path)
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^([0-9A-Fa-f]{64})\s+(.+)$') { $map[$Matches[2].Trim()] = $Matches[1].ToUpperInvariant() }
        }
    }
    return $map
}

function Get-AfUniquePst {
    <#
    .SYNOPSIS
        Splits PST files into Keep and Duplicates by SHA-256, so the same mail is not imported
        twice. The first file of each hash (by name) is kept. -GetHash gets a file, returns its hash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Files,
        [scriptblock] $GetHash = { param($File) (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash }
    )
    # Plain arrays: a generic List inside a pscustomobject throws "Argument types do not match".
    $seen = @{}
    $keep = @()
    $dup = @()
    foreach ($f in @($Files | Sort-Object Name)) {
        $h = [string](& $GetHash $f)
        if ($seen.ContainsKey($h)) { $dup += $f } else { $seen[$h] = $true; $keep += $f }
    }
    return [pscustomobject]@{ Keep = $keep; Duplicates = $dup }
}

function New-AfPstMappingCsv {
    <#
    .SYNOPSIS
        The Purview mapping file: one row per PST, into the Online Archive, each in its own
        Imported-<name> folder. FilePath is the backup folder's name, as AzCopy uploads it.
        Throws when a file name has a comma or semicolon (the CSV and AzCopy would split it).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $FolderName,
        [Parameter(Mandatory)] [string[]] $FileName,
        [Parameter(Mandatory)] [string] $Mailbox
    )
    $bad = @($FileName | Where-Object { $_ -match '[,;]' })
    if ($bad.Count) { throw ('A file name has a comma or semicolon. Rename the copy in the backup folder first: {0}' -f ($bad -join ' | ')) }
    $lines = @('Workload,FilePath,Name,Mailbox,IsArchive,TargetRootFolder,ContentCodePage,SPFileContainer,SPManifestContainer,SPSiteUrl')
    foreach ($n in $FileName) {
        $lines += 'Exchange,{0},{1},{2},TRUE,/Imported-{3},,,,' -f $FolderName, $n, $Mailbox, [IO.Path]::GetFileNameWithoutExtension($n)
    }
    return $lines
}

function Get-AfNewestPstBackup {
    # The newest PSTBackup-* folder on the system drive, made by Back up PSTs.
    [CmdletBinding()]
    param([string] $Root = ($env:SystemDrive + '\'))
    return (Get-ChildItem -LiteralPath $Root -Directory -Filter 'PSTBackup-*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1)
}

function Get-AfMailboxKey {
    # Ties the saved "before" values to one mailbox without saving the address.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Mailbox)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Mailbox.Trim().ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') })) }
    finally { $sha.Dispose() }
}

function Confirm-AfDownload {
    # Announces one download or online step and asks Y/N. Returns $true only on Y.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $What, [Parameter(Mandatory)] [string] $Where, [scriptblock] $ReadKey = { Read-AfMenuKey })
    Write-Host ''
    Write-Host ('  Online add-on: {0}' -f $What) -ForegroundColor Yellow
    Write-Host ('  Connects to: {0}' -f $Where) -ForegroundColor Yellow
    return ((Read-AfYesNo -Prompt 'Go ahead?' -ReadKey $ReadKey) -eq $true)
}

function Connect-AfExchange {
    <#
    .SYNOPSIS
        Online add-on: makes sure the Exchange Online module is here (offers to install it for this
        Windows user from the PowerShell Gallery), signs in as the tenant's admin and asks the
        technician to confirm the organization. Returns $true when signed in to the right one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([scriptblock] $ReadKey = { Read-AfMenuKey }, [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) })

    if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        Write-Host '  The Exchange Online module (ExchangeOnlineManagement, by Microsoft) is not on this PC.' -ForegroundColor Yellow
        if (-not (Confirm-AfDownload -What 'install the Exchange Online module for this Windows user only' -Where 'PowerShell Gallery (www.powershellgallery.com)' -ReadKey $ReadKey)) { return $false }
        try {
            # PowerShellGet may ask once more about the gallery; that question is its own.
            Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
            Import-Module ExchangeOnlineManagement -ErrorAction Stop
        }
        catch {
            Write-Host ('  Could not install it: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-Host '  Remove later with: Uninstall-Module ExchangeOnlineManagement' -ForegroundColor DarkGray
            return $false
        }
        Write-Host '  Installed. Remove later with: Uninstall-Module ExchangeOnlineManagement' -ForegroundColor DarkGray
    }

    $admin = [string](& $ReadText 'Admin sign-in (the tenant''s Microsoft 365 admin, not your own account)')
    if ($admin -notmatch $script:AfEmailPattern) { Write-Host '  That is not an email address. Nothing was changed.' -ForegroundColor Yellow; return $false }
    if (-not (Confirm-AfDownload -What 'sign in to Exchange Online (a Microsoft sign-in window opens)' -Where 'login.microsoftonline.com, outlook.office365.com' -ReadKey $ReadKey)) { return $false }
    Write-Host '  Sign-in: 1 = Microsoft sign-in window (password + 2FA, Windows Hello, key)' -ForegroundColor White
    Write-Host '           2 = web browser with a code (best for passkeys)' -ForegroundColor White
    $how = [string](& $ReadText 'Type 1 or 2 (Enter = 1)')
    $params = (Get-Command Connect-ExchangeOnline).Parameters
    $in = $false
    if ($how -ne '2') {
        try { Connect-ExchangeOnline -UserPrincipalName $admin -ShowBanner:$false -ErrorAction Stop; $in = $true }
        catch { Write-Host ('  The sign-in window did not finish: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
        if (-not $in -and $params.ContainsKey('DisableWAM')) {
            try { Connect-ExchangeOnline -UserPrincipalName $admin -ShowBanner:$false -DisableWAM -ErrorAction Stop; $in = $true }
            catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
        }
    }
    if (-not $in -and $params.ContainsKey('Device')) {
        Write-Host '  Open the link below in a browser, type the code, and sign in as the tenant''s admin.' -ForegroundColor White
        try { Connect-ExchangeOnline -Device -ShowBanner:$false -ErrorAction Stop; $in = $true }
        catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    if (-not $in) { Write-Host '  Could not sign in. Nothing was changed.' -ForegroundColor Red; return $false }
    # Shown here only, to make sure this is the right tenant. Never logged.
    $org = (Get-OrganizationConfig -ErrorAction SilentlyContinue).DisplayName
    Write-Host ('  Signed in. Organization: {0}' -f $org) -ForegroundColor White
    if ((Read-AfYesNo -Prompt 'Is this the right organization?' -ReadKey $ReadKey) -ne $true) {
        Disconnect-AfExchange
        Write-Host '  Signed out. Nothing was changed.' -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Disconnect-AfExchange {
    [CmdletBinding()]
    param()
    if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
        try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop | Out-Null }
        catch { Write-Verbose ('Disconnect: {0}' -f $_.Exception.Message) }
    }
}

function Read-AfMailboxAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param([scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) })
    $user = [string](& $ReadText 'The user''s email address (whose Online Archive gets the mail)')
    if ($user -notmatch $script:AfEmailPattern) { Write-Host '  That is not an email address. Nothing was changed.' -ForegroundColor Yellow; return $null }
    return $user.Trim()
}

function Invoke-AfPurviewPrecheck {
    # Online add-on, read-only: archive status and the two settings the import changes. Saves the
    # two "before" values in C:\PSTImport so After the import can put them back.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot, [scriptblock] $ReadKey = { Read-AfMenuKey }, [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) })

    if (-not (Connect-AfExchange -ReadKey $ReadKey -ReadText $ReadText)) { return }
    try {
        $user = Read-AfMailboxAddress -ReadText $ReadText
        if (-not $user) { return }
        $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'purview' -Redactor (New-AfRedactor) -Task 'Purview PST Import: pre-check (read-only)'
        $mb = Get-Mailbox -Identity $user -ErrorAction SilentlyContinue
        if (-not $mb) { Write-Host '  That mailbox is not in this organization. Nothing was changed.' -ForegroundColor Red; Write-AfToolLog $toolLog 'FAILED    mailbox not found'; return }
        $st = Get-EXOMailboxStatistics -Identity $user -Archive -ErrorAction SilentlyContinue
        $roles = @(Get-ManagementRoleAssignment -Role 'Mailbox Import Export' -ErrorAction SilentlyContinue)
        $lines = @(
            ('Online Archive       : {0}' -f $mb.ArchiveStatus)
            ('Archive size / items : {0} / {1}' -f $st.TotalItemSize, $st.ItemCount)
            ('Retention hold now   : {0} (the import turns it on; After the import puts it back)' -f $mb.RetentionHoldEnabled)
            ('Max receive size now : {0} (the import may raise it; After the import puts it back)' -f $mb.MaxReceiveSize)
            ('Import role assigned : {0} time(s)' -f $roles.Count)
        )
        foreach ($l in $lines) { Write-Host ('  {0}' -f $l); Write-AfToolLog $toolLog $l }
        if ($mb.ArchiveStatus -ne 'Active') { Write-Host '  The Online Archive must be Active first: Exchange admin center > mailbox > Others > Manage mailbox archive.' -ForegroundColor Yellow }
        $null = New-Item -ItemType Directory -Path $script:AfPurviewWork -Force
        [ordered]@{ mailboxKey = (Get-AfMailboxKey -Mailbox $user); retentionHoldEnabled = [bool]$mb.RetentionHoldEnabled; maxReceiveSize = [string]$mb.MaxReceiveSize; savedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:AfPurviewWork 'mailbox-before.json') -Encoding UTF8
        Write-Host '  Result: OK. Nothing was changed. The two "before" values are saved in C:\PSTImport.' -ForegroundColor Green
        Write-AfToolLog $toolLog 'Result: OK. Nothing was changed.'
    }
    finally { Disconnect-AfExchange }
}

function Invoke-AfPurviewRole {
    # Online add-on, CHANGE: gives only the signed-in admin the Mailbox Import Export role through
    # the role group "PST Import - temp". Undo: After the import, or Undo part 1.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot, [scriptblock] $ReadKey = { Read-AfMenuKey }, [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) })

    if (-not (Connect-AfExchange -ReadKey $ReadKey -ReadText $ReadText)) { return }
    try {
        $me = (Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1).UserPrincipalName
        $user = Get-User -Identity $me -ErrorAction SilentlyContinue
        $has = @(Get-ManagementRoleAssignment -Role 'Mailbox Import Export' -GetEffectiveUsers -ErrorAction SilentlyContinue | Where-Object { $user -and $_.EffectiveUserName -eq $user.Name })
        if ($has.Count) { Write-Host '  You already have Mailbox Import Export. Nothing to add.' -ForegroundColor Green; return }
        if (Get-RoleGroup -Identity $script:AfPurviewRoleGroup -ErrorAction SilentlyContinue) {
            Write-Host ('  The role group "{0}" exists but you are not in it. Stopping so nothing is guessed.' -f $script:AfPurviewRoleGroup) -ForegroundColor Yellow
            return
        }
        Write-Host ('  This adds the role group "{0}" with the Mailbox Import Export role, with only you in it.' -f $script:AfPurviewRoleGroup) -ForegroundColor White
        Write-Host '  Undo: After the import removes it, or Undo > 1.' -ForegroundColor DarkGray
        if ((Read-AfYesNo -Prompt 'Add the import role?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
        $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'purview' -Redactor (New-AfRedactor) -Task 'Purview PST Import: add import role'
        try {
            New-RoleGroup -Name $script:AfPurviewRoleGroup -Roles 'Mailbox Import Export' -Members $me -Description 'Temporary, for one PST import. Added by Auto-Fixer.' -ErrorAction Stop | Out-Null
            Write-Host '  Role group added. Microsoft can take a while to apply it: if Purview says you lack permission, wait and refresh.' -ForegroundColor Green
            Write-AfToolLog $toolLog 'Result: role group added.'
        }
        catch {
            Write-Host ('  Could not add it: {0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-AfToolLog $toolLog ('FAILED    {0}' -f $_.Exception.Message)
        }
    }
    finally { Disconnect-AfExchange }
}

function Get-AfAzCopy {
    # Online add-on: AzCopy from Microsoft into C:\PSTImport\azcopy, used only if Microsoft signed it.
    [CmdletBinding()]
    param([scriptblock] $ReadKey = { Read-AfMenuKey })

    $az = Get-ChildItem -LiteralPath $script:AfPurviewWork -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $az) {
        if (-not (Confirm-AfDownload -What 'download Microsoft AzCopy (one program, about 20 MB) into C:\PSTImport' -Where 'aka.ms and the Microsoft server it forwards to' -ReadKey $ReadKey)) { return $null }
        $zip = Join-Path $script:AfPurviewWork 'azcopy.zip'
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
            Invoke-WebRequest -Uri $script:AfAzCopyUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $script:AfPurviewWork 'azcopy') -Force -ErrorAction Stop
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
        catch { Write-Host ('  Download failed: {0}' -f $_.Exception.Message) -ForegroundColor Red; return $null }
        $az = Get-ChildItem -LiteralPath $script:AfPurviewWork -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $az) { Write-Host '  AzCopy was not found after the download.' -ForegroundColor Red; return $null }
    $sig = Get-AuthenticodeSignature -FilePath $az.FullName
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Write-Host '  AzCopy is not validly signed by Microsoft, so it will not run. Undo > 2 deletes it.' -ForegroundColor Red
        return $null
    }
    Write-Host '  AzCopy is signed by Microsoft.' -ForegroundColor Green
    return $az.FullName
}

function Invoke-AfPurviewPrepare {
    <#
    .SYNOPSIS
        Stock Windows, no download: finds the newest PSTBackup folder, skips duplicate PSTs (same
        SHA-256) and writes C:\PSTImport\pst-mapping.csv. Returns Folder, Keep, Duplicates, Csv.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [string] $Mailbox,
        [scriptblock] $GetBackup = { Get-AfNewestPstBackup },
        [string] $WorkFolder = $script:AfPurviewWork
    )

    $backup = & $GetBackup
    if (-not $backup) {
        Write-Host '  No PSTBackup-* folder was found. Run Office and Outlook > Back up PSTs first. Nothing was changed.' -ForegroundColor Yellow
        return $null
    }
    $files = @(Get-ChildItem -LiteralPath $backup.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.pst' })
    if (-not $files.Count) { Write-Host '  The backup folder has no PST files. Nothing was changed.' -ForegroundColor Yellow; return $null }
    if (-not $Mailbox) { $Mailbox = Read-AfMailboxAddress -ReadText $ReadText }
    if (-not $Mailbox) { return $null }

    $known = Read-AfPstHashList -Path (Join-Path $backup.FullName 'hashes-sha256.txt')
    $split = Get-AfUniquePst -Files $files -GetHash {
        param($File)
        if ($known.ContainsKey($File.Name)) { $known[$File.Name] } else { (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash }
    }.GetNewClosure()
    try { $csv = New-AfPstMappingCsv -FolderName $backup.Name -FileName @($split.Keep.Name) -Mailbox $Mailbox }
    catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red; return $null }
    $null = New-Item -ItemType Directory -Path $WorkFolder -Force
    $csvPath = Join-Path $WorkFolder 'pst-mapping.csv'
    $csv | Set-Content -LiteralPath $csvPath -Encoding ASCII

    $redactor = New-AfRedactor
    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'purview' -Redactor $redactor -Task 'Purview PST Import: mapping file (no download)'
    foreach ($d in $split.Duplicates) { Write-Host ('  Same mail as an earlier file, skipped: {0}' -f (Protect-AfText -Redactor $redactor -Text $d.Name)) -ForegroundColor Yellow }
    $summary = 'Result: {0} PST(s) to import, {1} duplicate(s) skipped. Mapping file: {2}' -f $split.Keep.Count, $split.Duplicates.Count, $csvPath
    Write-Host ('  {0}' -f $summary) -ForegroundColor Green
    Write-AfToolLog $toolLog $summary
    return [pscustomobject]@{ Folder = $backup.FullName; Keep = $split.Keep; Duplicates = $split.Duplicates; Csv = $csvPath }
}

function Invoke-AfPurviewUpload {
    # Online add-on: mapping file, AzCopy (download + signature check), hidden SAS URL, Y/N, upload.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        [scriptblock] $ReadSecret = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) -AsSecureString }
    )

    $prep = Invoke-AfPurviewPrepare -OutputRoot $OutputRoot -ReadText $ReadText
    if (-not $prep) { return }
    $azcopy = Get-AfAzCopy -ReadKey $ReadKey
    if (-not $azcopy) { return }

    Write-Host ''
    Write-Host '  The upload link (SAS URL) is in Purview: Data lifecycle management > Import > New import job >' -ForegroundColor White
    Write-Host '  Upload your data > Show network upload SAS URL. It works like a password: paste it only here.' -ForegroundColor White
    $secure = & $ReadSecret 'Paste the SAS URL (hidden)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $sas = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not (Test-AfSasUrl -Url $sas)) {
        $sas = $null
        Write-Host '  That is not a Purview upload link (https://...blob.core.windows.net/ingestiondata...sig=...). Nothing was uploaded.' -ForegroundColor Red
        return
    }
    $gb = ($prep.Keep | Measure-Object Length -Sum).Sum / 1GB
    if (-not (Confirm-AfDownload -What ('upload {0} PST copy(ies), {1:N2} GB, from the backup folder' -f $prep.Keep.Count, $gb) -Where 'Microsoft 365 import storage (<name>.blob.core.windows.net)' -ReadKey $ReadKey)) {
        $sas = $null
        Write-Host '  Nothing was uploaded.' -ForegroundColor Yellow
        return
    }

    $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'purview' -Redactor (New-AfRedactor) -Task 'Purview PST Import: upload PST copies'
    $env:AZCOPY_LOG_LOCATION = Join-Path $script:AfPurviewWork 'logs'
    $env:AZCOPY_JOB_PLAN_LOCATION = Join-Path $script:AfPurviewWork 'plans'
    & $azcopy copy $prep.Folder $sas --recursive=true --include-pattern (@($prep.Keep.Name) -join ';') --log-level ERROR
    $code = $LASTEXITCODE
    $sas = $null
    if ($code -ne 0) {
        Write-Host ('  AzCopy stopped with exit code {0}. Its log is in C:\PSTImport\logs.' -f $code) -ForegroundColor Red
        Write-AfToolLog $toolLog ('FAILED    AzCopy exit code {0}' -f $code)
        return
    }
    $summary = 'Result: uploaded {0} PST copy(ies), {1:N2} GB. Duplicates skipped: {2}.' -f $prep.Keep.Count, $gb, $prep.Duplicates.Count
    Write-Host ('  {0}' -f $summary) -ForegroundColor Green
    Write-Host '  Next, in the same Purview import job: tick both boxes, select C:\PSTImport\pst-mapping.csv, Validate, Save,' -ForegroundColor White
    Write-Host '  wait for "Analysis completed", then Import to Microsoft 365. Microsoft deletes the upload after 30 days.' -ForegroundColor White
    Write-AfToolLog $toolLog $summary
}

function Invoke-AfPurviewAfter {
    # Online add-on, CHANGE: after the import job says Complete, puts back retention hold and max
    # receive size, and removes the temporary role group if Auto-Fixer made it.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputRoot, [scriptblock] $ReadKey = { Read-AfMenuKey }, [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) })

    Write-Host '  Run this only after Purview shows the import job as Complete.' -ForegroundColor Yellow
    if (-not (Connect-AfExchange -ReadKey $ReadKey -ReadText $ReadText)) { return }
    try {
        $user = Read-AfMailboxAddress -ReadText $ReadText
        if (-not $user) { return }
        $mb = Get-Mailbox -Identity $user -ErrorAction SilentlyContinue
        if (-not $mb) { Write-Host '  That mailbox is not in this organization. Nothing was changed.' -ForegroundColor Red; return }
        $saved = $null
        $file = Join-Path $script:AfPurviewWork 'mailbox-before.json'
        if (Test-Path -LiteralPath $file) {
            $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($saved.mailboxKey -ne (Get-AfMailboxKey -Mailbox $user)) { $saved = $null }
        }
        if ($saved) {
            $wasHold = [bool]$saved.retentionHoldEnabled
            $wasMax = [string]$saved.maxReceiveSize
            Write-Host ('  Before the import (saved by the pre-check {0} UTC): retention hold {1}, max receive size {2}.' -f $saved.savedUtc, $wasHold, $wasMax)
        }
        else {
            Write-Host '  No pre-check values for this mailbox on this PC. Type them from the pre-check log.' -ForegroundColor Yellow
            $h = [string](& $ReadText 'Retention hold BEFORE the import (True or False)')
            if ($h -notmatch '^(?i)(true|false)$') { Write-Host '  Type True or False. Nothing was changed.' -ForegroundColor Yellow; return }
            $wasHold = $h -match '^(?i)true$'
            $wasMax = ([string](& $ReadText 'Max receive size BEFORE the import, such as 36 MB (Enter = leave as is)') -replace '\s*\(.*$', '').Trim()
        }
        $wasMax = ($wasMax -replace '\s*\(.*$', '').Trim()
        $group = Get-RoleGroup -Identity $script:AfPurviewRoleGroup -ErrorAction SilentlyContinue
        Write-Host ('  Now: retention hold {0}, max receive size {1}.' -f $mb.RetentionHoldEnabled, $mb.MaxReceiveSize)
        Write-Host ('  This sets retention hold to {0}{1}{2}.' -f $wasHold, $(if ($wasMax) { ", max receive size to $wasMax" } else { '' }), $(if ($group) { ', and removes the temporary import role group' } else { '' })) -ForegroundColor White
        if ((Read-AfYesNo -Prompt 'Put the settings back?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }

        $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'purview' -Redactor (New-AfRedactor) -Task 'Purview PST Import: after the import'
        $steps = @()
        try { Set-Mailbox -Identity $user -RetentionHoldEnabled $wasHold -ErrorAction Stop; $steps += ('OK        retention hold set to {0}' -f $wasHold) }
        catch { $steps += ('FAILED    retention hold: {0}' -f $_.Exception.Message) }
        if ($wasMax) {
            try { Set-Mailbox -Identity $user -MaxReceiveSize $wasMax -ErrorAction Stop; $steps += ('OK        max receive size set to {0}' -f $wasMax) }
            catch { $steps += ('FAILED    max receive size: {0}' -f $_.Exception.Message) }
        }
        if ($group) {
            try { Remove-RoleGroup -Identity $script:AfPurviewRoleGroup -Confirm:$false -ErrorAction Stop; $steps += 'OK        temporary role group removed' }
            catch { $steps += ('FAILED    role group: {0}' -f $_.Exception.Message) }
        }
        foreach ($s in $steps) { Write-Host ('  {0}' -f $s) -ForegroundColor (@{ $true = 'Green'; $false = 'Red' }[$s.StartsWith('OK')]); Write-AfToolLog $toolLog $s }
        Write-Host '  Check the Imported-<name> folders in the user''s Online Archive.' -ForegroundColor White
    }
    finally { Disconnect-AfExchange }
}

function Show-AfPurviewGuide {
    [CmdletBinding()]
    param()
    $lines = @(
        'Purview PST Import puts PST copies into a user''s Online Archive. The user does nothing.'
        ''
        'You need: the tenant''s Microsoft 365 admin sign-in, the user''s Online Archive turned on'
        '(Exchange admin center > mailbox > Others > Manage mailbox archive), and internet.'
        ''
        '1. Office and Outlook > Back up PSTs (no download): copies + SHA-256 check.'
        '2. M  Mapping file (no download): skips duplicates, writes C:\PSTImport\pst-mapping.csv.'
        'The steps below are online add-ons (Settings > Online add-ons must be On):'
        '3. C  Pre-check the mailbox (read-only; saves the two settings the import changes).'
        '4. R  Add the import role (only you, in a temporary role group).'
        '5. In Purview: Data lifecycle management > Import > New import job (lowercase name) >'
        '   Upload your data > Show network upload SAS URL.'
        '6. U  Upload the PST copies (downloads Microsoft AzCopy, asks for the SAS URL hidden).'
        '7. In the same job: tick both boxes, select the mapping file, Validate, Save, wait for'
        '   "Analysis completed", then Import to Microsoft 365.'
        '8. A  After the import says Complete: put the settings back, remove the role group.'
        'N  Undo: role group, the C:\PSTImport folder (AzCopy included), or how to remove the mail.'
        ''
        'Microsoft turns retention hold on with no end date and may raise max receive size; step 8 puts them back.'
    )
    Write-Host ''
    foreach ($l in $lines) { Write-Host ('  {0}' -f $l) }
}

function Invoke-AfPurviewUndo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $ReadText = { param($Prompt) Read-Host -Prompt ('  ' + $Prompt) },
        # Part 1 signs in to Exchange Online, so it needs the add-on switch.
        [bool] $AddonsOn = $false
    )

    Write-Host ''
    Write-Host '  1 = remove the role group "PST Import - temp" (online add-on, signs in)' -ForegroundColor White
    Write-Host '  2 = delete C:\PSTImport on this PC (AzCopy, mapping file, logs). Backups are not touched.' -ForegroundColor White
    Write-Host '  3 = how to remove imported mail (manual)' -ForegroundColor White
    $part = [string](& $ReadText 'Type 1, 2 or 3 (Enter = stop)')
    switch ($part) {
        '1' {
            if (-not $AddonsOn) { Write-Host '  Part 1 is an online add-on: turn on Settings > Online add-ons first. Nothing was changed.' -ForegroundColor Yellow; return }
            if (-not (Connect-AfExchange -ReadKey $ReadKey -ReadText $ReadText)) { return }
            try {
                if (-not (Get-RoleGroup -Identity $script:AfPurviewRoleGroup -ErrorAction SilentlyContinue)) { Write-Host '  No role group to remove. Nothing was changed.' -ForegroundColor Green; return }
                if ((Read-AfYesNo -Prompt 'Remove the role group?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
                $toolLog = New-AfToolLog -OutputRoot $OutputRoot -Kind 'purview' -Redactor (New-AfRedactor) -Task 'Purview PST Import: undo role group'
                try { Remove-RoleGroup -Identity $script:AfPurviewRoleGroup -Confirm:$false -ErrorAction Stop; Write-Host '  Role group removed.' -ForegroundColor Green; Write-AfToolLog $toolLog 'Result: role group removed.' }
                catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red; Write-AfToolLog $toolLog ('FAILED    {0}' -f $_.Exception.Message) }
            }
            finally { Disconnect-AfExchange }
        }
        '2' {
            if (-not (Test-Path -LiteralPath $script:AfPurviewWork)) { Write-Host '  No C:\PSTImport folder. Nothing was changed.' -ForegroundColor Green; return }
            if ((Read-AfYesNo -Prompt 'Delete C:\PSTImport?' -ReadKey $ReadKey) -ne $true) { Write-Host '  Nothing was changed.' -ForegroundColor Yellow; return }
            try { Remove-Item -LiteralPath $script:AfPurviewWork -Recurse -Force -ErrorAction Stop; Write-Host '  C:\PSTImport deleted. Backup folders untouched.' -ForegroundColor Green }
            catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red }
        }
        '3' {
            Write-Host '  Imported mail is only in Online Archive folders named Imported-<name>. Delete those folders in' -ForegroundColor White
            Write-Host '  Outlook or Outlook on the web. Nothing else in the mailbox changed. Then run After the import.' -ForegroundColor White
        }
        default { Write-Host '  Nothing was changed.' -ForegroundColor Yellow }
    }
}

function Invoke-AfPurviewMenu {
    <#
    .SYNOPSIS
        Office and Outlook > Purview PST Import (Technician). G and M use stock Windows. C, R, U, A
        and N > 1 are online add-ons: with the switch off they show a note and offer Settings.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputRoot', Justification = 'Used by the default action script blocks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Settings,
        [Parameter(Mandatory)] [string] $OutputRoot,
        [scriptblock] $ReadKey = { Read-AfMenuKey },
        [scriptblock] $OpenSettings,
        # Each is called with the settings.
        [scriptblock] $Guide = { param($S) Show-AfPurviewGuide },
        [scriptblock] $Prepare = { param($S) $null = Invoke-AfPurviewPrepare -OutputRoot $OutputRoot },
        [scriptblock] $Precheck = { param($S) Invoke-AfPurviewPrecheck -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Role = { param($S) Invoke-AfPurviewRole -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Upload = { param($S) Invoke-AfPurviewUpload -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $After = { param($S) Invoke-AfPurviewAfter -OutputRoot $OutputRoot -ReadKey $ReadKey },
        [scriptblock] $Undo = { param($S) Invoke-AfPurviewUndo -OutputRoot $OutputRoot -ReadKey $ReadKey -AddonsOn (Test-AfOnlineAddonsOn -Settings $S) }
    )

    $addon = 'Online add-on: needs Settings > Online add-ons On.'
    $itemInfo = @{
        G = @('What the import does, what you need, and the order of the steps.', '', 'Changes system: NO', 'Internet: never')
        M = @('Skips duplicate PSTs (same SHA-256) in the newest PSTBackup folder and writes the Purview mapping file.', '', 'Changes system: writes C:\PSTImport', 'Internet: never')
        C = @('Reads the user''s archive status and the two settings the import changes, and saves them for step A.', '', 'Changes system: NO', $addon, 'Exchange Online module + sign-in.')
        R = @('Gives only you the Mailbox Import Export role, in a temporary role group.', '', 'Changes system: YES (the tenant)', $addon, 'Asks Y/N first.')
        U = @('Uploads the PST copies to Microsoft with AzCopy. Asks for the SAS URL hidden; never saved.', '', 'Changes system: downloads AzCopy to C:\PSTImport', $addon, 'Asks Y/N before the download and the upload.')
        A = @('After the import is Complete: puts retention hold and max receive size back, removes the role group.', '', 'Changes system: YES (the tenant)', $addon, 'Asks Y/N first.')
        N = @('Remove the role group, delete C:\PSTImport, or how to remove imported mail.', '', 'Asks Y/N first.')
        B = @('Back to Office and Outlook.')
        Q = @('Closes Auto-Fixer. Asks first.')
    }
    $needs = @{ C = 'the Exchange Online module'; R = 'the Exchange Online module'; U = 'Microsoft AzCopy'; A = 'the Exchange Online module' }
    $notice = $null
    while ($true) {
        $state = @{ $true = 'On'; $false = 'Off' }[(Test-AfOnlineAddonsOn -Settings $Settings)]
        $info = @('Puts PST copies into a user''s Online Archive through Microsoft Purview.', ('Online add-ons: {0} (Settings > Online add-ons).' -f $state))
        $items = @(
            @{ Key = 'G'; Label = '&Guide: steps and what you need' }
            @{ Key = 'M'; Label = '&Mapping file (no download)'; Divider = $true }
            @{ Key = 'C'; Label = 'Pre-&check the mailbox'; Tags = '[ADD-ON]' }
            @{ Key = 'R'; Label = 'Add the import &role'; Tags = '[ADD-ON] [CHG]' }
            @{ Key = 'U'; Label = '&Upload PST copies'; Tags = '[ADD-ON]' }
            @{ Key = 'A'; Label = '&After the import'; Tags = '[ADD-ON] [CHG]' }
            @{ Key = 'N'; Label = 'U&ndo'; Divider = $true }
            @{ Key = 'B'; Label = '&Back' }
            @{ Key = 'Q'; Label = '&Quit' }
        )
        $choice = Select-AfMenuItem -Title 'Purview PST Import' -Items $items -Header { Show-AfBanner -Mode $Settings.Mode } -Info $info -ItemInfo $itemInfo `
            -Mode $Settings.Mode -Notice $notice -EscapeKey 'B' -ReadKey $ReadKey
        $notice = $null
        if ($choice -eq 'B') { return }
        if ($choice -eq 'Q') {
            if (Confirm-AfQuit -ReadKey $ReadKey) { $script:AfQuitRequested = $true; return }
            continue
        }
        if ($needs.ContainsKey($choice) -and -not (Test-AfOnlineAddonsOn -Settings $Settings)) {
            if (-not (Show-AfAddonOffNote -Settings $Settings -Needs $needs[$choice] -OpenSettings $OpenSettings -ReadKey $ReadKey)) {
                if ($script:AfQuitRequested) { return }
                Write-Host ''
                Write-Host '  Press any key to return to Purview PST Import.' -ForegroundColor DarkGray
                Clear-AfKeyBuffer
                $null = & $ReadKey
                continue
            }
        }
        $action = @{ G = $Guide; M = $Prepare; C = $Precheck; R = $Role; U = $Upload; A = $After; N = $Undo }[$choice]
        try { & $action $Settings }
        catch { Write-Host ('  Stopped: {0}' -f $_.Exception.Message) -ForegroundColor Red }
        if ($script:AfQuitRequested) { return }
        Write-Host ''
        Write-Host '  Press any key to return to Purview PST Import.' -ForegroundColor DarkGray
        Clear-AfKeyBuffer
        $null = & $ReadKey
    }
}
