# Capture.ps1 - Saving what a rebuild would lose to the VM's StateDir on the host.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Files come out of the guest over PowerShell Direct (Copy-VMFile only goes
# the other way). Folders are zipped in the guest first and pulled out as one
# file, far faster than thousands of small files one by one. SQL backups stay
# on the SQL data disk, which no rebuild touches.

function Get-CaptureManifestPath {
    param([Parameter(Mandatory)][VMContext]$VM)

    return Join-Path -Path $VM.Settings.StateDir -ChildPath $script:ManifestFileName
}

function Get-CaptureManifest {
    <# The VM's last capture, or $null when it has none or it cannot be read. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $path = Get-CaptureManifestPath -VM $VM
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [CaptureManifest]::FromJson((Get-Content -LiteralPath $path -Raw)) }
    catch {
        Write-LogEntry "The capture at $path cannot be used: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Save-GuestState {
    <# Captures every area in turn; one that fails is recorded in the manifest's warnings and the rest carry on. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $null = Open-GuestSession -VM $VM -Purpose 'capture its state'

    # Finds the data disk's letter, so SQL backups land in the right place.
    try { Initialize-GuestSqlDisk -VM $VM }
    catch { Write-LogEntry "Could not prepare the data disk: $($_.Exception.Message)" 'WARN' }

    $stateDir = $VM.Settings.StateDir
    foreach ($sub in 'vs', 'windows', 'sql', 'projects', 'apps') { New-Folder -Path (Join-Path $stateDir $sub) }

    $manifest = [CaptureManifest]::new()
    $manifest.CapturedAt = (Get-Date).ToString('o')
    $manifest.CapturedFrom = $VM.Name
    $manifest.Stamp = Get-Stamp

    $run = Invoke-IsolatedStep -What 'capture' -Steps @(
        [pscustomobject]@{ Name = 'Guest'; Action = { Get-GuestIdentity -VM $VM } }
        [pscustomobject]@{ Name = 'VisualStudio'; Action = { Save-GuestVisualStudioState -VM $VM } }
        [pscustomobject]@{ Name = 'Sql'; Action = { Save-GuestSqlState -VM $VM } }
        [pscustomobject]@{ Name = 'Windows'; Action = { Save-GuestWindowsState -VM $VM } }
        [pscustomobject]@{ Name = 'Projects'; Action = { Save-GuestProjectFolder -VM $VM } }
        [pscustomobject]@{ Name = 'AppSettings'; Action = { Save-GuestAppSetting -VM $VM } }
    )
    foreach ($name in $run.Results.Keys) { $manifest.$name = $run.Results[$name] }
    $manifest.Warnings = @($run.Failures | ForEach-Object { "capture of $_" })

    $manifest.Databases = @($manifest.Sql | Where-Object { $_ } | ForEach-Object { @($_.Databases) } | Where-Object { $_ } | ForEach-Object { $_.Name })
    $manifest.Summary = "$($manifest.Databases.Count) database(s) backed up"

    $manifestPath = Get-CaptureManifestPath -VM $VM
    Write-TextFileAtomic -Path $manifestPath -Text $manifest.ToJson()
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stateDir "manifest-$($manifest.Stamp).json") -Force

    Write-LogEntry "Capture written to $manifestPath" 'OK'
    return $manifest
}

function Get-GuestIdentity {
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'guest identity' -TimeoutMinutes 5 -ScriptBlock {
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            UserName     = $env:USERNAME
            OsCaption    = $os.Caption
            OsBuild      = $os.BuildNumber
            InstallDate  = $os.InstallDate.ToString('o')
            TimeZone     = (Get-TimeZone).Id
        }
    }
}

# ── Visual Studio ────────────────────────────────────────────────────────────

function Save-GuestVisualStudioState {
    <#
      Visual Studio's settings, NuGet.Config, .gitconfig and the snippets and
      templates under Documents. Workloads and extensions are recorded in the
      tooling list, and reinstalled from it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $vs = Get-GuestVisualStudio -VM $VM
    if (-not $vs) {
        Write-LogEntry '  Visual Studio is not installed - skipping' 'INFO'
        return $null
    }

    $info = Invoke-GuestScript -VM $VM -Activity 'Visual Studio capture' -TimeoutMinutes 20 -ArgumentList @(
        $VM.Settings.GuestSetupDir, $vs.InstanceId, "$($vs.ProductLine)"
    ) -ScriptBlock {
        param($setupDir, $instanceId, $productLine)
        $ErrorActionPreference = 'Stop'
        New-GuestFolder -Path $setupDir
        $out = [ordered]@{ Settings = $null; NuGetConfig = $null; GitConfig = $null; UserItems = $null; Notes = @() }

        # Visual Studio writes a .vssettings backup every time it closes, so
        # the newest one is the live configuration. The folder is named
        # <version>_<instance id>, which ties it to this Visual Studio.
        $candidates = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*_$instanceId" } |
                ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'Settings') -Filter '*.vssettings' -File -ErrorAction SilentlyContinue } |
                Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -gt 0) { $out.Settings = $candidates[0].FullName }
        else { $out.Notes += New-GuestNote -Level WARN -Text 'no .vssettings backup found (open and close Visual Studio once to create one)' }

        $nuget = Join-Path $env:APPDATA 'NuGet\NuGet.Config'
        if (Test-Path $nuget) { $out.NuGetConfig = $nuget }
        $gitconfig = Join-Path $env:USERPROFILE '.gitconfig'
        if (Test-Path $gitconfig) { $out.GitConfig = $gitconfig }

        $userItems = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Visual Studio $productLine"
        if (Test-Path $userItems) {
            $staging = Join-Path $setupDir 'vs-useritems'
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            New-GuestFolder -Path $staging
            foreach ($name in 'Code Snippets', 'Templates', 'Settings') {
                $source = Join-Path $userItems $name
                if (Test-Path $source) { Copy-Item -Path $source -Destination $staging -Recurse -Force -ErrorAction SilentlyContinue }
            }
            if (@(Get-ChildItem $staging -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
                $out.UserItems = Join-Path $setupDir 'vs-useritems.zip'
                New-GuestZip -Source $staging -Destination $out.UserItems
            }
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]$out
    }

    $captured = [ordered]@{
        DisplayName = $vs.DisplayName
        Version     = $vs.Version
        ProductLine = "$($vs.ProductLine)"
        Files       = [ordered]@{}
    }
    $vsDir = Join-Path $VM.Settings.StateDir 'vs'
    $pulls = @(
        [pscustomobject]@{ Guest = $info.Settings; Name = 'VisualStudio.vssettings'; Key = 'Settings' }
        [pscustomobject]@{ Guest = $info.NuGetConfig; Name = 'NuGet.Config'; Key = 'NuGetConfig' }
        [pscustomobject]@{ Guest = $info.GitConfig; Name = 'gitconfig'; Key = 'GitConfig' }
        [pscustomobject]@{ Guest = $info.UserItems; Name = 'vs-useritems.zip'; Key = 'UserItems' }
    )
    foreach ($pull in @($pulls | Where-Object { $_.Guest })) {
        $destination = Join-Path $vsDir $pull.Name
        try {
            Copy-FromGuest -VM $VM -GuestPath $pull.Guest -HostPath $destination
            $captured.Files[$pull.Key] = $destination
            Write-LogEntry "  $($pull.Name)" 'OK'
        }
        catch {
            Write-LogEntry "  could not retrieve $($pull.Name): $($_.Exception.Message)" 'WARN'
        }
    }

    # The build's settings step applies VSSettingsBackup, so the captured
    # settings go there.
    if ($captured.Files.Contains('Settings')) {
        Copy-Item -LiteralPath $captured.Files['Settings'] -Destination $VM.Settings.VSSettingsBackup -Force -ErrorAction SilentlyContinue
    }

    Write-LogEntry "  Visual Studio: $($vs.DisplayName)" 'OK'
    Write-GuestNote -Notes $info.Notes
    return [pscustomobject]$captured
}

# ── SQL Server ───────────────────────────────────────────────────────────────

function Save-GuestSqlState {
    <# Backs up every user database to the data disk, checks each backup, and records logins and instance settings. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $instance = Connect-GuestSqlInstance -VM $VM
    if (-not $instance) {
        Write-LogEntry '  SQL Server is not installed - skipping' 'INFO'
        return $null
    }
    $server = $VM.Runtime.SqlServer
    $backupDir = $VM.Runtime.GuestSqlBackupDir

    $state = Invoke-GuestScript -VM $VM -Activity 'SQL logins and settings capture' -TimeoutMinutes 10 -ArgumentList @($server) -ScriptBlock {
        param($server)
        $ErrorActionPreference = 'Stop'
        $connection = Open-GuestSqlConnection -Server $server
        try {
            $version = @(Get-GuestSqlRow -Connection $connection -Sql "SELECT SERVERPROPERTY('ProductVersion') AS V, SERVERPROPERTY('Edition') AS E, @@SERVICENAME AS S")[0]
            $databases = @(Get-GuestSqlRow -Connection $connection -Sql "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' AND is_read_only = 0" | ForEach-Object { "$($_.name)" })

            # SID and password hash are kept, so database users are not
            # orphaned when the databases are restored into a new instance.
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

            # What a capture knowingly does not bring across.
            $notMigrated = @()
            foreach ($check in @(
                    @{ What = 'SQL Agent jobs'; Sql = 'SELECT name FROM msdb.dbo.sysjobs' }
                    @{ What = 'linked servers'; Sql = 'SELECT name FROM sys.servers WHERE server_id <> 0' }
                    @{ What = 'credentials'; Sql = 'SELECT name FROM sys.credentials' })) {
                $names = @(Get-GuestSqlRow -Connection $connection -Sql $check.Sql | ForEach-Object { "$($_.name)" })
                if ($names.Count -gt 0) { $notMigrated += "$($check.What): $($names -join ', ')" }
            }

            return [pscustomobject]@{
                Instance = "$($version.S)"; Version = "$($version.V)"; Edition = "$($version.E)"
                DatabaseNames = $databases; Logins = $logins; Configs = $configs; NotMigrated = $notMigrated
            }
        }
        finally { $connection.Close() }
    }

    $backups = @(foreach ($name in @($state.DatabaseNames)) {
            Backup-GuestDatabase -VM $VM -Name $name -BackupDir $backupDir
        })

    $total = ($backups | Measure-Object -Property SizeBytes -Sum).Sum
    Write-LogEntry "  SQL $($state.Version) ($($state.Edition)): $($backups.Count) database(s), $(Format-Size ([double]$total)) of backups, $(@($state.Logins).Count) login(s)" 'OK'
    Write-LogEntry "  Backups stay on the data disk ($backupDir), which survives the rebuild" 'INFO'
    foreach ($item in @($state.NotMigrated)) { Write-LogEntry "  NOT migrated automatically - $item" 'WARN' }

    return [pscustomobject]@{
        Instance    = $state.Instance
        Version     = $state.Version
        Edition     = $state.Edition
        BackupDir   = $backupDir
        Databases   = $backups
        Logins      = @($state.Logins)
        Configs     = @($state.Configs)
        NotMigrated = @($state.NotMigrated)
    }
}

function Backup-GuestDatabase {
    <# Backs up one database to <BackupDir>\<name>.bak and proves the backup readable. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BackupDir
    )

    return Invoke-GuestScript -VM $VM -Activity "backing up $Name" -TimeoutMinutes 180 -ArgumentList @($VM.Runtime.SqlServer, $Name, $BackupDir) -ScriptBlock {
        param($server, $name, $backupDir)
        $ErrorActionPreference = 'Stop'
        New-GuestFolder -Path $backupDir
        $file = Join-Path $backupDir "$name.bak"
        $target = "$(ConvertTo-SqlName -Name $name) TO DISK = $(ConvertTo-SqlString -Text $file)"
        $connection = Open-GuestSqlConnection -Server $server
        try {
            # COMPRESSION is unavailable on some editions; retry without it.
            try { $null = Invoke-GuestSql -Connection $connection -Sql "BACKUP DATABASE $target WITH INIT, FORMAT, CHECKSUM, COMPRESSION, STATS = 10" }
            catch { $null = Invoke-GuestSql -Connection $connection -Sql "BACKUP DATABASE $target WITH INIT, FORMAT, CHECKSUM, STATS = 10" }
            $null = Invoke-GuestSql -Connection $connection -Sql "RESTORE VERIFYONLY FROM DISK = $(ConvertTo-SqlString -Text $file) WITH CHECKSUM"

            $details = @(Get-GuestSqlRow -Connection $connection -Sql "SELECT recovery_model_desc AS Recovery, compatibility_level AS CompatLevel, collation_name AS Collation FROM sys.databases WHERE name = $(ConvertTo-SqlString -Text $name)")[0]
            return [pscustomobject]@{
                Name        = $name
                BackupFile  = $file
                SizeBytes   = (Get-Item $file).Length
                Recovery    = "$($details.Recovery)"
                CompatLevel = [int]$details.CompatLevel
                Collation   = "$($details.Collation)"
            }
        }
        finally { $connection.Close() }
    }
}

# ── Windows environment ──────────────────────────────────────────────────────
#
# Each part is saved into a staging folder in the guest by a call of its
# own, then the folder is zipped and pulled out as winstate.zip. The
# environment itself is recorded in VM.json instead (GuestEnvironment.ps1).

function Save-GuestWindowsState {
    param([Parameter(Mandatory)][VMContext]$VM)

    $staging = Join-Path $VM.Settings.GuestSetupDir 'winstate'
    $null = Invoke-GuestScript -VM $VM -Activity 'Windows capture staging' -TimeoutMinutes 5 -ArgumentList @($staging) -ScriptBlock {
        param($staging)
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($folder in $staging, (Join-Path $staging 'certs'), (Join-Path $staging 'tasks')) { New-GuestFolder -Path $folder }
    }

    # The environment is plain data, so it is recorded in VM.json (#131), not the archive.
    try { $null = Update-GuestEnvironmentRecord -VM $VM }
    catch { Write-LogError '  The guest environment could not be recorded; VM.json keeps what it had' $_ }

    $certificates = Save-GuestCertificate -VM $VM -Staging $staging
    $firewall = Save-GuestFirewallRule -VM $VM -Staging $staging
    $tasks = Save-GuestScheduledTask -VM $VM -Staging $staging

    $summary = [pscustomobject]@{
        Certificates   = @($certificates.Certificates)
        FirewallRules  = $firewall
        ScheduledTasks = @($tasks.Tasks)
    }
    $zip = Invoke-GuestScript -VM $VM -Activity 'Windows capture archive' -TimeoutMinutes 15 -ArgumentList @($staging, ($summary | ConvertTo-Json -Depth 8), $VM.Settings.GuestSetupDir) -ScriptBlock {
        param($staging, $summaryJson, $setupDir)
        Set-Content -Path (Join-Path $staging 'environment.json') -Value $summaryJson -Encoding UTF8
        $zip = Join-Path $setupDir 'winstate.zip'
        New-GuestZip -Source $staging -Destination $zip
        return $zip
    }

    $archive = Join-Path (Join-Path $VM.Settings.StateDir 'windows') 'winstate.zip'
    Copy-FromGuest -VM $VM -GuestPath $zip -HostPath $archive

    Write-LogEntry ("  windows: {0} certificate(s), {1} firewall rule(s), {2} task(s)" -f $summary.Certificates.Count, $firewall, $summary.ScheduledTasks.Count) 'OK'
    Write-GuestNote -Notes (@($certificates.Notes) + @($tasks.Notes))

    return [pscustomobject]@{
        Archive        = $archive
        Certificates   = $summary.Certificates
        FirewallRules  = $firewall
        ScheduledTasks = $summary.ScheduledTasks
    }
}

function Save-GuestCertificate {
    <#
      Personal certificates, and self-signed roots, which is where developer
      and local HTTPS certificates live, as .pfx with their keys where the key
      can be exported and .cer otherwise. The stock trust list comes back with
      a fresh Windows install anyway.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The certificate PFX password has to cross into the guest as text, where it becomes a SecureString again.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The PFX password arrives in the guest as text and becomes a SecureString there.')]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Staging
    )

    $password = (Get-OrNewStoredCredential -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.CertCredFile -UserName 'certs').Credential.Password
    return Invoke-GuestScript -VM $VM -Activity 'certificate capture' -TimeoutMinutes 10 -ArgumentList @($Staging, (ConvertTo-PlainText -Secure $password)) -ScriptBlock {
        param($staging, $certPassword)
        $securePassword = ConvertTo-SecureString -String $certPassword -AsPlainText -Force
        $out = @{ Certificates = @(); Notes = @() }
        foreach ($store in 'Cert:\LocalMachine\My', 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\Root') {
            foreach ($cert in @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue)) {
                # In the root store, only certificates someone made themselves.
                if ($store -eq 'Cert:\LocalMachine\Root' -and $cert.Issuer -ne $cert.Subject) { continue }
                if ($store -eq 'Cert:\LocalMachine\Root' -and $cert.Subject -match '(?i)microsoft|verisign|digicert|globalsign|baltimore|thawte|entrust|sectigo|comodo|go daddy|symantec|starfield|usertrust') { continue }
                $file = Join-Path $staging "certs\$($cert.Thumbprint).pfx"
                try { Export-PfxCertificate -Cert $cert -FilePath $file -Password $securePassword -ErrorAction Stop | Out-Null }
                catch {
                    # No exportable private key: a .cer still restores trust.
                    $file = Join-Path $staging "certs\$($cert.Thumbprint).cer"
                    try { Export-Certificate -Cert $cert -FilePath $file -ErrorAction Stop | Out-Null }
                    catch {
                        $out.Notes += New-GuestNote -Level WARN -Text "certificate $($cert.Thumbprint) could not be exported: $($_.Exception.Message)"
                        continue
                    }
                }
                $out.Certificates += [pscustomobject]@{
                    Thumbprint = $cert.Thumbprint
                    Subject    = "$($cert.Subject)"
                    Store      = $store
                    File       = [IO.Path]::GetFileName($file)
                    HasKey     = ($file -like '*.pfx')
                    NotAfter   = $cert.NotAfter.ToString('o')
                }
            }
        }
        return [pscustomobject]$out
    }
}

function Save-GuestFirewallRule {
    <# Firewall rules added in the guest: built-in ones belong to a group; LazyVM's own are left out. Returns how many. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Staging
    )

    return Invoke-GuestScript -VM $VM -Activity 'firewall capture' -TimeoutMinutes 10 -ArgumentList @($Staging, $script:TaskPrefix) -ScriptBlock {
        param($staging, $excludePrefix)
        $rules = @(foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { -not $_.Group -and $_.Enabled -eq 'True' -and $_.DisplayName -notlike "$excludePrefix*" })) {
                $ports = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                $addresses = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    DisplayName   = $rule.DisplayName
                    Direction     = "$($rule.Direction)"
                    Action        = "$($rule.Action)"
                    Protocol      = "$($ports.Protocol)"
                    LocalPort     = @($ports.LocalPort)
                    RemoteAddress = @($addresses.RemoteAddress)
                    Profile       = "$($rule.Profile)"
                }
            })
        ConvertTo-Json -InputObject $rules -Depth 5 | Set-Content (Join-Path $staging 'firewall.json') -Encoding UTF8
        return $rules.Count
    }
}

function Save-GuestScheduledTask {
    <# Scheduled tasks someone created in the root folder, as XML; LazyVM's own are left out. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Staging
    )

    return Invoke-GuestScript -VM $VM -Activity 'scheduled task capture' -TimeoutMinutes 10 -ArgumentList @($Staging, $script:TaskPrefix) -ScriptBlock {
        param($staging, $excludePrefix)
        $out = @{ Tasks = @(); Notes = @() }
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -notlike "$excludePrefix*" })) {
            try {
                $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
                $safe = ($task.TaskName -replace '[\\/:*?"<>|]', '_')
                $xml | Set-Content (Join-Path $staging "tasks\$safe.xml") -Encoding Unicode
                $out.Tasks += $task.TaskName
            }
            catch {
                $out.Notes += New-GuestNote -Level WARN -Text "scheduled task '$($task.TaskName)' could not be exported: $($_.Exception.Message)"
            }
        }
        return [pscustomobject]$out
    }
}

# ── Project files and application settings ───────────────────────────────────

function Save-GuestProjectFolder {
    <#
      Anything in GuestProjectPaths, which are on the guest's own disk.
      Source on the Dev Drive needs no capture: that disk persists across
      rebuilds, and source control backs it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $result = Invoke-GuestScript -VM $VM -Activity 'project capture' -TimeoutMinutes 60 -ArgumentList @(
        $settings.GuestSetupDir, $settings.GuestProjectPaths, $settings.ProjectExcludeDirs, $settings.MaxProjectCaptureGB
    ) -ScriptBlock {
        param($setupDir, $paths, $excludes, $maxGB)
        $ErrorActionPreference = 'Stop'
        $staging = Join-Path $setupDir 'projects'
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        New-GuestFolder -Path $staging

        $included = @(); $notes = @(); $bytes = 0
        foreach ($raw in $paths) {
            $path = [Environment]::ExpandEnvironmentVariables($raw)
            if (-not (Test-Path $path)) { continue }

            $name = Split-Path $path -Leaf
            $destination = Join-Path $staging $name
            $i = 1
            while (Test-Path $destination) { $destination = Join-Path $staging "$name-$i"; $i++ }

            # Build outputs and package caches can be made again; copying them
            # would only make the archive bigger.
            $robocopyArgs = @($path, $destination, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            if (@($excludes).Count -gt 0) { $robocopyArgs += '/XD'; $robocopyArgs += $excludes }
            & robocopy.exe @robocopyArgs | Out-Null
            if ($LASTEXITCODE -ge 8) { $notes += New-GuestNote -Level WARN -Text "skipped $path (robocopy exit $LASTEXITCODE)"; continue }

            $size = [double](Get-ChildItem $destination -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if (($bytes + $size) -gt ($maxGB * 1GB)) {
                Remove-Item $destination -Recurse -Force -ErrorAction SilentlyContinue
                $notes += New-GuestNote -Level WARN -Text "skipped $path (would exceed the ${maxGB} GB capture limit)"
                continue
            }
            $bytes += $size
            $included += $path
        }

        $zip = $null
        if ($included.Count -gt 0) {
            $zip = Join-Path $setupDir 'projects.zip'
            New-GuestZip -Source $staging -Destination $zip
        }
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Zip = $zip; Included = $included; Notes = $notes; Bytes = $bytes }
    }

    Write-GuestNote -Notes $result.Notes
    if (-not $result.Zip) {
        Write-LogEntry '  no guest-side project files found' 'INFO'
        return $null
    }

    $archive = Join-Path (Join-Path $settings.StateDir 'projects') 'projects.zip'
    Copy-FromGuest -VM $VM -GuestPath $result.Zip -HostPath $archive
    Write-LogEntry "  projects: $(@($result.Included).Count) folder(s), $(Format-Size $result.Bytes) -> $(Format-Size (Get-Item $archive).Length) compressed" 'OK'
    return [pscustomobject]@{ Archive = $archive; Included = @($result.Included); Bytes = $result.Bytes }
}

function Save-GuestAppSetting {
    <#
      Exports each registry key in AppSettings to <StateDir>\apps\<Name>.reg.
      A key that does not exist yet (the application was never started) is
      skipped, not an error.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $saved = @()
    foreach ($entry in @($VM.Settings.AppSettings)) {
        $name = "$($entry['Name'])"
        $key = "$($entry['RegistryKey'])"
        $guestFile = Join-Path $VM.Settings.GuestSetupDir "app-$name.reg"

        $exported = Invoke-GuestScript -VM $VM -Activity "$name settings export" -TimeoutMinutes 5 -ArgumentList @($key, $guestFile) -ScriptBlock {
            param($key, $file)
            New-GuestFolder -Path (Split-Path $file -Parent)
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            & reg.exe export $key $file /y 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0 -and (Test-Path $file))
        }
        if (-not $exported) {
            Write-LogEntry "  $name - no settings in the registry yet ($key)" 'INFO'
            continue
        }
        $hostFile = Join-Path (Join-Path $VM.Settings.StateDir 'apps') "$name.reg"
        Copy-FromGuest -VM $VM -GuestPath $guestFile -HostPath $hostFile
        Write-LogEntry "  $name settings" 'OK'
        $saved += [pscustomobject]@{ Name = $name; RegistryKey = $key; File = $hostFile }
    }
    return $saved
}
