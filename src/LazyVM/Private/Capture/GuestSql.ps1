# GuestSql.ps1 - The guest's SQL Server logins, instance settings and Agent objects, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Logins, their server roles and the instance settings are plain data, so
# they live in VM.json's GuestSql (#131), recorded on every maintenance run
# and every capture, whenever they changed. A SQL login keeps its SID and
# password hash, never the password, so database users are not orphaned
# when the databases come back in a new instance. The databases themselves
# stay on the SQL data disk (Capture.ps1); Agent jobs, operators and alerts
# are read and recreated by GuestSqlAgent.ps1.

function Get-GuestSqlSnapshot {
    <#
      Reads the instance's logins (Logins) and its settings (Configs) from
      the instance Connect-GuestSqlInstance found.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'SQL logins and settings check' -TimeoutMinutes 10 -ArgumentList @($VM.Runtime.SqlServer) -ScriptBlock {
        param($server)
        $ErrorActionPreference = 'Stop'
        $connection = Open-GuestSqlConnection -Server $server
        try {
            $logins = @(foreach ($login in @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT sp.name, sp.type_desc AS TypeDesc, sp.is_disabled AS IsDisabled,
       sp.default_database_name AS DefaultDb, sp.default_language_name AS DefaultLang,
       CONVERT(varchar(max), sp.sid, 1) AS SidHex,
       CONVERT(varchar(max), sl.password_hash, 1) AS HashHex,
       sl.is_policy_checked AS PolicyChecked, sl.is_expiration_checked AS ExpirationChecked
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G') AND sp.name NOT LIKE '##%' AND sp.name NOT LIKE 'NT %'
  AND sp.name <> 'sa' AND sp.name NOT LIKE 'BUILTIN\%'
'@)) {
                    $roles = @(Get-GuestSqlRow -Connection $connection -Sql "SELECT r.name FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id = m.role_principal_id JOIN sys.server_principals p ON p.principal_id = m.member_principal_id WHERE p.name = $(ConvertTo-SqlString -Text "$($login.name)")" | ForEach-Object { "$($_.name)" })
                    [pscustomobject]@{
                        Name              = "$($login.name)"
                        TypeDesc          = "$($login.TypeDesc)"
                        IsDisabled        = [bool]$login.IsDisabled
                        DefaultDb         = "$($login.DefaultDb)"
                        DefaultLang       = "$($login.DefaultLang)"
                        SidHex            = "$($login.SidHex)"
                        HashHex           = "$($login.HashHex)"
                        PolicyChecked     = [bool]$login.PolicyChecked
                        ExpirationChecked = [bool]$login.ExpirationChecked
                        ServerRoles       = $roles
                    }
                })

            $configs = @(Get-GuestSqlRow -Connection $connection -Sql 'SELECT name, value_in_use FROM sys.configurations WHERE value <> value_in_use OR value_in_use <> 0' |
                    ForEach-Object { [pscustomobject]@{ Name = "$($_.name)"; Value = "$($_.value_in_use)" } })

            # database_id 1-4 are master, tempdb, model and msdb.
            $files = @(Get-GuestSqlRow -Connection $connection -Sql 'SELECT d.name AS DbName, mf.physical_name AS PhysicalName FROM sys.master_files mf JOIN sys.databases d ON d.database_id = mf.database_id WHERE d.database_id > 4 ORDER BY d.name, mf.file_id')
            $databases = @($files | Group-Object -Property DbName | ForEach-Object {
                    [pscustomobject]@{ Name = $_.Name; Files = @($_.Group | ForEach-Object { "$($_.PhysicalName)" }) }
                })

            return [pscustomobject]@{ Logins = $logins; Configs = $configs; Databases = $databases }
        }
        finally { $connection.Close() }
    }
}

function ConvertTo-GuestSqlRecord {
    <#
      Turns what the guest reported ($Snapshot, from Get-GuestSqlSnapshot)
      into VM.json's GuestSql, everything sorted by name so the same state
      always compares equal.
    #>
    param([Parameter(Mandatory)][object]$Snapshot)

    $configs = @(foreach ($config in @($Snapshot.Configs | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{ Name = [string]$config.Name; Value = [long]$config.Value }
        })
    $logins = @(foreach ($login in @($Snapshot.Logins | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{
                Name              = [string]$login.Name
                TypeDesc          = [string]$login.TypeDesc
                IsDisabled        = [bool]$login.IsDisabled
                DefaultDb         = [string]$login.DefaultDb
                DefaultLang       = [string]$login.DefaultLang
                SidHex            = [string]$login.SidHex
                HashHex           = [string]$login.HashHex
                PolicyChecked     = [bool]$login.PolicyChecked
                ExpirationChecked = [bool]$login.ExpirationChecked
                ServerRoles       = @($login.ServerRoles | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object)
            }
        })
    # Files stay in file order: attaching needs the primary data file first.
    $databases = @(foreach ($database in @($Snapshot.Databases | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{ Name = [string]$database.Name; Files = @($database.Files | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        })
    return [ordered]@{ Configs = $configs; Logins = $logins; Databases = $databases }
}

function Update-GuestSqlRecord {
    <#
      Records the guest's SQL logins, instance settings and Agent jobs,
      operators and alerts as they are now in VM.json. A guest without SQL Server keeps what was recorded, so an
      install that failed cannot erase the logins a rebuild needs. Writes
      nothing when nothing changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not (Connect-GuestSqlInstance -VM $VM)) {
        Write-LogEntry '  SQL Server is not installed - its logins were not recorded' 'INFO'
        return $false
    }
    $record = ConvertTo-GuestSqlRecord -Snapshot (Get-GuestSqlSnapshot -VM $VM)
    $record.Agent = ConvertTo-GuestSqlAgentRecord -Snapshot (Get-GuestSqlAgentSnapshot -VM $VM)

    $change = @{ $script:GuestSqlSettingName = $record }
    $changed = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest SQL logins, settings or Agent objects changed').Count -gt 0
    if ($changed) { Write-LogEntry "Guest SQL recorded: $($record.Logins.Count) login(s), $($record.Configs.Count) instance setting(s), $($record.Databases.Count) database(s), $($record.Agent.Jobs.Count) Agent job(s)" 'OK' }
    return $changed
}

function Get-GuestSqlRestore {
    <#
      What a restore puts back into the guest's SQL Server: VM.json's
      GuestSql as the file holds it now, as Configs, Logins, Databases (empty
      when recorded before #132) and Agent ($null when recorded before Agent
      objects were). $null when it was never recorded, so a capture from
      before #131 is used instead.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $sql = $current[$script:GuestSqlSettingName]
    if ($null -eq $sql) { return $null }
    return [pscustomobject]@{ Configs = @($sql.Configs); Logins = @($sql.Logins); Databases = @($sql['Databases'] | Where-Object { $_ }); Agent = $sql['Agent'] }
}
