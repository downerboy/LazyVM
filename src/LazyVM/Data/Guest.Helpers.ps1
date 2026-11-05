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

# How long SQL work waits for SQL Server to accept a connection, and how long
# it pauses between tries. After a restart the service can still be starting
# when SQL work begins (#318).
$script:GuestSqlStartLimit = [timespan]::FromMinutes(5)
$script:GuestSqlRetrySeconds = 5

function Get-GuestSqlInstanceName {
    <# The instance $Server names: localhost is MSSQLSERVER, localhost\DEV is DEV. #>
    param([Parameter(Mandatory)][string]$Server)

    if ($Server -match '\\(.+)$') { return $Matches[1] }
    return 'MSSQLSERVER'
}

function Get-GuestSqlServiceName {
    <# The Windows service of an instance: MSSQLSERVER for the default one, MSSQL$DEV for DEV. #>
    param([Parameter(Mandatory)][string]$Instance)

    if ($Instance -eq 'MSSQLSERVER') { return $Instance }
    return "MSSQL`$$Instance"
}

function Get-GuestSqlErrorLogPath {
    <#
      The ERRORLOG file of an instance, from the -e startup parameter SQL
      Server setup records; $null when the registry does not say.
    #>
    param([Parameter(Mandatory)][string]$Instance)

    $sqlKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
    $names = Get-ItemProperty -Path "$sqlKey\Instance Names\SQL" -ErrorAction SilentlyContinue
    if (-not $names -or -not $names.PSObject.Properties[$Instance]) { return $null }

    $parameters = Get-ItemProperty -Path "$sqlKey\$($names.$Instance)\MSSQLServer\Parameters" -ErrorAction SilentlyContinue
    if (-not $parameters) { return $null }
    $errorLog = @($parameters.PSObject.Properties | Where-Object { $_.Name -like 'SQLArg*' -and "$($_.Value)" -like '-e*' })
    if ($errorLog.Count -eq 0) { return $null }
    return "$($errorLog[0].Value)".Substring(2)
}

function Start-GuestSqlService {
    <# Starts the service $Name when it is stopped, without waiting; throws when it is disabled. #>
    param([Parameter(Mandatory)][string]$Name)

    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.Status -ne 'Stopped') { return }
    if ($service.StartType -eq 'Disabled') {
        throw "SQL Server cannot start: its service $Name is disabled. Set the service's startup type to Automatic in Services (services.msc), then run this again."
    }
    # Start() returns at once; Start-Service would wait, with no limit, for
    # the service to run.
    $service.Start()
}

function New-GuestSqlConnection {
    <# One try: an open connection to master on $Server, with Windows authentication. #>
    param([Parameter(Mandatory)][string]$Server)

    $connection = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30")
    $connection.Open()
    return $connection
}

function Open-GuestSqlConnection {
    <#
      An open connection to master on $Server, with Windows authentication.
      A stopped SQL Server service is started, and SQL Server is given up to
      $script:GuestSqlStartLimit to run and accept the connection.
    #>
    param([Parameter(Mandatory)][string]$Server)

    $instance = Get-GuestSqlInstanceName -Server $Server
    $serviceName = Get-GuestSqlServiceName -Instance $instance
    Start-GuestSqlService -Name $serviceName
    $deadline = (Get-Date) + $script:GuestSqlStartLimit
    $lastError = 'none, as the service never ran'
    while ($true) {
        $status = (Get-Service -Name $serviceName -ErrorAction Stop).Status
        if ($status -eq 'Running') {
            try { return New-GuestSqlConnection -Server $Server }
            catch { $lastError = $_.Exception.Message }
        }
        if ((Get-Date) -ge $deadline) {
            $errorLog = Get-GuestSqlErrorLogPath -Instance $instance
            $where = if ($errorLog) { " at $errorLog" } else { ', in the MSSQL\Log folder of the instance under C:\Program Files\Microsoft SQL Server' }
            throw "SQL Server did not accept a connection within $($script:GuestSqlStartLimit.TotalMinutes) minutes. Its service $serviceName is $status; the last connection error was: $lastError. The SQL Server ERRORLOG$where, says why it did not start."
        }
        Start-Sleep -Seconds $script:GuestSqlRetrySeconds
    }
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

function Get-GuestVisualStudioSettingsHash {
    <#
      The SHA256 hash of the newest .vssettings backup of the Visual Studio
      with instance $InstanceId (Get-GuestVisualStudioSettingsFile), or ''
      when there is none, or when a junction or link is on the way to it
      from the profile, which the user's own processes could have put there
      to lead an administrator's read to another file (#330).
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$InstanceId)

    $settings = Get-GuestVisualStudioSettingsFile -InstanceId $InstanceId
    if (-not $settings -or (Test-GuestLinkOnPath -Root $env:USERPROFILE -Path $settings)) { return '' }
    return (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
}

# Where the guest records, per user, what it has of each Visual Studio
# instance's settings (#266): its marker, in the value named for the instance
# id, and the night maintenance first found that Visual Studio opened while
# the settings were pending, in the value named for the instance id with
# $script:GuestVisualStudioFirstOpenedSuffix.
$script:GuestVisualStudioSettingKey = 'HKCU:\SOFTWARE\LazyVM\VisualStudioSettings'
$script:GuestVisualStudioFirstOpenedSuffix = '.FirstOpened'

function Get-GuestVisualStudioSettingValue {
    <# The value $Name under the Visual Studio settings key, or $null when there is none. #>
    param([Parameter(Mandatory)][string]$Name)

    $recorded = Get-ItemProperty -Path $script:GuestVisualStudioSettingKey -Name $Name -ErrorAction SilentlyContinue
    if ($recorded) { return "$($recorded.$Name)" }
    return $null
}

function Set-GuestVisualStudioSettingValue {
    <# Records $Value as the value $Name under the Visual Studio settings key. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    if (-not (Test-Path -Path $script:GuestVisualStudioSettingKey)) { $null = New-Item -Path $script:GuestVisualStudioSettingKey -Force }
    $null = New-ItemProperty -Path $script:GuestVisualStudioSettingKey -Name $Name -Value $Value -PropertyType String -Force
}

function Get-GuestVisualStudioSettingMarker {
    <# What the guest records of the settings of the Visual Studio with instance $InstanceId, or $null when it records nothing. #>
    param([Parameter(Mandatory)][string]$InstanceId)

    return Get-GuestVisualStudioSettingValue -Name $InstanceId
}

function Set-GuestVisualStudioSettingMarker {
    <#
      Records $Value for the settings of the Visual Studio with instance
      $InstanceId. A new marker starts or ends a pending period, so the night
      Visual Studio was first found opened in the previous one goes.
    #>
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$Value
    )

    Set-GuestVisualStudioSettingValue -Name $InstanceId -Value $Value
    Remove-ItemProperty -Path $script:GuestVisualStudioSettingKey -Name "$InstanceId$script:GuestVisualStudioFirstOpenedSuffix" -ErrorAction SilentlyContinue
}

function Get-GuestVisualStudioFirstOpened {
    <# The night (yyyy-MM-dd) maintenance first found the Visual Studio with instance $InstanceId opened while its settings were pending, or $null. #>
    param([Parameter(Mandatory)][string]$InstanceId)

    return Get-GuestVisualStudioSettingValue -Name "$InstanceId$script:GuestVisualStudioFirstOpenedSuffix"
}

function Set-GuestVisualStudioFirstOpened {
    <# Records $Date (yyyy-MM-dd) as the night maintenance first found the Visual Studio with instance $InstanceId opened while its settings were pending. #>
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$Date
    )

    Set-GuestVisualStudioSettingValue -Name "$InstanceId$script:GuestVisualStudioFirstOpenedSuffix" -Value $Date
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

function Find-GuestRecoveryProtector {
    <# The key protector of $Volume (from Get-BitLockerVolume) with the recovery password $RecoveryPassword, or $null when it has none. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'RecoveryPassword', Justification = 'The BitLocker cmdlets report a recovery password only as text.')]
    param(
        [Parameter(Mandatory)][psobject]$Volume,
        [Parameter(Mandatory)][string]$RecoveryPassword
    )

    $protectors = @($Volume.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' -and $_.RecoveryPassword -eq $RecoveryPassword })
    if ($protectors.Count -eq 0) { return $null }
    return $protectors[0]
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
    if (-not $System -and "$((Get-BitLockerVolume -MountPoint (Get-GuestSystemDrive)).VolumeStatus)" -eq 'FullyDecrypted') {
        throw "C: is not encrypted, so $MountPoint could not unlock itself; left as it was"
    }
    $hasPassword = [bool](Find-GuestRecoveryProtector -Volume $volume -RecoveryPassword $RecoveryPassword)

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

function Get-GuestRecoveryKeyId {
    <#
      The key protector ID BitLocker gave $RecoveryPassword on $MountPoint,
      which its recovery screen shows as the recovery key ID; empty when the
      volume does not have that password.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'RecoveryPassword', Justification = 'The BitLocker cmdlets report a recovery password only as text.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][string]$RecoveryPassword
    )

    $protector = Find-GuestRecoveryProtector -Volume (Get-BitLockerVolume -MountPoint $MountPoint) -RecoveryPassword $RecoveryPassword
    if ($protector) { return [string]$protector.KeyProtectorId }
    return ''
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
    $found = @(Get-ChildItem -Path ([IO.Path]::Combine((Get-GuestSystemFolder -Name ProgramFiles), 'WindowsApps')) -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    if ($found.Count -gt 0) { return $found[0].FullName }
    return $null
}

function ConvertFrom-GuestWingetTable {
    <#
      The rows of a table winget printed (search, list, upgrade), each as
      @{ Name; Id; Source }: Source is the last column, empty on a line that
      is not a row but runs on after the table, as winget's footers do.
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
        $lastStart = $starts[$starts.Count - 1]
        [pscustomobject]@{
            Name   = $line.Substring(0, $starts[1]).Trim()
            Id     = $line.Substring($starts[1], $idLength).Trim()
            Source = $(if ($line.Length -gt $lastStart) { $line.Substring($lastStart).Trim() } else { '' })
        }
    }
}

function Test-GuestWingetId {
    <#
      Whether $Id has the shape of a winget identifier, which text from
      around winget's tables (footers, notes) does not. With -AllowCutShort,
      an id winget cut short with an ellipsis to fit its column passes too.
    #>
    param(
        [AllowEmptyString()][string]$Id,
        [switch]$AllowCutShort
    )

    $ending = if ($AllowCutShort) { [string][char]0x2026 + '?' } else { '' }
    return $Id -match ('^[A-Za-z0-9][A-Za-z0-9._+-]*' + $ending + '$')
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
    if (-not (Test-GuestWingetId -Id $matched[0].Id)) { return '' }
    return $matched[0].Id
}

function Resolve-GuestWingetId {
    <#
      The whole id for an id from a table winget printed. winget cuts a long
      id short with an ellipsis to fit its columns; such an id is completed
      from $KnownId (winget export's ids, which are whole) when exactly one
      of them starts with it. Returns '' when it cannot be completed.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$KnownId = @()
    )

    $ellipsis = [string][char]0x2026
    if (-not $Id.EndsWith($ellipsis)) { return $Id }
    $start = $Id.Substring(0, $Id.Length - 1)
    $candidates = @($KnownId | Where-Object { $_.StartsWith($start, [StringComparison]::OrdinalIgnoreCase) })
    if ($candidates.Count -ne 1) { return '' }
    return $candidates[0]
}

function Test-GuestProgramFolderUsable {
    <#
      Whether $Path can stand for one program's folder when telling whether
      it is running; a program without one gets no running check. Not a drive, Program Files, or a profile's AppData or
      Programs folder, which hold every program, and nothing under Windows
      or the Package Cache, where installers keep only their own copies.
    #>
    param([AllowEmptyString()][string]$Path)

    if (-not $Path -or $Path -match '^[A-Za-z]:\\?$') { return $false }
    $tooBroad = @((Get-GuestSystemFolder -Name ProgramFiles), (Get-GuestSystemFolder -Name ProgramFilesX86), $env:APPDATA, $env:LOCALAPPDATA, "$env:LOCALAPPDATA\Programs") |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ($tooBroad -contains $Path.TrimEnd('\')) { return $false }
    $installerFolders = @((Get-GuestSystemFolder -Name Windows), "$(Get-GuestSystemFolder -Name CommonApplicationData)\Package Cache")
    foreach ($installersOnly in $installerFolders) {
        if ("$Path\".StartsWith("$installersOnly\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-GuestProgramFolder {
    <#
      The folders the program Windows lists as $Name (in Installed apps) is
      installed in, from its uninstall entries: the install location, or the
      folder of its icon. A name winget cut short with an ellipsis matches the
      names it starts. Nothing for a program with neither, or whose folder
      cannot stand for it alone (Test-GuestProgramFolderUsable), as an MSI's
      icon in the Windows folder cannot: its folder is then unknown, and
      whether it is running cannot be told.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $ellipsis = [string][char]0x2026
    $cutShort = $Name.EndsWith($ellipsis)
    $start = $Name.TrimEnd([char]0x2026)
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $folders = foreach ($entry in @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue)) {
        $displayName = "$($entry.DisplayName)"
        $matched = if ($cutShort) { $displayName.StartsWith($start, [StringComparison]::OrdinalIgnoreCase) } else { $displayName -eq $Name }
        if (-not $matched) { continue }

        $folder = "$($entry.InstallLocation)".Trim().Trim('"').TrimEnd('\')
        if (-not $folder -and "$($entry.DisplayIcon)") {
            # An icon is "path" or "path,index".
            $icon = ("$($entry.DisplayIcon)" -split ',')[0].Trim().Trim('"')
            $folder = if ($icon.Contains('\')) { $icon.Substring(0, $icon.LastIndexOf('\')) } else { '' }
        }
        if (Test-GuestProgramFolderUsable -Path $folder) { $folder }
    }
    return @($folders | Sort-Object -Unique)
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

# ── System folders ───────────────────────────────────────────────────────────
#
# Where Windows, Program Files and the other system folders are, asked of
# Windows. Never from $env:ProgramFiles, $env:SystemRoot and the like: the
# guest admin's sessions also take variables from its HKCU\Environment, which
# that account can change without elevating, so they could lead what LazyVM
# trusts, writes or deletes elsewhere (#317). For the same reason a temporary
# file goes in the staging folder (Get-GuestStagingFolder on the host), never
# in $env:TEMP.

function Get-GuestSystemFolder {
    <# The system folder $Name (ProgramFiles, Windows, System...), as Windows has it. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][Environment+SpecialFolder]$Name)

    return [Environment]::GetFolderPath($Name)
}

function Get-GuestSystemDrive {
    <# The drive Windows is on, as 'C:'. #>
    [OutputType([string])]
    param()

    return Split-Path -Path (Get-GuestSystemFolder -Name Windows) -Qualifier
}

function Get-GuestWindowsPowerShell {
    <# Windows PowerShell's powershell.exe, in the system folder. #>
    [OutputType([string])]
    param()

    return [IO.Path]::Combine((Get-GuestSystemFolder -Name System), 'WindowsPowerShell', 'v1.0', 'powershell.exe')
}

function Get-GuestHostsFile {
    <# The guest's hosts file. #>
    [OutputType([string])]
    param()

    return [IO.Path]::Combine((Get-GuestSystemFolder -Name System), 'drivers', 'etc', 'hosts')
}

function Get-GuestVisualStudioInstallerFolder {
    <# The Visual Studio Installer's folder, which holds vswhere.exe, setup.exe and vs_installer.exe. #>
    [OutputType([string])]
    param()

    return [IO.Path]::Combine((Get-GuestSystemFolder -Name ProgramFilesX86), 'Microsoft Visual Studio', 'Installer')
}

# ── Private folders ──────────────────────────────────────────────────────────
#
# A folder only administrators and SYSTEM can change, for files that SYSTEM
# or an administrator runs or trusts: owned by Administrators, nothing
# inherited from the folder above, and full control for SYSTEM and
# Administrators, for the folder, its subfolders and its files. For a task
# that runs as a user under their limited token, which cannot use the
# Administrators entry, the task's folder also lets that user read it, and
# its Output folder lets them change it.
#
# They are kept only under %ProgramFiles%\LazyVM, whose folders only
# administrators, SYSTEM and TrustedInstaller may change (#302): in a folder
# other users can make folders and links in, such as C:\, a check could be
# raced. A folder that is not right is moved aside, never deleted: a
# recursive delete of a tree someone else could change can be led anywhere.

$script:GuestAdministratorsSid = 'S-1-5-32-544'

# The accounts that may own or change the folders above the private ones:
# Administrators, SYSTEM and TrustedInstaller, as TrustedCode.ps1 has them.
$script:GuestTrustedWriters = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

# Rights that change a folder or what is in it, as in TrustedCode.ps1.
$script:GuestWriteRights = [long]0x500D0156

function Get-GuestPrivateFolderAccess {
    <# The access a private folder gives: each security identifier with its rights. #>
    param(
        [string]$ReadSid,
        [string]$ModifySid
    )

    $access = [ordered]@{ 'S-1-5-18' = 'FullControl'; $script:GuestAdministratorsSid = 'FullControl' }
    if ($ReadSid) { $access[$ReadSid] = 'ReadAndExecute' }
    if ($ModifySid) { $access[$ModifySid] = 'Modify' }
    return $access
}

function New-GuestPrivateFolder {
    <#
      A new, empty private folder, for a download that is checked and then
      run, or a task's files. Created with its owner and ACL in one step, and
      checked afterwards, as Windows hands back a folder or link already
      there without applying the ACL. With $ReadSid, that account may read
      it; with $ModifySid, change it. Fails if anything is already at $Path.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ReadSid,
        [string]$ModifySid
    )

    if (Test-Path -LiteralPath $Path) { throw "$Path already exists" }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:GuestAdministratorsSid)))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in (Get-GuestPrivateFolderAccess -ReadSid $ReadSid -ModifySid $ModifySid).GetEnumerator()) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($entry.Key)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $entry.Value, 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $null = [IO.Directory]::CreateDirectory($Path, $acl)
    $problem = Get-GuestPrivateFolderProblem -Path $Path -ReadSid $ReadSid -ModifySid $ModifySid
    if ($problem) { throw "$Path was not made private: $problem" }
}

function Get-GuestFolderAclProblem {
    <#
      Why a folder's ACL ($Acl, as Get-Acl reads it) is not the one
      New-GuestPrivateFolder gives, or '' when it is. Its entries must be
      exactly those of Get-GuestPrivateFolderAccess; Synchronize, which
      Windows adds to every allow entry, is ignored.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Acl,
        [string]$ReadSid,
        [string]$ModifySid
    )

    $owner = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $script:GuestAdministratorsSid) { return "it is owned by $owner, not Administrators" }
    if (-not $Acl.AreAccessRulesProtected) { return 'it inherits access from the folder above' }

    $expected = Get-GuestPrivateFolderAccess -ReadSid $ReadSid -ModifySid $ModifySid
    $synchronize = [System.Security.AccessControl.FileSystemRights]::Synchronize
    $everywhere = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $found = @{}
    foreach ($rule in @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        $sid = $rule.IdentityReference.Value
        $rights = $expected[$sid]
        $matching = $false
        if ($rights -and "$($rule.AccessControlType)" -eq 'Allow' -and $rule.InheritanceFlags -eq $everywhere -and "$($rule.PropagationFlags)" -eq 'None') {
            $matching = ($rule.FileSystemRights -bor $synchronize) -eq ([System.Security.AccessControl.FileSystemRights]$rights -bor $synchronize)
        }
        if (-not $matching) { return "it gives $sid $($rule.AccessControlType) $($rule.FileSystemRights) ($($rule.InheritanceFlags))" }
        $found[$sid] = $true
    }
    foreach ($sid in $expected.Keys) {
        if (-not $found.ContainsKey($sid)) { return "it does not give $sid $($expected[$sid])" }
    }
    return ''
}

function Get-GuestPrivateFolderProblem {
    <# Why what is at $Path is not a private folder (New-GuestPrivateFolder), or '' when it is. $Path must exist. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ReadSid,
        [string]$ModifySid
    )

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return 'it is not a folder' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'it is a junction or link' }
    return Get-GuestFolderAclProblem -Acl (Get-Acl -LiteralPath $Path) -ReadSid $ReadSid -ModifySid $ModifySid
}

function Initialize-GuestPrivateFolder {
    <#
      Makes $Path a private folder (New-GuestPrivateFolder), in a folder only
      administrators can change (Initialize-GuestAdminFolder). A folder
      already there is kept, with what it holds, only when its owner and ACL
      are exactly right; anything else there is moved aside beside it,
      never deleted. Returns @{ Path; Replaced; Reason; MovedTo }.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ReadSid,
        [string]$ModifySid
    )

    $result = [pscustomobject]@{ Path = $Path; Replaced = $false; Reason = ''; MovedTo = '' }
    if (Test-Path -LiteralPath $Path) {
        $result.Reason = Get-GuestPrivateFolderProblem -Path $Path -ReadSid $ReadSid -ModifySid $ModifySid
        if (-not $result.Reason) { return $result }
        $result.Replaced = $true
        $result.MovedTo = '{0}.replaced-{1}' -f $Path, [guid]::NewGuid().ToString('N')
        # A move renames the folder, file or link itself; nothing in it is touched.
        if ((Get-Item -LiteralPath $Path -Force).PSIsContainer) { [IO.Directory]::Move($Path, $result.MovedTo) }
        else { [IO.File]::Move($Path, $result.MovedTo) }
    }
    New-GuestPrivateFolder -Path $Path -ReadSid $ReadSid -ModifySid $ModifySid
    return $result
}

function Get-GuestAdminFolderProblem {
    <#
      Why the folder at $Path, above LazyVM's private folders, is not one
      only administrators, SYSTEM and TrustedInstaller own and can change,
      or '' when it is. A rule for what is inside only does not count.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return 'it is not a folder' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'it is a junction or link' }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($script:GuestTrustedWriters -notcontains $owner) { return "it is owned by $owner, who can change its permissions" }
    foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        $sid = $rule.IdentityReference.Value
        $insideOnly = [bool]($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
        if ("$($rule.AccessControlType)" -ne 'Allow' -or $insideOnly -or $script:GuestTrustedWriters -contains $sid) { continue }
        if ([long]$rule.FileSystemRights -band $script:GuestWriteRights) { return "$sid can change it ($($rule.FileSystemRights))" }
    }
    return ''
}

function New-GuestAdminFolder {
    <#
      A new folder at $Path, above LazyVM's private folders, owned by
      Administrators whatever the token's default owner is, and inheriting
      the access of the folder above it. Only the owner is set: a security
      descriptor given when the folder is made would replace what it
      inherits with an empty list. The folder above, which only
      administrators can change, keeps anyone else out meanwhile.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $null = [IO.Directory]::CreateDirectory($Path)
    $owner = New-Object System.Security.AccessControl.DirectorySecurity
    $owner.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:GuestAdministratorsSid)))
    [IO.Directory]::SetAccessControl($Path, $owner)
}

function Assert-GuestAdminFolder {
    <# Stops, saying why and changing nothing, when the folder at $Path is not one only administrators can change (Get-GuestAdminFolderProblem). #>
    param([Parameter(Mandatory)][string]$Path)

    $problem = Get-GuestAdminFolderProblem -Path $Path
    if ($problem) { throw "$Path is not safe for LazyVM's files: $problem. LazyVM does not change it; an administrator must fix or remove it." }
}

function Initialize-GuestAdminFolder {
    <#
      Makes sure the folder at $Path, above LazyVM's private folders, is one
      only administrators can change. A missing one is made
      (New-GuestAdminFolder). One that is not right is never changed or
      deleted: this stops, saying why.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { New-GuestAdminFolder -Path $Path }
    Assert-GuestAdminFolder -Path $Path
}

function Get-GuestLazyVMFolder {
    <# %ProgramFiles%\LazyVM in the guest, which holds LazyVM's task and staging folders. #>
    [OutputType([string])]
    param()

    return [IO.Path]::Combine((Get-GuestSystemFolder -Name ProgramFiles), 'LazyVM')
}

function Initialize-GuestLazyVMFolder {
    <#
      Makes %ProgramFiles%\LazyVM ready (Initialize-GuestAdminFolder) and
      returns it, once %ProgramFiles% itself is checked; that one is only
      checked, never changed.
    #>
    [OutputType([string])]
    param()

    Assert-GuestAdminFolder -Path (Get-GuestSystemFolder -Name ProgramFiles)
    $lazyVM = Get-GuestLazyVMFolder
    Initialize-GuestAdminFolder -Path $lazyVM
    return $lazyVM
}

function Test-GuestReparsePoint {
    <# Whether what is at $Path is a junction or link (false when nothing is): one a user made would lead a read elsewhere. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return [bool]($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Initialize-GuestStagingFolder {
    <#
      Makes %ProgramFiles%\LazyVM\Staging, where LazyVM stages what it copies
      in and out of the guest, a private folder, and returns
      Initialize-GuestPrivateFolder's result for it.
    #>
    [OutputType([pscustomobject])]
    param()

    return Initialize-GuestPrivateFolder -Path ([IO.Path]::Combine((Initialize-GuestLazyVMFolder), 'Staging'))
}

function Get-GuestAccountSid {
    <# The security identifier of the guest account $UserName. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$UserName)

    $account = New-Object System.Security.Principal.NTAccount($UserName)
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Get-GuestInstallerInstance {
    <#
      Every product the Visual Studio Installer manages (Visual Studio, SSMS,
      Build Tools), as vswhere reports it; nothing when the installer is absent.
      Callers wrap the call in @().
    #>
    $vswhere = Join-Path (Get-GuestVisualStudioInstallerFolder) 'vswhere.exe'
    if (-not (Test-Path $vswhere)) { return }
    $raw = & $vswhere -all -prerelease -products * -format json -utf8 2>$null
    if (-not $raw) { return }

    # Windows PowerShell 5.1 passes a JSON array down the pipeline as ONE
    # object; foreach splits it into its instances.
    foreach ($instance in (($raw -join "`n") | ConvertFrom-Json)) { $instance }
}

function Get-GuestVisualStudioInstaller {
    <# The Visual Studio Installer's setup.exe. Throws when the guest has no installer. #>
    $installer = Join-Path (Get-GuestVisualStudioInstallerFolder) 'setup.exe'
    if (-not (Test-Path $installer)) { throw 'the Visual Studio Installer is not in the guest' }
    return $installer
}

function Get-GuestProcessNameInFolder {
    <# The names of the processes running from $Folder or a folder below it, each once. #>
    param([Parameter(Mandatory)][string]$Folder)

    $prefix = $Folder.TrimEnd('\') + '\'
    return @(Get-CimInstance -ClassName Win32_Process |
            Where-Object { "$($_.ExecutablePath)".StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { $_.Name } | Sort-Object -Unique)
}

# ── Nightly updates from other sources (#293) ────────────────────────────────
#
# The host lists what each source has (Update-GuestSource), each item as
# @{ Name; Label; Version } (Label is what the log calls it), then updates
# each item in a guest call of its own, which returns @{ Version; Notes }:
# the item's version afterwards, or $null, and notes for the log.

function Find-GuestDotnet {
    <# dotnet.exe, or $null when .NET is not installed. #>
    $command = Get-Command -Name dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function ConvertFrom-GuestDotnetToolList {
    <#
      The tools in what dotnet tool list printed, each as @{ Name; Version }:
      the rows under its line of dashes, package id first, version second.
    #>
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][string[]]$Lines = @())

    $inTable = $false
    foreach ($line in $Lines) {
        if ($line -match '^-{3,}\s*$') { $inTable = $true; continue }
        $fields = @($line.Trim() -split '\s+')
        if ($inTable -and $fields.Count -ge 2) { [pscustomobject]@{ Name = $fields[0]; Version = $fields[1] } }
    }
}

function Get-GuestDotnetTool {
    <#
      The dotnet global tools of the account this runs as, each as
      @{ Name; Label; Version }; nothing when .NET is not installed.
    #>
    [OutputType([pscustomobject])]
    param()

    $dotnet = Find-GuestDotnet
    if (-not $dotnet) { return }
    $lines = @(& $dotnet tool list --global 2>&1 | ForEach-Object { "$_" })
    foreach ($tool in @(ConvertFrom-GuestDotnetToolList -Lines $lines)) {
        [pscustomobject]@{ Name = $tool.Name; Label = $tool.Name; Version = $tool.Version }
    }
}

function Invoke-GuestDotnetToolUpdate {
    <#
      Updates the dotnet global tool $Tool (Get-GuestDotnetTool) with dotnet
      tool update, and returns @{ Version; Notes }: its version afterwards,
      or $null when it is no longer listed. Throws with what dotnet said
      when it could not update the tool.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Tool)

    $output = @(& (Find-GuestDotnet) tool update --global $Tool.Name 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool update exit ${LASTEXITCODE}: $(if ($output) { $output[-1] })" }
    $after = Get-GuestDotnetTool | Where-Object { $_.Name -eq $Tool.Name } | Select-Object -First 1
    return [pscustomobject]@{ Version = $(if ($after) { $after.Version }); Notes = @() }
}

function Get-GuestPowerShellEdition {
    <# The PowerShell editions in the guest, each as @{ Edition; Path }: Windows PowerShell, and PowerShell 7 when it is installed. #>
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{ Edition = 'Windows PowerShell'; Path = (Get-GuestWindowsPowerShell) }
    $pwsh = Get-Command -Name pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { [pscustomobject]@{ Edition = 'PowerShell 7'; Path = $pwsh.Source } }
}

function Invoke-GuestPowerShellEdition {
    <#
      Runs $ScriptBlock in a process of the PowerShell at $Path, without its
      profile, and returns its output; throws with its error when it fails.
      Each edition has its own module folders and PowerShellGet, so a module
      is listed and updated by the edition it was installed in.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    # Given a script block, PowerShell passes it and its arguments to the other process encoded, never as text to parse.
    $output = @(& $Path -NoProfile -NonInteractive -Command $ScriptBlock -args $ArgumentList 2>&1)
    $errors = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    if ($LASTEXITCODE -ne 0) { throw $(if ($errors) { "$($errors[-1])" } else { "$Path exited with $LASTEXITCODE" }) }
    return @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

function Get-GuestGalleryModule {
    <#
      The modules installed from the PowerShell Gallery in each PowerShell
      edition, as @{ Items; Notes; Editions }: each item @{ Name; Label;
      Version; Path }, Path being the edition's PowerShell, a note for each
      edition that could not be asked and each module left alone, and the
      editions that were listed. PowerShellGet and PackageManagement are
      left alone: they would be updating themselves, which can leave an
      edition without a working PowerShellGet.
    #>
    [OutputType([pscustomobject])]
    param()

    $leftAlone = @('PowerShellGet', 'PackageManagement')
    $items = @()
    $notes = @()
    $listed = @()
    foreach ($edition in @(Get-GuestPowerShellEdition)) {
        try {
            $modules = @(Invoke-GuestPowerShellEdition -Path $edition.Path -ScriptBlock {
                    Get-InstalledModule -ErrorAction SilentlyContinue | Where-Object { $_.Repository -eq 'PSGallery' } |
                        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = "$($_.Version)" } }
                })
        }
        catch {
            $notes += New-GuestNote -Level WARN -Text "could not list the modules of $($edition.Edition): $($_.Exception.Message)"
            continue
        }
        $listed += $edition.Edition
        foreach ($module in $modules) {
            $label = "$($module.Name) ($($edition.Edition))"
            if ($leftAlone -contains $module.Name) {
                $notes += New-GuestNote -Level INFO -Text "left alone: $label - it would be updating itself; update it by hand when needed"
                continue
            }
            $items += [pscustomobject]@{ Name = $module.Name; Label = $label; Version = $module.Version; Path = $edition.Path }
        }
    }
    return [pscustomobject]@{ Items = $items; Notes = $notes; Editions = $listed }
}

# Old versions of Gallery modules that could not be removed yet, such as
# ones in use, by module label: versions separated by ';' (#293).
$script:GuestModuleRemovalKey = 'HKCU:\SOFTWARE\LazyVM\GalleryModuleRemovals'

function Get-GuestModuleRemovalPending {
    <# The versions of the module labelled $Label recorded as still to be removed. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Label)

    $recorded = Get-ItemProperty -Path $script:GuestModuleRemovalKey -Name $Label -ErrorAction SilentlyContinue
    if (-not $recorded) { return }
    @("$($recorded.$Label)" -split ';' | Where-Object { $_ })
}

function Set-GuestModuleRemovalPending {
    <# Records $Version as the versions of the module labelled $Label still to be removed; with none, forgets the module. #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyCollection()][string[]]$Version = @()
    )

    if (@($Version).Count -eq 0) {
        Remove-ItemProperty -Path $script:GuestModuleRemovalKey -Name $Label -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path -Path $script:GuestModuleRemovalKey)) { $null = New-Item -Path $script:GuestModuleRemovalKey -Force }
    $null = New-ItemProperty -Path $script:GuestModuleRemovalKey -Name $Label -Value ($Version -join ';') -PropertyType String -Force
}

function Remove-GuestModuleRemovalStale {
    <# Forgets the removals recorded for $Edition's modules that are no longer installed there: those whose label is not one of $Label (#309). #>
    param(
        [Parameter(Mandatory)][string]$Edition,
        [AllowEmptyCollection()][string[]]$Label = @()
    )

    $recorded = Get-Item -Path $script:GuestModuleRemovalKey -ErrorAction SilentlyContinue
    if (-not $recorded) { return }
    foreach ($name in @($recorded.Property | Where-Object { $_.EndsWith(" ($Edition)") -and $Label -notcontains $_ })) {
        Set-GuestModuleRemovalPending -Label $name
    }
}

function Invoke-GuestGalleryModuleUpdate {
    <#
      Updates the PowerShell Gallery module $Module (Get-GuestGalleryModule)
      in its own edition, and returns @{ Version; Notes }: its newest version
      afterwards, and a note for each old version removed or not removed.
      Only when the Gallery has a newer version is it installed, beside the
      ones there are and in the scope of the newest copy; nothing is
      reinstalled. That night, the version it made old (the one before the
      newest until then) is removed, so the two newest are kept; any other
      version, such as one kept side by side on purpose, is left alone. A
      version that could not be removed is recorded and tried again each
      night (Get-GuestModuleRemovalPending) until it is removed or gone.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Module)

    $pending = @(Get-GuestModuleRemovalPending -Label $Module.Label)
    $report = Invoke-GuestPowerShellEdition -Path $Module.Path -ArgumentList @($Module.Name, $pending, (Get-GuestSystemFolder -Name ProgramFiles)) -ScriptBlock {
        param($name, $pending, $programFiles)
        $ErrorActionPreference = 'Stop'
        # Windows PowerShell may offer only TLS 1.0, which the Gallery refuses (https://devblogs.microsoft.com/powershell/powershell-gallery-tls-support/).
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # A prerelease label is left out of the comparison: [version] cannot read it, and Windows PowerShell has no semantic version.
        $numeric = { param($version) [version]("$version" -replace '-.*$') }
        $byVersion = { @(Get-InstalledModule -Name $name -AllVersions | Sort-Object { & $numeric $_.Version } -Descending) }

        # A module installed both for all users and for the current user has a copy in each; the newest counts.
        $versions = & $byVersion
        $newest = $versions | Select-Object -First 1
        $latest = Find-Module -Name $name -Repository PSGallery
        $toRemove = @($pending)
        if ((& $numeric $latest.Version) -gt (& $numeric $newest.Version)) {
            $scope = if ("$($newest.InstalledLocation)".StartsWith("$programFiles\", [StringComparison]::OrdinalIgnoreCase)) { 'AllUsers' } else { 'CurrentUser' }
            # -Force lets the new version in beside the old one; it reinstalls nothing, as this version is not installed.
            Install-Module -Name $name -RequiredVersion $latest.Version -Repository PSGallery -Scope $scope -Force
            # A version in both scopes counts once, so the one before the newest is really older (#309).
            $distinct = @($versions | ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
            if ($distinct.Count -ge 2) { $toRemove += $distinct[1] }
        }

        $present = @(& $byVersion | ForEach-Object { "$($_.Version)" })
        $removed = @()
        $notRemoved = @()
        foreach ($version in @($toRemove | Select-Object -Unique)) {
            # A recorded version that is gone, removed by hand say, has nothing left to do.
            if ($present -notcontains $version) { continue }
            try {
                Uninstall-Module -Name $name -RequiredVersion $version
                $removed += $version
            }
            catch { $notRemoved += [pscustomobject]@{ Version = $version; Reason = $_.Exception.Message } }
        }
        [pscustomobject]@{ Version = "$((& $byVersion | Select-Object -First 1).Version)"; Removed = $removed; NotRemoved = $notRemoved }
    } | Select-Object -Last 1

    Set-GuestModuleRemovalPending -Label $Module.Label -Version @($report.NotRemoved | ForEach-Object { "$($_.Version)" })
    $notes = @(foreach ($version in @($report.Removed)) {
            New-GuestNote -Level INFO -Text "removed: $($Module.Label) $version - made old by tonight's update; the two newest versions are kept"
        })
    $notes += @(foreach ($old in @($report.NotRemoved)) { New-GuestNote -Level INFO -Text "not removed yet: $($Module.Label) $($old.Version) - $($old.Reason); tried again tomorrow" })
    return [pscustomobject]@{ Version = $(if ($report) { $report.Version }); Notes = $notes }
}

# ── One-shot scheduled tasks ─────────────────────────────────────────────────
#
# Work that must outlive the PowerShell Direct session (long installers), or
# run in the signed-in user's desktop session (Visual Studio settings), runs
# as a scheduled task. The task runs a fixed wrapper script. The work itself
# and its arguments are written beside it as files, never pasted into script
# text, so no path or value can change what the script does. The wrapper
# writes Output\<task>.done: the work's result, OK, or FAILED: <reason>.
#
# Each task keeps these files, and any file it is given, in a private folder
# of its own, %ProgramFiles%\LazyVM\Tasks\<task> (#302), and its result and
# transcript in the Output folder inside it. A task under a user's limited
# token can read its folder and change only Output, so what it is given
# stays as LazyVM wrote it; its result is only that user's word. As that
# user can make anything in Output a link, administrators never write,
# move or delete there, and read only on one handle checked for links
# (Read-GuestTaskOutputFile; #302, #330). Each start
# gets a nonce in its arguments, which the wrapper writes before the
# result, so a result from an earlier start is never taken for this one.

$script:GuestTaskWrapper = @'
$ErrorActionPreference = 'Stop'
# For the work: its own folder, with what it was given, and where it may write.
$TaskFolder = Split-Path -Path $PSCommandPath -Parent
$TaskOutput = Join-Path $TaskFolder 'Output'
$name = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$base = Join-Path $TaskFolder $name
$done = Join-Path $TaskOutput "$name.done"
$nonce = ''
$transcribing = $false
try { Start-Transcript -Path (Join-Path $TaskOutput "$name.log") -Force | Out-Null; $transcribing = $true } catch { $transcribing = $false }
try {
    $task = Get-Content -LiteralPath "$base.args.json" -Raw | ConvertFrom-Json
    $nonce = "$($task.Nonce)"
    $arguments = @()
    foreach ($item in $task.Arguments) { $arguments += , $item }
    $work = [scriptblock]::Create((Get-Content -LiteralPath "$base.work.ps1" -Raw))
    $result = & $work @arguments
    if ($null -eq $result) { $result = 'OK' }
    "$nonce $(@($result)[-1])" | Set-Content -LiteralPath $done -Encoding UTF8
}
catch { "$nonce FAILED: $($_.Exception.Message)" | Set-Content -LiteralPath $done -Encoding UTF8 }
finally { if ($transcribing) { Stop-Transcript | Out-Null } }
'@

function Get-GuestTaskFolder {
    <# The private folder of task $TaskName, whether or not it exists yet. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$TaskName)

    return [IO.Path]::Combine((Get-GuestLazyVMFolder), 'Tasks', $TaskName)
}

function Get-GuestTaskOutputFolder {
    <# Where task $TaskName writes its result and transcript: Output in its folder, as the wrapper has it. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$TaskName)

    return Join-Path (Get-GuestTaskFolder -TaskName $TaskName) 'Output'
}

function Initialize-GuestTaskFolder {
    <#
      Makes task $TaskName's private folder and its Output folder ready, once
      the folders above are checked, and returns the task's folder. The one
      place that decides who has access: for a task that runs as $UserName
      under their limited token (not -Elevated), that user may read the
      folder and change Output; a full token or SYSTEM needs no entry of its own.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$UserName,
        [switch]$Elevated
    )

    Initialize-GuestAdminFolder -Path ([IO.Path]::Combine((Initialize-GuestLazyVMFolder), 'Tasks'))
    $userSid = if ($UserName -and -not $Elevated) { Get-GuestAccountSid -UserName $UserName } else { '' }
    $folder = Get-GuestTaskFolder -TaskName $TaskName
    $null = Initialize-GuestPrivateFolder -Path $folder -ReadSid $userSid
    $null = Initialize-GuestPrivateFolder -Path (Get-GuestTaskOutputFolder -TaskName $TaskName) -ModifySid $userSid
    return $folder
}

function Start-GuestTask {
    <#
      Writes the wrapper, the work and its arguments, with this start's
      $Nonce, to the task's private folder, registers the task and starts it. As SYSTEM, or with -UserName
      as that signed-in user under their normal (limited) token, or with
      -Elevated their full one. Returns the boot time, so the host can tell
      when the guest restarted.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Work,
        [object[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Nonce,
        [string]$UserName,
        [switch]$Elevated,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $folder = Initialize-GuestTaskFolder -TaskName $TaskName -UserName $UserName -Elevated:$Elevated
    $base = Join-Path $folder $TaskName
    $task = [ordered]@{ Nonce = $Nonce; Arguments = @($ArgumentList) }
    Set-Content -LiteralPath "$base.ps1" -Value $script:GuestTaskWrapper -Encoding UTF8
    Set-Content -LiteralPath "$base.work.ps1" -Value $Work -Encoding UTF8
    Set-Content -LiteralPath "$base.args.json" -Value (ConvertTo-Json -InputObject $task -Depth 6) -Encoding UTF8

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute (Get-GuestWindowsPowerShell) -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$base.ps1`"" -WorkingDirectory $folder
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
    <#
      Done: what the wrapper wrote for the start with $Nonce, or $null while
      it runs; the task's state; the boot time. A result for another start,
      or one Read-GuestTaskOutputFile refuses, counts as none. A task under a
      user's limited token can write its own result, so its Done is only
      that user's word.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Nonce
    )

    $result = $null
    # Not there yet, or not one LazyVM reads (Read-GuestTaskOutputFile): no result.
    try { $bytes = Read-GuestTaskOutputFile -TaskName $TaskName -Name "$TaskName.done" -MaximumBytes $script:GuestTaskResultMaximumBytes }
    catch { $bytes = $null }
    if ($null -ne $bytes) {
        # Windows PowerShell writes UTF-8 with a byte order mark.
        $written = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF).Trim()
        if ($written.StartsWith("$Nonce ")) { $result = $written.Substring($Nonce.Length + 1) }
    }
    return [pscustomobject]@{
        Done      = $result
        TaskState = "$((Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State)"
        BootTime  = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    }
}

# The most Get-GuestTaskStatus reads of a task's result.
$script:GuestTaskResultMaximumBytes = 1MB

# Reads a file in a task's Output folder on one handle (Read-GuestTaskOutputFile).
$script:GuestTaskOutputReaderSource = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LazyVM
{
    public static class TaskOutputReader
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileReadAttributes = 0x80;
        private const uint FileShareRead = 0x1;
        private const uint OpenExisting = 3;
        private const uint FlagBackupSemantics = 0x02000000;
        private const uint FlagOpenReparsePoint = 0x00200000;
        private const uint AttributeDirectory = 0x10;
        private const uint AttributeReparsePoint = 0x400;
        private const int FileAttributeTagInfoClass = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileAttributeTagInfo
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, out FileAttributeTagInfo info, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation info);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);

        private static SafeFileHandle Open(string path, uint access, uint flags)
        {
            SafeFileHandle handle = CreateFileW(path, access, FileShareRead, IntPtr.Zero, OpenExisting, flags, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 3) { throw new FileNotFoundException(path + " is not there"); }
                throw new IOException(path + " cannot be opened: " + new Win32Exception(error).Message);
            }
            return handle;
        }

        private static string FinalPath(SafeFileHandle handle)
        {
            StringBuilder path = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
            if (length == 0 || length >= path.Capacity) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            string text = path.ToString();
            if (text.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) { return @"\\" + text.Substring(8); }
            if (text.StartsWith(@"\\?\", StringComparison.Ordinal)) { return text.Substring(4); }
            return text;
        }

        // The bytes of the file name in folder, read on the one handle that
        // was checked: not a reparse point itself, reached through none
        // (its final path is folder\name under the final path of folder's
        // parent, which only administrators can change), with no other hard
        // link, and no more than maximumBytes.
        public static byte[] Read(string folder, string name, long maximumBytes)
        {
            string full = Path.GetFullPath(folder).TrimEnd('\\', '/');
            string expected;
            using (SafeFileHandle parent = Open(Path.GetDirectoryName(full), FileReadAttributes, FlagBackupSemantics))
            {
                expected = Path.Combine(FinalPath(parent), Path.GetFileName(full), name);
            }
            string path = Path.Combine(full, name);
            using (SafeFileHandle handle = Open(path, GenericRead, FlagOpenReparsePoint))
            {
                FileAttributeTagInfo tag;
                if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfoClass, out tag, (uint)Marshal.SizeOf(typeof(FileAttributeTagInfo))))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if ((tag.FileAttributes & AttributeReparsePoint) != 0) { throw new IOException(path + " is a junction or link, and LazyVM never reads through one"); }
                if ((tag.FileAttributes & AttributeDirectory) != 0) { throw new IOException(path + " is a folder, not a file"); }
                string final = FinalPath(handle);
                if (!string.Equals(final, expected, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException(path + " leads to " + final + " through a junction or link, and LazyVM never reads through one");
                }
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                if (information.NumberOfLinks != 1)
                {
                    throw new IOException(path + " has " + information.NumberOfLinks + " hard links, and LazyVM reads only a file with one");
                }
                long length = ((long)information.FileSizeHigh << 32) | information.FileSizeLow;
                if (length > maximumBytes) { throw new IOException(path + " is " + length + " bytes, over the " + maximumBytes + " LazyVM reads back"); }
                byte[] bytes = new byte[length];
                int read = 0;
                using (FileStream stream = new FileStream(handle, FileAccess.Read))
                {
                    while (read < bytes.Length)
                    {
                        int count = stream.Read(bytes, read, bytes.Length - read);
                        if (count == 0) { break; }
                        read += count;
                    }
                }
                if (read != bytes.Length) { Array.Resize(ref bytes, read); }
                return bytes;
            }
        }
    }
}
'@

function Read-GuestTaskOutputFile {
    <#
      The bytes of the file $Name that task $TaskName wrote in its Output
      folder, for an administrator to read. The task's user can change
      Output, and could put a junction, link or mount point in place of the
      folder or the file between a check and a read, so it is opened once,
      without following a link at the file itself, and everything is
      checked on that handle before it is read from (TaskOutputReader): the
      file is not a reparse point; its final path is Output\$Name, so no
      junction on the way led elsewhere; it has no other hard link, which
      could be a file only administrators may read; and it is no more than
      $MaximumBytes. Throws why not, or that it is not there. What the file
      holds is only that user's word.
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    if (-not ('LazyVM.TaskOutputReader' -as [type])) { Add-Type -TypeDefinition $script:GuestTaskOutputReaderSource }
    try { $bytes = [LazyVM.TaskOutputReader]::Read((Get-GuestTaskOutputFolder -TaskName $TaskName), $Name, $MaximumBytes) }
    catch [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException }
    return , $bytes
}

function Test-GuestLinkOnPath {
    <#
      Whether $Path is not inside $Root, or $Root, a folder below it on the
      way to $Path, or $Path itself is a junction or link, which would lead
      an administrator's read elsewhere.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $separators = [char[]]@('\', '/')
    $current = [IO.Path]::GetFullPath($Root).TrimEnd($separators)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($current + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if (Test-GuestReparsePoint -Path $current) { return $true }
    foreach ($part in $full.Substring($current.Length).Split($separators, [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = [IO.Path]::Combine($current, $part)
        if (Test-GuestReparsePoint -Path $current) { return $true }
    }
    return $false
}

function Remove-GuestTask {
    <#
      Stops the task, then removes it. Removing a running task leaves its
      work running, as a task the host gave up on would be (#262).
    #>
    param([Parameter(Mandatory)][string]$TaskName)

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

# Automatic sign-in (#278). Winlogon signs DefaultUserName in at every start
# while AutoAdminLogon is 1 and there is no AutoLogonCount; with a count, it
# turns automatic sign-in off when the count reaches 0. The password is the
# LSA secret DefaultPassword, as Sysinternals Autologon stores it, never the
# clear-text DefaultPassword registry value. See "MSGina.dll Features" and
# "Protecting the Automatic Logon Password" on Microsoft Learn.
$script:GuestWinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Get-GuestAutoLogonState {
    <#
      Winlogon's automatic sign-in settings, and whether the answer file set
      it up: its first sign-in sets Provisioned at $MarkerKey, which a VM
      built with -NoUnattend never has.
    #>
    param([Parameter(Mandatory)][string]$MarkerKey)

    $winlogon = Get-ItemProperty -Path $script:GuestWinlogonKey
    $marker = Get-ItemProperty -Path $MarkerKey -Name 'Provisioned' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Unattended           = [bool]($marker -and $marker.Provisioned -eq 1)
        AutoAdminLogon       = "$($winlogon.AutoAdminLogon)"
        HasLogonCount        = $null -ne $winlogon.PSObject.Properties['AutoLogonCount']
        HasPlainTextPassword = $null -ne $winlogon.PSObject.Properties['DefaultPassword']
    }
}

function Save-GuestAutoLogonSecret {
    <# Stores $Password as the LSA secret DefaultPassword, which Winlogon reads for automatic sign-in. Throws when LSA refuses. #>
    param([Parameter(Mandatory)][securestring]$Password)

    if (-not ('LazyVM.AutoLogonSecret' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;

namespace LazyVM
{
    public static class AutoLogonSecret
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct LsaUnicodeString
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LsaObjectAttributes
        {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        private const uint PolicyCreateSecret = 0x00000020;

        [DllImport("advapi32.dll")]
        private static extern uint LsaOpenPolicy(IntPtr systemName, ref LsaObjectAttributes objectAttributes, uint desiredAccess, out IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaStorePrivateData(IntPtr policyHandle, ref LsaUnicodeString keyName, ref LsaUnicodeString privateData);

        [DllImport("advapi32.dll")]
        private static extern uint LsaClose(IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern int LsaNtStatusToWinError(uint status);

        private static LsaUnicodeString ToLsaString(IntPtr buffer, int length)
        {
            LsaUnicodeString result = new LsaUnicodeString();
            result.Buffer = buffer;
            result.Length = (ushort)(length * 2);
            result.MaximumLength = (ushort)((length + 1) * 2);
            return result;
        }

        public static void Store(SecureString password)
        {
            LsaObjectAttributes attributes = new LsaObjectAttributes();
            IntPtr policy;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, PolicyCreateSecret, out policy);
            if (status != 0) { throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status), "LsaOpenPolicy failed"); }

            string keyName = "DefaultPassword";
            LsaUnicodeString name = ToLsaString(Marshal.StringToHGlobalUni(keyName), keyName.Length);
            LsaUnicodeString secret = ToLsaString(Marshal.SecureStringToGlobalAllocUnicode(password), password.Length);
            try
            {
                status = LsaStorePrivateData(policy, ref name, ref secret);
                if (status != 0) { throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status), "LsaStorePrivateData failed"); }
            }
            finally
            {
                Marshal.FreeHGlobal(name.Buffer);
                Marshal.ZeroFreeGlobalAllocUnicode(secret.Buffer);
                LsaClose(policy);
            }
        }
    }
}
'@
    }
    [LazyVM.AutoLogonSecret]::Store($Password)
}

function Enable-GuestAutoLogon {
    <#
      Turns automatic sign-in on for the account with no limit: the password
      goes into the LSA secret first, so a refusal changes nothing, then
      Winlogon is pointed at the account, as Sysinternals Autologon does,
      and the logon count and any clear-text password are removed.
    #>
    param([Parameter(Mandatory)][pscredential]$Credential)

    Save-GuestAutoLogonSecret -Password $Credential.Password

    Set-ItemProperty -Path $script:GuestWinlogonKey -Name 'DefaultUserName' -Value $Credential.UserName
    Set-ItemProperty -Path $script:GuestWinlogonKey -Name 'DefaultDomainName' -Value ([Environment]::MachineName)
    Set-ItemProperty -Path $script:GuestWinlogonKey -Name 'AutoAdminLogon' -Value '1'

    $winlogon = Get-ItemProperty -Path $script:GuestWinlogonKey
    foreach ($name in 'AutoLogonCount', 'DefaultPassword') {
        if ($winlogon.PSObject.Properties[$name]) { Remove-ItemProperty -Path $script:GuestWinlogonKey -Name $name }
    }
}

# Event logs, audit policy and PowerShell logging (#291). The host decides
# what to fix (EventLogging.ps1); these read the guest's settings and set
# only what the host sends.

function Invoke-GuestAuditPol {
    <#
      Runs auditpol.exe with $Argument and throws with its output when it
      fails. Windows PowerShell turns a native program's error output into
      errors, which 'Stop' would throw, so it is read as text here.
    #>
    param([Parameter(Mandatory)][string[]]$Argument)

    $output = & { $ErrorActionPreference = 'Continue'; & auditpol.exe @Argument 2>&1 } | Out-String
    if ($LASTEXITCODE -ne 0) { throw "auditpol $($Argument -join ' ') failed (exit $LASTEXITCODE): $($output.Trim())" }
}

function ConvertFrom-AuditPolicyBackup {
    <#
      The setting of each audit subcategory in a file auditpol /backup
      wrote, by subcategory GUID in capitals: 0 none, 1 success, 2 failure,
      3 both. Its option rows, which have no GUID, are left out.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $audit = @{}
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        if ($row.'Subcategory GUID') { $audit[$row.'Subcategory GUID'.ToUpperInvariant()] = [int]$row.'Setting Value' }
    }
    return $audit
}

function Get-GuestLoggingState {
    <#
      The size and mode of each log in $LogName, the audit policy (by
      subcategory GUID) and the value of each registry value in
      $PolicyValue (Path, Name), $null when it is missing. auditpol backs
      the policy up to a file of its own in $Folder, the staging folder,
      which is removed again.
    #>
    param(
        [Parameter(Mandatory)][string[]]$LogName,
        [Parameter(Mandatory)][object[]]$PolicyValue,
        [Parameter(Mandatory)][string]$Folder
    )

    $logs = foreach ($name in $LogName) {
        $log = New-Object -TypeName System.Diagnostics.Eventing.Reader.EventLogConfiguration -ArgumentList $name
        [pscustomobject]@{ Name = $name; MaximumSizeInBytes = $log.MaximumSizeInBytes; LogMode = "$($log.LogMode)" }
    }

    $backup = Join-Path -Path $Folder -ChildPath "LazyVM-auditpol-$([guid]::NewGuid().ToString('N')).csv"
    try {
        Invoke-GuestAuditPol -Argument @('/backup', "/file:$backup")
        $audit = ConvertFrom-AuditPolicyBackup -Path $backup
    }
    finally {
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }

    $values = foreach ($value in $PolicyValue) {
        $item = Get-ItemProperty -LiteralPath $value.Path -Name $value.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{ Path = $value.Path; Name = $value.Name; Value = $(if ($item) { $item.($value.Name) } else { $null }) }
    }

    return [pscustomobject]@{ Logs = @($logs); Audit = $audit; Values = @($values) }
}

function Set-GuestEventLogSize {
    <# Gives the log $Name its size, overwriting its oldest events when full. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$MaximumSizeInBytes
    )

    $log = New-Object -TypeName System.Diagnostics.Eventing.Reader.EventLogConfiguration -ArgumentList $Name
    $log.MaximumSizeInBytes = $MaximumSizeInBytes
    $log.LogMode = [System.Diagnostics.Eventing.Reader.EventLogMode]::Circular
    $log.SaveChanges()
}

function Enable-GuestAuditSubcategory {
    <# Turns on success or failure auditing, or both, for the subcategory $SubcategoryGuid. Never turns any off. #>
    param(
        [Parameter(Mandatory)][string]$SubcategoryGuid,
        [switch]$Success,
        [switch]$Failure
    )

    $argument = @('/set', "/subcategory:$SubcategoryGuid")
    if ($Success) { $argument += '/success:enable' }
    if ($Failure) { $argument += '/failure:enable' }
    Invoke-GuestAuditPol -Argument $argument
}

function Set-GuestPolicyValue {
    <# Sets the DWORD registry value $Name under $Path, creating the key if it is missing. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}
