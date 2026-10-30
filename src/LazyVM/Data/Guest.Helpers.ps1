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
      user under their normal (limited) token. Returns the boot time, so the
      host can tell when the guest restarted.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$SetupDir,
        [Parameter(Mandatory)][string]$Work,
        [object[]]$ArgumentList = @(),
        [string]$UserName,
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
        New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
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
