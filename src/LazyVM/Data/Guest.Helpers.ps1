# Guest.Helpers.ps1 - Functions the guest-side script blocks share.
#
# Script blocks sent to the guest cannot call the module's functions, so
# what they share lives here. Import-GuestHelper loads this file into the
# PowerShell Direct session as an in-memory module each time the session
# opens; nothing is written to the guest's disk and the guest's execution
# policy does not apply.
#
# Runs in the GUEST, under Windows PowerShell 5.1: no PowerShell 7 syntax.

function New-GuestNote {
    <# One event for the host's log: Level is INFO, OK, WARN or ERROR. #>
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )

    return [pscustomobject]@{ Level = $Level; Text = $Text }
}

function New-GuestFolder {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# ── Zip archives ─────────────────────────────────────────────────────────────

function New-GuestZip {
    <# Zips $Source into $Destination, replacing any earlier archive. #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($Source, $Destination)
}

function Expand-GuestZip {
    <# Extracts $Archive into $Destination, which must not exist yet. #>
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

# ── SQL Server ───────────────────────────────────────────────────────────────

function Open-GuestSqlConnection {
    <# An open connection to master on $Server, with Windows authentication. #>
    param([Parameter(Mandatory)][string]$Server)

    $connection = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30")
    $connection.Open()
    return $connection
}

function Invoke-GuestSql {
    <# Runs a statement and returns the number of rows it affected. #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [int]$TimeoutSeconds = 3600
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = $TimeoutSeconds
    return $command.ExecuteNonQuery()
}

function Invoke-GuestSqlProcedure {
    <#
      Runs a stored procedure with named parameters (name without the @ ->
      value), so every value reaches SQL Server as data, never as SQL text.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Parameter = @{}
    )

    $command = $Connection.CreateCommand()
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    $command.CommandText = $Name
    $command.CommandTimeout = 300
    foreach ($key in $Parameter.Keys) {
        # Values from ConvertFrom-Json come wrapped; SqlClient needs the value itself.
        $value = $Parameter[$key]
        if ($null -ne $value) { $value = $value.PSObject.BaseObject }
        $null = $command.Parameters.AddWithValue("@$key", $value)
    }
    return $command.ExecuteNonQuery()
}

function Get-GuestSqlScalar {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = 120
    return $command.ExecuteScalar()
}

function Get-GuestSqlRow {
    <# Every row a query returns, each as an object with one property per column. #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = 300
    $reader = $command.ExecuteReader()
    $rows = @()
    try {
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) { $row[$reader.GetName($i)] = $reader.GetValue($i) }
            $rows += [pscustomobject]$row
        }
    }
    finally { $reader.Close() }
    # Callers wrap the call in @() so one row is still a list.
    return $rows
}

function ConvertTo-SqlName {
    <# A name bracket-quoted, so an odd name cannot change the statement: [my]]db]. #>
    param([Parameter(Mandatory)][string]$Name)

    return '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-SqlString {
    <# Text as a quoted Unicode literal: N'it''s'. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return "N'" + $Text.Replace("'", "''") + "'"
}

function Restore-GuestSqlBackup {
    <#
      Restores database $Name from $BackupFile, its files into $DataDir and
      $LogDir under their own logical names. Never overwrites: returns $false,
      changing nothing, when the database already exists, and $true once
      restored. Throws when the restore fails.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BackupFile,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$LogDir
    )

    $exists = [int](Get-GuestSqlScalar -Connection $Connection -Sql "SELECT COUNT(*) FROM sys.databases WHERE name = $(ConvertTo-SqlString -Text $Name)")
    if ($exists -gt 0) { return $false }

    $file = ConvertTo-SqlString -Text $BackupFile
    $moves = @()
    foreach ($entry in @(Get-GuestSqlRow -Connection $Connection -Sql "RESTORE FILELISTONLY FROM DISK = $file")) {
        $folder = if ("$($entry.Type)".ToUpperInvariant() -eq 'L') { $LogDir } else { $DataDir }
        $target = Join-Path $folder ([IO.Path]::GetFileName("$($entry.PhysicalName)"))
        $moves += "MOVE $(ConvertTo-SqlString -Text "$($entry.LogicalName)") TO $(ConvertTo-SqlString -Text $target)"
    }
    if ($moves.Count -eq 0) { throw "the backup $BackupFile lists no files" }

    $null = Invoke-GuestSql -Connection $Connection -Sql "RESTORE DATABASE $(ConvertTo-SqlName -Name $Name) FROM DISK = $file WITH $($moves -join ', '), STATS = 10"
    return $true
}

function Mount-GuestSqlDatabase {
    <#
      Attaches database $Name from $Files, the paths VM.json recorded for it,
      primary data file first (#132). A file not at its recorded path is
      looked for at the same path on drive $DriveLetter, where the SQL data
      disk is now. Returns 'Exists', changing nothing, when the database is
      already there; 'Missing', changing nothing, when a file is on neither
      drive; 'Attached' once attached. Throws when the attach fails.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    $exists = [int](Get-GuestSqlScalar -Connection $Connection -Sql "SELECT COUNT(*) FROM sys.databases WHERE name = $(ConvertTo-SqlString -Text $Name)")
    if ($exists -gt 0) { return 'Exists' }

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        $candidates = @($file)
        if ($file -match '^[A-Za-z]:\\') { $candidates += "${DriveLetter}:$($file.Substring(2))" }
        $here = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
        if (-not $here) { return 'Missing' }
        $found.Add($here)
    }

    $on = @($found | ForEach-Object { "(FILENAME = $(ConvertTo-SqlString -Text $_))" }) -join ', '
    $null = Invoke-GuestSql -Connection $Connection -Sql "CREATE DATABASE $(ConvertTo-SqlName -Name $Name) ON $on FOR ATTACH"
    return 'Attached'
}

function Get-GuestCapturedCertificate {
    <#
      The certificates a capture keeps: personal ones, and self-signed roots,
      which is where developer and local HTTPS certificates live. The stock
      trust list comes back with a fresh Windows install anyway. Each comes
      with the store it is in, as Store.
    #>
    foreach ($store in 'Cert:\LocalMachine\My', 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\Root') {
        foreach ($cert in @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue)) {
            # In the root store, only certificates someone made themselves.
            if ($store -eq 'Cert:\LocalMachine\Root' -and $cert.Issuer -ne $cert.Subject) { continue }
            if ($store -eq 'Cert:\LocalMachine\Root' -and $cert.Subject -match '(?i)microsoft|verisign|digicert|globalsign|baltimore|thawte|entrust|sectigo|comodo|go daddy|symantec|starfield|usertrust') { continue }
            [pscustomobject]@{ Certificate = $cert; Store = $store }
        }
    }
}

function Get-GuestVisualStudioSettingsFile {
    <#
      The newest .vssettings backup of the Visual Studio with instance
      $InstanceId, or $null. Visual Studio writes one every time it closes,
      so the newest is the live configuration. Its folder is named
      <version>_<instance id>, which ties it to that Visual Studio.
    #>
    param([Parameter(Mandatory)][string]$InstanceId)

    $newest = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio') -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*_$InstanceId" } |
            ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'Settings') -Filter '*.vssettings' -File -ErrorAction SilentlyContinue } |
            Sort-Object LastWriteTime -Descending) | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return $null
}

function Backup-GuestSqlDatabase {
    <#
      Checks database $Name with DBCC CHECKDB and, only when it passes, backs
      it up to <BackupDir>\<Name>.bak.new, verifies that backup, and only then
      lets it replace <Name>.bak (#133). So a corrupt database or a failed
      backup never costs the one good backup kept. Returns the backup's path;
      throws, leaving the last good backup as it was, when any step fails.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BackupDir
    )

    $null = Invoke-GuestSql -Connection $Connection -Sql "DBCC CHECKDB ($(ConvertTo-SqlString -Text $Name)) WITH NO_INFOMSGS, ALL_ERRORMSGS"

    New-GuestFolder -Path $BackupDir
    $file = Join-Path $BackupDir "$Name.bak"
    $new = "$file.new"
    $target = "$(ConvertTo-SqlName -Name $Name) TO DISK = $(ConvertTo-SqlString -Text $new)"
    try {
        # COMPRESSION is unavailable on some editions; retry without it.
        try { $null = Invoke-GuestSql -Connection $Connection -Sql "BACKUP DATABASE $target WITH INIT, FORMAT, CHECKSUM, COMPRESSION, STATS = 10" }
        catch { $null = Invoke-GuestSql -Connection $Connection -Sql "BACKUP DATABASE $target WITH INIT, FORMAT, CHECKSUM, STATS = 10" }
        $null = Invoke-GuestSql -Connection $Connection -Sql "RESTORE VERIFYONLY FROM DISK = $(ConvertTo-SqlString -Text $new) WITH CHECKSUM"
        Move-Item -LiteralPath $new -Destination $file -Force
    }
    catch {
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        throw
    }
    return $file
}

function Repair-GuestSqlOrphanedUser {
    <#
      Links each user in database $Name that has no login to the login of the
      same name. The SIDs kept with the logins should already prevent
      orphaned users. Returns a note for each user it could not link.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Name
    )

    $quoted = ConvertTo-SqlName -Name $Name
    $orphans = @(Get-GuestSqlRow -Connection $Connection -Sql "SELECT dp.name FROM $quoted.sys.database_principals dp LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid WHERE dp.type IN ('S','U') AND dp.principal_id > 4 AND sp.sid IS NULL" | ForEach-Object { "$($_.name)" })
    foreach ($user in $orphans) {
        try { $null = Invoke-GuestSql -Connection $Connection -Sql "USE $quoted; ALTER USER $(ConvertTo-SqlName -Name $user) WITH LOGIN = $(ConvertTo-SqlName -Name $user)" }
        catch { New-GuestNote -Level WARN -Text "user '$user' in $Name has no login: $($_.Exception.Message)" }
    }
}

# ── Volumes and drive letters ────────────────────────────────────────────────

function Get-GuestVolumeByLetter {
    param([Parameter(Mandatory)][string]$Letter)

    return Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='${Letter}:'" -ErrorAction SilentlyContinue
}

function Get-GuestFreeLetter {
    <# The highest free drive letter from Z: down to Q:, so moved drives land out of the way; $null when none is free. #>
    foreach ($letter in 'Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') {
        if (-not (Get-GuestVolumeByLetter -Letter $letter)) { return $letter }
    }
    return $null
}

# ── Data disks ───────────────────────────────────────────────────────────────

function Get-GuestDiskLun {
    <#
      The SCSI LUN Windows reports for a disk, which on Hyper-V is the
      location the host attached it at; $null when it reports none. Both
      Get-Disk and Get-PhysicalDisk give it as
      "Integrated : Adapter 0 : Port 0 : Target 0 : LUN 2".
    #>
    param([Parameter(Mandatory)]$Disk)

    if ("$($Disk.Location)" -match 'LUN (\d+)') { return [int]$Matches[1] }
    $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.DeviceId)" -eq "$($Disk.Number)" } | Select-Object -First 1
    if ($physical -and "$($physical.PhysicalLocation)" -match 'LUN (\d+)') { return [int]$Matches[1] }
    return $null
}

function Find-GuestDataDisk {
    <#
      The disk that a data disk's recorded identity names, never chosen by
      size. Tried in order: its GPT disk GUID, the SCSI location the host
      recorded when it attached the disk, then the location of its VHDX file
      now. Boot and system disks never match. Returns the disk and how it was
      found. Throws when nothing matches, when two disks match, or when the
      disk at the location has a different GPT disk GUID from the one
      recorded: the caller initialises and formats what this returns.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][AllowEmptyString()][string]$Guid,
        [AllowNull()]$Location,
        [AllowNull()]$FileLocation,
        [object[]]$Disks
    )

    if (-not $PSBoundParameters.ContainsKey('Disks')) { $Disks = @(Get-Disk) }
    $candidates = @($Disks | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })

    if ($Guid) {
        $byGuid = @($candidates | Where-Object { "$($_.Guid)" -eq $Guid })
        if ($byGuid.Count -gt 1) { throw "$($byGuid.Count) disks in the guest have the $Label's GPT disk GUID $Guid, so LazyVM cannot tell which is the $Label. Nothing was changed." }
        if ($byGuid.Count -eq 1) { return [pscustomobject]@{ Disk = $byGuid[0]; FoundBy = "its GPT disk GUID $Guid" } }
    }

    $tries = @(
        @{ Lun = $Location; FoundBy = 'the SCSI location recorded when it was attached' }
        @{ Lun = $FileLocation; FoundBy = 'the SCSI location of its VHDX file' }
    )
    foreach ($try in $tries) {
        if ($null -eq $try.Lun -or "$($try.Lun)" -eq '') { continue }
        $lun = [int]$try.Lun
        $atLun = @($candidates | Where-Object { (Get-GuestDiskLun -Disk $_) -eq $lun })
        if ($atLun.Count -gt 1) { throw "$($atLun.Count) disks in the guest are at SCSI LUN $lun, so LazyVM cannot tell which is the $Label. Nothing was changed." }
        if ($atLun.Count -eq 0) { continue }

        $disk = $atLun[0]
        if ($Guid -and "$($disk.Guid)" -and "$($disk.Guid)" -ne $Guid) {
            throw "The disk at SCSI LUN $lun has the GPT disk GUID $($disk.Guid), but the $Label's is recorded as $Guid, so it is not the $Label. Nothing was changed."
        }
        return [pscustomobject]@{ Disk = $disk; FoundBy = "$($try.FoundBy) (LUN $lun)" }
    }

    $recorded = @()
    if ($Guid) { $recorded += "GPT disk GUID $Guid" }
    if ($null -ne $Location -and "$Location" -ne '') { $recorded += "SCSI location $Location" }
    if ($null -ne $FileLocation -and "$FileLocation" -ne '') { $recorded += "VHDX file at SCSI location $FileLocation" }
    $what = if ($recorded.Count -gt 0) { $recorded -join ', ' } else { 'nothing recorded, and its VHDX file is not attached to SCSI controller 0' }
    throw "The $Label was not found in the guest ($what). Nothing was initialised or formatted. Check that the disk is attached to the VM."
}

# ── BitLocker ────────────────────────────────────────────────────────────────
#
# C: is protected by the virtual TPM, and every persistent disk by a recovery
# password the host stores, plus auto-unlock, which ties it to the C: that
# turned it on (#175). Nothing here ever puts a recovery password in a note
# or an error.

function Get-GuestVolumeMountPoint {
    <# The data volume on $Disk as BitLocker names it: its drive letter, else its volume GUID path; $null when the disk holds no volume yet. #>
    param([Parameter(Mandatory)]$Disk)

    $part = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.Type -ne 'Reserved' -and $_.Size -gt 100MB }) | Select-Object -First 1
    if (-not $part) { return $null }
    $letter = "$($part.DriveLetter)".Trim()
    if ($letter) { return "${letter}:" }
    return @($part.AccessPaths | Where-Object { "$_" -like '\\?\Volume*' }) | Select-Object -First 1
}

function Protect-GuestVolume {
    <#
      Turns BitLocker on for $MountPoint with $RecoveryPassword, or, when it
      is on already, makes sure the volume has that password, for a data
      volume auto-unlock, and that its protection is on. -System is C:, which the TPM unlocks: it gets the
      recovery password before it is encrypted, as Microsoft advises. A data
      volume is encrypted only when C: is, since only then can it unlock
      itself, and BitLocker is turned off again when auto-unlock cannot be
      turned on. -UsedSpaceOnly is for a volume formatted in this run; any
      other is encrypted whole. Encryption goes on in the background.
      Returns notes (New-GuestNote); throws, leaving the volume as it was,
      when it cannot be done.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'RecoveryPassword', Justification = 'The BitLocker cmdlets take a recovery password only as text.')]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][string]$RecoveryPassword,
        [switch]$System,
        [switch]$UsedSpaceOnly
    )

    $notes = @()
    $volume = Get-BitLockerVolume -MountPoint $MountPoint
    if ("$($volume.LockStatus)" -eq 'Locked') { throw "$MountPoint is locked, so BitLocker could not be checked; left as it was" }
    $status = "$($volume.VolumeStatus)"
    if ($status -eq 'DecryptionInProgress') {
        return New-GuestNote -Level WARN -Text "$MountPoint is being decrypted; left as it is"
    }
    if (-not $System -and "$((Get-BitLockerVolume -MountPoint $env:SystemDrive).VolumeStatus)" -eq 'FullyDecrypted') {
        throw "C: is not encrypted, so $MountPoint could not unlock itself; left as it was"
    }
    $hasPassword = @($volume.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' -and $_.RecoveryPassword -eq $RecoveryPassword }).Count -gt 0

    if ($status -eq 'FullyDecrypted') {
        $encryption = @{ EncryptionMethod = 'XtsAes256'; SkipHardwareTest = $true; UsedSpaceOnly = [bool]$UsedSpaceOnly }
        if ($System) {
            if (-not $hasPassword) { $null = Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -RecoveryPassword $RecoveryPassword }
            $null = Enable-BitLocker -MountPoint $MountPoint -TpmProtector @encryption
        }
        else {
            $null = Enable-BitLocker -MountPoint $MountPoint -RecoveryPasswordProtector -RecoveryPassword $RecoveryPassword @encryption
            try { $null = Enable-BitLockerAutoUnlock -MountPoint $MountPoint }
            catch {
                $reason = $_.Exception.Message
                $null = Disable-BitLocker -MountPoint $MountPoint
                throw "auto-unlock could not be turned on for $MountPoint ($reason), so BitLocker was turned off again"
            }
        }
        $extent = if ($UsedSpaceOnly) { 'its used space' } else { 'the whole volume' }
        return New-GuestNote -Level OK -Text "BitLocker turned on for ${MountPoint}: encrypting $extent in the background"
    }

    if (-not $hasPassword) {
        $null = Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -RecoveryPassword $RecoveryPassword
        $notes += New-GuestNote -Level INFO -Text "gave $MountPoint the recovery password LazyVM stores"
    }
    if (-not $System -and -not $volume.AutoUnlockEnabled) {
        $null = Enable-BitLockerAutoUnlock -MountPoint $MountPoint
        $notes += New-GuestNote -Level OK -Text "turned on auto-unlock for $MountPoint"
    }

    # Windows' own device encryption leaves a volume encrypted with a clear
    # key and protection off (#185). C: needs the TPM before protection can go
    # on. A C: that has the TPM already was suspended by Windows Update, which
    # resumes it after the next restart; resuming it sooner can make that
    # restart ask for the recovery password.
    if ("$($volume.ProtectionStatus)" -eq 'Off') {
        $hasTpm = @($volume.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'Tpm' }).Count -gt 0
        if ($System -and $hasTpm) {
            $notes += New-GuestNote -Level INFO -Text "BitLocker on $MountPoint is suspended until Windows restarts; left as it is"
            return $notes
        }
        if ($System) { $null = Add-BitLockerKeyProtector -MountPoint $MountPoint -TpmProtector }
        $null = Resume-BitLocker -MountPoint $MountPoint
        $notes += New-GuestNote -Level OK -Text "turned BitLocker protection on for $MountPoint"
    }
    return $notes
}

function Unlock-GuestVolume {
    <#
      Unlocks $MountPoint with $RecoveryPassword when BitLocker has it
      locked, as it does in a rebuilt guest. Returns whether it unlocked it.
      Throws when it is locked and stays so, so nothing is restored onto it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'RecoveryPassword', Justification = 'The BitLocker cmdlets take a recovery password only as text.')]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][AllowNull()][string]$RecoveryPassword
    )

    if ("$((Get-BitLockerVolume -MountPoint $MountPoint).LockStatus)" -ne 'Locked') { return $false }
    if (-not $RecoveryPassword) {
        throw "The $Label is locked by BitLocker and LazyVM has no recovery password stored for it. Nothing was changed."
    }
    try { $null = Unlock-BitLocker -MountPoint $MountPoint -RecoveryPassword $RecoveryPassword }
    catch { throw "The $Label could not be unlocked with its stored recovery password ($($_.Exception.Message)). Nothing was changed." }
    if ("$((Get-BitLockerVolume -MountPoint $MountPoint).LockStatus)" -eq 'Locked') {
        throw "The $Label could not be unlocked with its stored recovery password: it is still locked. Nothing was changed."
    }
    return $true
}

# ── The User disk ────────────────────────────────────────────────────────────
#
# Personal folders live on the User disk, which no rebuild touches (#137).
# What is already on C: is copied, never moved: the originals go only when a
# rebuild replaces the OS disk.

$script:UserShellFolderKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

function Copy-GuestFolderContent {
    <# Copies everything in $Source into $Destination, never overwriting a newer file there. Throws when a file could not be copied. #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    # /XO keeps a newer file already on the User disk; /XJ skips junctions,
    # which would copy what they point at. Security is not copied: the
    # folder's own permissions apply.
    & robocopy.exe $Source $Destination '/E' '/XO' '/XJ' '/COPY:DAT' '/DCOPY:DAT' '/R:1' '/W:1' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "could not copy $Source to $Destination (robocopy exit $LASTEXITCODE)" }
}

function Set-GuestFolderLink {
    <#
      Makes $Link a junction to $Target. A real folder at $Link is copied
      into $Target first and kept, renamed. A link already pointing at
      $Target is left alone, and so is one pointing elsewhere, which someone
      chose: that returns a WARN note.
    #>
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    New-GuestFolder -Path $Target
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) {
        if (@($item.Target) -contains $Target) { return }
        return New-GuestNote -Level WARN -Text "$Link already links to $(@($item.Target) -join ', '); left as it is"
    }
    if ($item) {
        Copy-GuestFolderContent -Source $Link -Destination $Target
        Rename-Item -LiteralPath $Link -NewName "$($item.Name).before-user-disk-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    else {
        New-GuestFolder -Path (Split-Path -Path $Link -Parent)
    }
    New-Item -ItemType Junction -Path $Link -Value $Target | Out-Null
    return New-GuestNote -Level OK -Text "linked $Link to $Target"
}

function Set-GuestShellFolder {
    <#
      Points the shell folder $Name, and each of $Aliases Windows already
      has, at $Path, once what its current location holds is copied there.
      Explorer picks the new location up at the next sign-in.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Aliases = @(),
        [Parameter(Mandatory)][string]$Path,
        [string]$Key = $script:UserShellFolderKey
    )

    New-GuestFolder -Path $Path
    $values = (Get-Item -LiteralPath $Key).GetValueNames()
    $current = [Environment]::ExpandEnvironmentVariables("$((Get-Item -LiteralPath $Key).GetValue($Name, ''))")
    if ($current -and $current.TrimEnd('\') -ne $Path.TrimEnd('\') -and (Test-Path -LiteralPath $current -PathType Container)) {
        Copy-GuestFolderContent -Source $current -Destination $Path
    }
    foreach ($value in @($Name) + @($Aliases | Where-Object { $values -contains $_ })) {
        Set-ItemProperty -LiteralPath $Key -Name $value -Value $Path -Type ExpandString
    }
}

function Grant-GuestFolderAccess {
    <#
      Makes $Path and everything in it belong to the account $Sid, with full
      control for it, SYSTEM and Administrators and no one else. A rebuilt
      guest's account has a new SID, so what the old one had is dropped.
      Returns whether anything changed: nothing does once it is so.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid
    )

    $allowed = @($Sid, 'S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $others = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $allowed -notcontains $_.IdentityReference.Value })
    if ($acl.AreAccessRulesProtected -and $owner -eq $Sid -and $others.Count -eq 0) { return $false }

    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($who in $allowed) {
        $identity = New-Object Security.Principal.SecurityIdentifier $who
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier $Sid))
    Set-Acl -LiteralPath $Path -AclObject $acl

    # What is inside inherits the folder's permissions and changes owner.
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
        & icacls.exe (Join-Path $Path '*') '/reset' '/T' '/C' '/Q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not reset the permissions inside $Path (icacls exit $LASTEXITCODE)" }
        & icacls.exe (Join-Path $Path '*') '/setowner' "*$Sid" '/T' '/C' '/Q' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not change the owner inside $Path (icacls exit $LASTEXITCODE)" }
    }
    return $true
}

function Get-GuestUserFolderProblem {
    <#
      What is not yet on the User disk at $Root: each of $Folders whose shell
      folder points elsewhere, or whose place in $ProfileDir is not a link.
      A link someone pointed elsewhere counts as their choice. Returns
      nothing when every folder is in place.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Folders,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ProfileDir,
        [string]$Key = $script:UserShellFolderKey
    )

    foreach ($folder in $Folders) {
        $target = Join-Path $Root $folder['Name']
        if ($folder['ShellFolder']) {
            $now = [Environment]::ExpandEnvironmentVariables("$((Get-Item -LiteralPath $Key).GetValue($folder['ShellFolder'], ''))")
            if ($now.TrimEnd('\') -ne $target) { "$($folder['Name']) is at '$now', not $target" }
        }
        else {
            $link = Join-Path $ProfileDir $folder['Link']
            if (-not (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue).LinkType) { "$link is not linked to $target" }
        }
    }
}

# ── Installed software ───────────────────────────────────────────────────────

function Find-GuestWinget {
    <#
      winget.exe, or $null. It ships as an MSIX app alias, which is not always
      on PATH in a PowerShell Direct session, so the real path is the fallback.
    #>
    $command = Get-Command winget -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $alias) { return $alias }
    $found = @(Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    if ($found.Count -gt 0) { return $found[0].FullName }
    return $null
}

function ConvertFrom-GuestWingetTable {
    <#
      The rows of a table winget printed (search, list), each as @{ Name; Id }.
      The columns are found from where each heading starts in the line above
      the dashes, so localized headings do not matter. Progress output before
      a carriage return is ignored.
    #>
    param([string[]]$Lines = @())

    $clean = @($Lines | ForEach-Object { ("$_" -split "`r")[-1] })
    $separator = -1
    for ($i = 1; $i -lt $clean.Count; $i++) {
        if ($clean[$i] -match '^\s*-{3,}\s*$') { $separator = $i; break }
    }
    if ($separator -lt 1) { return }

    $header = $clean[$separator - 1]
    $starts = @()
    for ($i = 0; $i -lt $header.Length; $i++) {
        if ($header[$i] -ne ' ' -and ($i -eq 0 -or $header[$i - 1] -eq ' ')) { $starts += $i }
    }
    if ($starts.Count -lt 3) { return }

    for ($i = $separator + 1; $i -lt $clean.Count; $i++) {
        $line = $clean[$i]
        if (-not $line.Trim()) { break }
        if ($line.Length -le $starts[1]) { continue }
        $idLength = [Math]::Min($starts[2], $line.Length) - $starts[1]
        [pscustomobject]@{
            Name = $line.Substring(0, $starts[1]).Trim()
            Id   = $line.Substring($starts[1], $idLength).Trim()
        }
    }
}

function Select-GuestWingetMatch {
    <#
      The id of the one package in winget's search output whose name is
      exactly $Name (ignoring case), or '' when none is, several are, or the
      id is not a well-formed winget identifier.
    #>
    param(
        [string[]]$Lines = @(),
        [Parameter(Mandatory)][string]$Name
    )

    $matched = @(ConvertFrom-GuestWingetTable -Lines $Lines | Where-Object { $_.Name -eq $Name.Trim() })
    if ($matched.Count -ne 1) { return '' }
    if ($matched[0].Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { return '' }
    return $matched[0].Id
}

function Get-GuestWingetPublisher {
    <# The Publisher line of winget show's output, or '' when it has none. #>
    param([string[]]$Lines = @())

    foreach ($line in $Lines) {
        if ("$line" -match '^\s*Publisher:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Get-GuestInstallerKind {
    <# 'exe' or 'msi' from a downloaded file's first bytes, never its name; '' for anything else. #>
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $head = New-Object byte[] 8
        $read = $stream.Read($head, 0, 8)
    }
    finally { $stream.Dispose() }

    if ($read -ge 2 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A) { return 'exe' }
    $ole = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    if ($read -eq 8 -and -not (Compare-Object -ReferenceObject $ole -DifferenceObject $head -SyncWindow 0)) { return 'msi' }
    return ''
}

function Get-GuestInstallerProblem {
    <#
      Why a downloaded installer must not run, or '' when it may: it must
      have a valid Authenticode signature from $Publisher (the signing
      certificate's name, ignoring case) and, when $Sha256 is given, that
      hash. Anything that cannot be checked counts as a problem.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Publisher,
        [string]$Sha256
    )

    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) { return "its SHA-256 hash is $actual, not the pinned $Sha256" }
    }

    try { $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop }
    catch { return "its signature could not be read: $($_.Exception.Message)" }
    if ("$($signature.Status)" -ne 'Valid') { return "its signature is $($signature.Status), not Valid" }
    if (-not $signature.SignerCertificate) { return 'its signature names no signer' }

    $signer = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ("$signer".Trim() -ne $Publisher.Trim()) { return "it is signed by '$signer', not '$Publisher'" }
    return ''
}

function New-GuestPrivateFolder {
    <#
      A new, empty folder only administrators and SYSTEM can change, for a
      download that is checked and then run. Created with its ACL in one
      step, so no one else can put anything in it first. Fails if anything
      is already at $Path.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) { throw "$Path already exists" }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $null = [IO.Directory]::CreateDirectory($Path, $acl)
}

function Get-GuestInstallerInstance {
    <#
      Every product the Visual Studio Installer manages (Visual Studio, SSMS,
      Build Tools), as vswhere reports it; nothing when the installer is absent.
      Callers wrap the call in @().
    #>
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return }
    $raw = & $vswhere -all -prerelease -products * -format json -utf8 2>$null
    if (-not $raw) { return }

    # Windows PowerShell 5.1 passes a JSON array down the pipeline as ONE
    # object; foreach splits it into its instances.
    foreach ($instance in (($raw -join "`n") | ConvertFrom-Json)) { $instance }
}

# ── One-shot scheduled tasks ─────────────────────────────────────────────────
#
# Work that must outlive the PowerShell Direct session (long installers), or
# run in the signed-in user's desktop session (Visual Studio settings), runs
# as a scheduled task. The task runs a fixed wrapper script. The work itself
# and its arguments are written beside it as files, never pasted into script
# text, so no path or value can change what the script does. The wrapper
# writes <task>.done: the work's result, OK, or FAILED: <reason>.

$script:GuestTaskWrapper = @'
$ErrorActionPreference = 'Stop'
$base = $PSCommandPath -replace '\.ps1$', ''
$transcribing = $false
try { Start-Transcript -Path "$base.log" -Force | Out-Null; $transcribing = $true } catch { $transcribing = $false }
try {
    $arguments = @()
    foreach ($item in (Get-Content -LiteralPath "$base.args.json" -Raw | ConvertFrom-Json)) { $arguments += , $item }
    $work = [scriptblock]::Create((Get-Content -LiteralPath "$base.work.ps1" -Raw))
    $result = & $work @arguments
    if ($null -eq $result) { $result = 'OK' }
    "$(@($result)[-1])" | Set-Content -LiteralPath "$base.done"
}
catch { "FAILED: $($_.Exception.Message)" | Set-Content -LiteralPath "$base.done" }
finally { if ($transcribing) { Stop-Transcript | Out-Null } }
'@

function Start-GuestTask {
    <#
      Writes the wrapper, the work and its arguments to $SetupDir, registers
      the task and starts it. As SYSTEM, or with -UserName as that signed-in
      user under their normal (limited) token, or with -Elevated their full
      one. Returns the boot time, so the host can tell when the guest
      restarted.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$SetupDir,
        [Parameter(Mandatory)][string]$Work,
        [object[]]$ArgumentList = @(),
        [string]$UserName,
        [switch]$Elevated,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    New-GuestFolder -Path $SetupDir
    $base = Join-Path $SetupDir $TaskName
    Remove-Item -LiteralPath "$base.done" -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath "$base.ps1" -Value $script:GuestTaskWrapper -Encoding UTF8
    Set-Content -LiteralPath "$base.work.ps1" -Value $Work -Encoding UTF8
    Set-Content -LiteralPath "$base.args.json" -Value (ConvertTo-Json -InputObject @($ArgumentList) -Depth 5) -Encoding UTF8

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$base.ps1`""
    $principal = if ($UserName) {
        New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel $(if ($Elevated) { 'Highest' } else { 'Limited' })
    }
    else {
        New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
}

function Get-GuestTaskStatus {
    <# Done: what the wrapper wrote, or $null while it runs; the task's state; the boot time. #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$SetupDir
    )

    $done = Join-Path $SetupDir "$TaskName.done"
    $result = $null
    if (Test-Path -LiteralPath $done) { $result = (Get-Content -LiteralPath $done -Raw).Trim() }
    return [pscustomobject]@{
        Done      = $result
        TaskState = "$((Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State)"
        BootTime  = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    }
}

function Remove-GuestTask {
    param([Parameter(Mandatory)][string]$TaskName)

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
