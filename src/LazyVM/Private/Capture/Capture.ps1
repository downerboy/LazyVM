# Capture.ps1 - Saving what a rebuild would lose to the VM's StateDir on the host,
# one folder per capture under StateDir\Captures, the newest three kept.
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
    <#
      Captures every area in turn into a folder of its own,
      StateDir\Captures\<stamp> (#21); one that fails is recorded in the
      manifest's warnings and the rest carry on. The manifest goes in that
      folder and, as the newest capture, to StateDir\manifest.json, which
      restore reads. Then the older captures are pruned.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $null = Open-GuestSession -VM $VM -Purpose 'capture its state'

    # Finds the data disk's letter, so SQL backups land in the right place.
    try { Initialize-GuestSqlDisk -VM $VM }
    catch { Write-LogEntry "Could not prepare the data disk: $($_.Exception.Message)" 'WARN' }

    $manifest = [CaptureManifest]::new()
    $manifest.CapturedAt = (Get-Date).ToString('o')
    $manifest.CapturedFrom = $VM.Name
    $manifest.Stamp = Get-Stamp

    $captureDir = Join-Path (Join-Path $VM.Settings.StateDir $script:CaptureFolderName) $manifest.Stamp
    New-Folder -Path $captureDir

    $run = Invoke-IsolatedStep -What 'capture' -Steps @(
        [pscustomobject]@{ Name = 'Guest'; Action = { Get-GuestIdentity -VM $VM } }
        [pscustomobject]@{ Name = 'VisualStudio'; Action = { Save-GuestVisualStudioState -VM $VM -CaptureDir $captureDir } }
        [pscustomobject]@{ Name = 'Sql'; Action = { Save-GuestSqlState -VM $VM } }
        [pscustomobject]@{ Name = 'Windows'; Action = { Save-GuestWindowsState -VM $VM -CaptureDir $captureDir } }
        [pscustomobject]@{ Name = 'AppSettings'; Action = { Save-GuestAppSetting -VM $VM } }
    )
    foreach ($name in $run.Results.Keys) { $manifest.$name = $run.Results[$name] }
    $manifest.Warnings = @($run.Failures | ForEach-Object { "capture of $_" })

    # Without a fingerprint the next daily run simply captures again (#20).
    try { $manifest.Fingerprint = Get-GuestStateFingerprint -VM $VM }
    catch { Write-LogEntry "Could not take the state fingerprint: $($_.Exception.Message)" 'WARN' }

    $manifest.Databases = @($manifest.Sql | Where-Object { $_ } | ForEach-Object { @($_.Databases) } | Where-Object { $_ } | ForEach-Object { $_.Name })
    $manifest.Summary = "$($manifest.Databases.Count) database(s) backed up"

    $json = $manifest.ToJson()
    Write-TextFileAtomic -Path (Join-Path $captureDir $script:ManifestFileName) -Text $json
    $manifestPath = Get-CaptureManifestPath -VM $VM
    Write-TextFileAtomic -Path $manifestPath -Text $json
    Write-LogEntry "Capture written to $captureDir" 'OK'

    Remove-OldCapture -VM $VM
    return $manifest
}

function Remove-OldCapture {
    <#
      Keeps the newest CapturesToKeep capture folders under StateDir\Captures
      and deletes the older ones (#21), with the manifest-<stamp>.json copies
      earlier versions left in StateDir. Only folders named like a stamp are
      touched. A folder that cannot be deleted is logged and left for the
      next capture.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $stateDir = $VM.Settings.StateDir
    $captures = @(Get-ChildItem -LiteralPath (Join-Path $stateDir $script:CaptureFolderName) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object -Property Name -Descending)
    $copies = @(Get-ChildItem -LiteralPath $stateDir -Filter 'manifest-*.json' -File -ErrorAction SilentlyContinue)
    $old = @($captures | Select-Object -Skip $script:CapturesToKeep) + $copies
    foreach ($item in $old) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            Write-LogEntry "  removed the old capture $($item.Name)" 'INFO'
        }
        catch { Write-LogEntry "  could not remove the old capture $($item.FullName): $($_.Exception.Message)" 'WARN' }
    }
}

function Get-GuestStateFingerprint {
    <#
      A cheap fingerprint of what a capture keeps that the daily records in
      VM.json do not (#20): the certificates a capture would export, by
      thumbprint, and the live Visual Studio settings, by hash.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $vs = Get-GuestVisualStudio -VM $VM
    $instanceId = if ($vs) { "$($vs.InstanceId)" } else { '' }
    $snapshot = Invoke-GuestScript -VM $VM -Activity 'state fingerprint' -TimeoutMinutes 5 -ArgumentList @($instanceId) -ScriptBlock {
        param($instanceId)
        $ErrorActionPreference = 'Stop'
        $settings = if ($instanceId) { Get-GuestVisualStudioSettingsFile -InstanceId $instanceId } else { $null }
        return [pscustomobject]@{
            Thumbprints              = @(Get-GuestCapturedCertificate | ForEach-Object { $_.Certificate.Thumbprint })
            VisualStudioSettingsHash = if ($settings) { (Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash } else { '' }
        }
    }
    return ConvertTo-GuestStateFingerprint -Snapshot $snapshot
}

function ConvertTo-GuestStateFingerprint {
    <# The fingerprint from what the guest reported: thumbprints sorted and without repeats, so the same certificates always compare equal. #>
    param([Parameter(Mandatory)][object]$Snapshot)

    return [ordered]@{
        Certificates         = (@($Snapshot.Thumbprints | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() } | Sort-Object -Unique) -join ',')
        VisualStudioSettings = [string]$Snapshot.VisualStudioSettingsHash
    }
}

function Test-GuestStateChanged {
    <#
      Whether the guest has changed since its newest capture in a way only a
      capture keeps (#20): true when there is no capture, or no fingerprint
      in it, or the fingerprint differs. Logs what changed.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $recorded = (Get-CaptureManifest -VM $VM)
    if (-not $recorded -or -not $recorded.Fingerprint) {
        Write-LogEntry 'No state fingerprint recorded yet - capturing' 'INFO'
        return $true
    }
    $current = Get-GuestStateFingerprint -VM $VM
    $changed = @($current.Keys | Where-Object { "$($current[$_])" -ne "$($recorded.Fingerprint.$_)" })
    if ($changed.Count -eq 0) { return $false }
    Write-LogEntry "Changed since the last capture: $($changed -join ', ') - capturing" 'INFO'
    return $true
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
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$CaptureDir
    )

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

        $out.Settings = Get-GuestVisualStudioSettingsFile -InstanceId $instanceId
        if (-not $out.Settings) { $out.Notes += New-GuestNote -Level WARN -Text 'no .vssettings backup found (open and close Visual Studio once to create one)' }

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
    $vsDir = Join-Path $CaptureDir 'vs'
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
    <#
      Backs up every user database to the data disk and checks each backup.
      Logins, instance settings and SQL Agent objects are recorded in VM.json
      instead (GuestSql.ps1, GuestSqlAgent.ps1).
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $instance = Connect-GuestSqlInstance -VM $VM
    if (-not $instance) {
        Write-LogEntry '  SQL Server is not installed - skipping' 'INFO'
        return $null
    }
    $server = $VM.Runtime.SqlServer
    $backupDir = $VM.Runtime.GuestSqlBackupDir

    # Logins, instance settings and Agent objects are plain data, so they are recorded in VM.json (#131), not the capture.
    try { $null = Update-GuestSqlRecord -VM $VM }
    catch { Write-LogError '  The SQL logins, settings and Agent objects could not be recorded; VM.json keeps what it had' $_ }

    $state = Invoke-GuestScript -VM $VM -Activity 'SQL databases check' -TimeoutMinutes 10 -ArgumentList @($server) -ScriptBlock {
        param($server)
        $ErrorActionPreference = 'Stop'
        $connection = Open-GuestSqlConnection -Server $server
        try {
            $version = @(Get-GuestSqlRow -Connection $connection -Sql "SELECT SERVERPROPERTY('ProductVersion') AS V, SERVERPROPERTY('Edition') AS E, @@SERVICENAME AS S")[0]

            # What a capture knowingly does not bring across.
            $notMigrated = @()
            foreach ($check in @(
                    @{ What = 'maintenance plans'; Sql = 'SELECT name FROM msdb.dbo.sysmaintplan_plans' }
                    @{ What = 'SQL Agent proxies'; Sql = 'SELECT name FROM msdb.dbo.sysproxies' }
                    @{ What = 'linked servers'; Sql = 'SELECT name FROM sys.servers WHERE server_id <> 0' }
                    @{ What = 'credentials'; Sql = 'SELECT name FROM sys.credentials' })) {
                $names = @(Get-GuestSqlRow -Connection $connection -Sql $check.Sql | ForEach-Object { "$($_.name)" })
                if ($names.Count -gt 0) { $notMigrated += "$($check.What): $($names -join ', ')" }
            }

            return [pscustomobject]@{
                Instance = "$($version.S)"; Version = "$($version.V)"; Edition = "$($version.E)"
                NotMigrated = $notMigrated
            }
        }
        finally { $connection.Close() }
    }

    $backups = @(Backup-GuestUserDatabase -VM $VM)

    $total = ($backups | Measure-Object -Property SizeBytes -Sum).Sum
    Write-LogEntry "  SQL $($state.Version) ($($state.Edition)): $($backups.Count) database(s), $(Format-Size ([double]$total)) of backups" 'OK'
    Write-LogEntry "  Backups stay on the data disk ($backupDir), which survives the rebuild" 'INFO'
    foreach ($item in @($state.NotMigrated)) { Write-LogEntry "  NOT migrated automatically - $item" 'WARN' }

    return [pscustomobject]@{
        Instance    = $state.Instance
        Version     = $state.Version
        Edition     = $state.Edition
        BackupDir   = $backupDir
        Databases   = $backups
        NotMigrated = @($state.NotMigrated)
    }
}

function Backup-GuestUserDatabase {
    <#
      Checks and backs up every online, writable user database to the SQL
      data disk, keeping one good backup of each (#133). A database whose
      check or backup fails is logged and keeps its last good backup; the
      others still run. Returns the backups made.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not (Connect-GuestSqlInstance -VM $VM)) {
        Write-LogEntry '  SQL Server is not installed - no databases to back up' 'INFO'
        return
    }
    $names = @(Invoke-GuestScript -VM $VM -Activity 'SQL user database list' -TimeoutMinutes 5 -ArgumentList @($VM.Runtime.SqlServer) -ScriptBlock {
            param($server)
            $ErrorActionPreference = 'Stop'
            $connection = Open-GuestSqlConnection -Server $server
            try { @(Get-GuestSqlRow -Connection $connection -Sql "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' AND is_read_only = 0" | ForEach-Object { "$($_.name)" }) }
            finally { $connection.Close() }
        })

    foreach ($name in $names) {
        try { Backup-GuestDatabase -VM $VM -Name $name -BackupDir $VM.Runtime.GuestSqlBackupDir }
        catch { Write-LogError "  The database $name failed its check or backup; its last good backup is kept" $_ }
    }
}

function Backup-GuestDatabase {
    <# Checks one database and backs it up to <BackupDir>\<name>.bak, replacing the last good backup only once the new one verifies (Backup-GuestSqlDatabase). #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BackupDir
    )

    return Invoke-GuestScript -VM $VM -Activity "checking and backing up $Name" -TimeoutMinutes 180 -ArgumentList @($VM.Runtime.SqlServer, $Name, $BackupDir) -ScriptBlock {
        param($server, $name, $backupDir)
        $ErrorActionPreference = 'Stop'
        $connection = Open-GuestSqlConnection -Server $server
        try {
            $file = Backup-GuestSqlDatabase -Connection $connection -Name $name -BackupDir $backupDir

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
# environment, firewall rules and scheduled tasks are recorded in VM.json
# instead (GuestEnvironment.ps1, GuestFirewall.ps1, GuestScheduledTask.ps1).

function Save-GuestWindowsState {
    <# Certificates and anything else for the Windows archive, into <CaptureDir>\windows\winstate.zip. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$CaptureDir
    )

    $staging = Join-Path $VM.Settings.GuestSetupDir 'winstate'
    $null = Invoke-GuestScript -VM $VM -Activity 'Windows capture staging' -TimeoutMinutes 5 -ArgumentList @($staging) -ScriptBlock {
        param($staging)
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($folder in $staging, (Join-Path $staging 'certs')) { New-GuestFolder -Path $folder }
    }

    # The environment, firewall rules and scheduled tasks are plain data, so they are recorded in VM.json (#131), not the archive.
    try { $null = Update-GuestEnvironmentRecord -VM $VM }
    catch { Write-LogError '  The guest environment could not be recorded; VM.json keeps what it had' $_ }
    try { $null = Update-GuestFirewallRecord -VM $VM }
    catch { Write-LogError '  The guest firewall rules could not be recorded; VM.json keeps what it had' $_ }
    try { $null = Update-GuestScheduledTaskRecord -VM $VM }
    catch { Write-LogError '  The guest scheduled tasks could not be recorded; VM.json keeps what it had' $_ }

    $certificates = Save-GuestCertificate -VM $VM -Staging $staging

    $summary = [pscustomobject]@{
        Certificates = @($certificates.Certificates)
    }
    $zip = Invoke-GuestScript -VM $VM -Activity 'Windows capture archive' -TimeoutMinutes 15 -ArgumentList @($staging, ($summary | ConvertTo-Json -Depth 8), $VM.Settings.GuestSetupDir) -ScriptBlock {
        param($staging, $summaryJson, $setupDir)
        Set-Content -Path (Join-Path $staging 'environment.json') -Value $summaryJson -Encoding UTF8
        $zip = Join-Path $setupDir 'winstate.zip'
        New-GuestZip -Source $staging -Destination $zip
        return $zip
    }

    $archive = Join-Path (Join-Path $CaptureDir 'windows') 'winstate.zip'
    Copy-FromGuest -VM $VM -GuestPath $zip -HostPath $archive

    Write-LogEntry "  windows: $($summary.Certificates.Count) certificate(s)" 'OK'
    Write-GuestNote -Notes @($certificates.Notes)

    return [pscustomobject]@{
        Archive      = $archive
        Certificates = $summary.Certificates
    }
}

function Save-GuestCertificate {
    <#
      The certificates Get-GuestCapturedCertificate picks, as .pfx with their
      keys where the key can be exported and .cer otherwise.
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
        foreach ($found in @(Get-GuestCapturedCertificate)) {
            $cert = $found.Certificate
            $store = $found.Store
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
        return [pscustomobject]$out
    }
}

# ── Application settings ─────────────────────────────────────────────────────

function Save-GuestAppSetting {
    <#
      Records the values under the AppSettings keys in VM.json
      (GuestAppSetting.ps1). Nothing goes into the capture itself, so the
      manifest's AppSettings stays empty.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $null = Update-GuestAppSettingRecord -VM $VM
    Write-LogEntry '  application settings: recorded in VM.json' 'OK'
    return $null
}
