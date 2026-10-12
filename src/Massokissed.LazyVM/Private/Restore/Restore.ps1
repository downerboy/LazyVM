# Restore.ps1 - Phase 10: restore captured state into a guest.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 10 — RESTORE
#
#  Applies a capture manifest into a freshly built guest. Every step is
#  isolated: a failure to re-add a firewall rule must not cost you your
#  databases.
# ─────────────────────────────────────────────────────────────────────────────
function Restore-GuestState {
    Write-LogEntry 'PHASE 10 - Restore Captured State' 'PHASE'

    $manifest = Get-CaptureManifest
    if (-not $manifest) {
        Write-LogEntry 'No capture manifest found - nothing to restore' 'WARN'
        Write-LogEntry "  Expected at $(Join-Path $CFG.StateDir 'manifest.json')" 'INFO'
        return
    }
    Write-LogEntry "Restoring the capture taken at $($manifest.CapturedAt)" 'INFO'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Stop-WithError "VM '$($CFG.VMName)' does not exist." }

    $credential = Get-GuestCredential
    if (-not $credential) { Stop-WithError 'No stored guest credential.' }

    if ($vm.State -ne 'Running') {
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 30 | Out-Null
    }
    Connect-Guest -Credential $credential | Out-Null
    Initialize-GuestSqlDisk

    $steps = @(
        [pscustomobject]@{ Name = '10a - Windows environment'; Action = { Restore-GuestWindowsState -Manifest $manifest } }
        [pscustomobject]@{ Name = '10b - Visual Studio'; Action = { Restore-GuestVisualStudioState -Manifest $manifest } }
        [pscustomobject]@{ Name = '10c - SQL Server'; Action = { Restore-GuestSqlState -Manifest $manifest } }
        [pscustomobject]@{ Name = '10d - project files'; Action = { Restore-GuestProjectFolder -Manifest $manifest } }
        [pscustomobject]@{ Name = '10e - application settings'; Action = { Restore-GuestAppSetting -Manifest $manifest } }
    )

    $failures = 0
    foreach ($step in $steps) {
        try { & $step.Action }
        catch {
            $failures++
            Write-LogError "$($step.Name) failed" $_
            Write-LogEntry '  Continuing with the remaining restore steps.' 'INFO'
        }
    }

    if ($failures -gt 0) { Write-LogEntry "Restore finished with $failures of $($steps.Count) steps failing" 'WARN' }
    else { Write-LogEntry 'Phase 10 complete' 'OK' }
    return ($failures -eq 0)
}

function Restore-GuestWindowsState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The certificate PFX password has to cross into the guest as text, where it becomes a SecureString again; PowerShell Direct cannot carry a SecureString encrypted with a key the guest does not have.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The certificate PFX password has to cross into the guest as text, where it becomes a SecureString again; PowerShell Direct cannot carry a SecureString encrypted with a key the guest does not have.')]
    param([Parameter(Mandatory)]$Manifest)

    if (-not $Manifest.Windows -or -not $Manifest.Windows.Archive) {
        Write-LogEntry '  no Windows environment capture - skipping' 'INFO'
        return
    }
    $archive = $Manifest.Windows.Archive
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-LogEntry "  capture archive missing at $archive - skipping" 'WARN'
        return
    }

    $certCred = Get-StoredCredential -Path $CFG.CertCredFile
    $certPassword = if ($certCred) { ConvertTo-PlainText $certCred.Password } else { '' }

    $guestZip = Join-Path $CFG.GuestSetupDir 'winstate.zip'
    Copy-ToGuest -HostPath $archive -GuestPath $guestZip

    $report = Invoke-GuestScript -Activity 'Windows environment restore' -TimeoutMinutes 60 -ArgumentList @(
        $guestZip, $CFG.GuestSetupDir, $certPassword
    ) -ScriptBlock {
        param($zip, $setupDir, $certPassword)
        $ErrorActionPreference = 'Stop'
        $log = @()

        $work = Join-Path $setupDir 'winstate-restore'
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)

        $state = Get-Content (Join-Path $work 'environment.json') -Raw | ConvertFrom-Json

        # -- environment variables --------------------------------------------
        $count = 0
        foreach ($scope in 'Machine', 'User') {
            $table = if ($scope -eq 'Machine') { $state.EnvMachine } else { $state.EnvUser }
            if (-not $table) { continue }
            foreach ($prop in $table.PSObject.Properties) {
                [Environment]::SetEnvironmentVariable($prop.Name, $prop.Value, $scope)
                $count++
            }
        }
        $log += "restored $count environment variable(s)"

        # PATH is merged, never replaced: the fresh install's own entries
        # (Visual Studio, SQL tools, Git) must survive.
        foreach ($scope in 'Machine', 'User') {
            $saved = @($state.PathEntries.$scope)
            if ($saved.Count -eq 0) { continue }
            $current = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ })
            $added = @($saved | Where-Object { $current -notcontains $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) })
            if ($added.Count -gt 0) {
                [Environment]::SetEnvironmentVariable('Path', (($current + $added) -join ';'), $scope)
                $log += "added $($added.Count) entr(ies) to the $scope PATH"
            }
        }

        # -- hosts file ---------------------------------------------------------
        $hostsSrc = Join-Path $work 'hosts'
        if (Test-Path $hostsSrc) {
            $hostsDest = "$env:SystemRoot\System32\drivers\etc\hosts"
            Copy-Item $hostsDest "$hostsDest.lazyvm-original" -Force -ErrorAction SilentlyContinue
            Copy-Item $hostsSrc $hostsDest -Force
            $log += 'restored the hosts file (previous kept as hosts.lazyvm-original)'
        }

        # -- certificates --------------------------------------------------------
        $certDir = Join-Path $work 'certs'
        $restored = 0
        if ((Test-Path $certDir) -and $state.Certificates) {
            $securePwd = if ($certPassword) { ConvertTo-SecureString -String $certPassword -AsPlainText -Force } else { $null }
            foreach ($cert in $state.Certificates) {
                $file = Join-Path $certDir $cert.File
                if (-not (Test-Path $file)) { continue }
                try {
                    if ($cert.HasKey -and $securePwd) {
                        Import-PfxCertificate -FilePath $file -CertStoreLocation $cert.Store -Password $securePwd -Exportable | Out-Null
                    }
                    else {
                        Import-Certificate -FilePath $file -CertStoreLocation $cert.Store | Out-Null
                    }
                    $restored++
                }
                catch { $log += "certificate $($cert.Thumbprint) failed: $($_.Exception.Message)" }
            }
        }
        if ($restored -gt 0) { $log += "restored $restored certificate(s)" }

        # -- firewall rules --------------------------------------------------------
        $firewallFile = Join-Path $work 'firewall.json'
        if (Test-Path $firewallFile) {
            $added = 0
            foreach ($rule in @(Get-Content $firewallFile -Raw | ConvertFrom-Json)) {
                if (Get-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue) { continue }
                try {
                    $params = @{
                        DisplayName = $rule.DisplayName
                        Direction   = $rule.Direction
                        Action      = $rule.Action
                        Profile     = $rule.Profile
                    }
                    if ($rule.Protocol -and $rule.Protocol -ne 'Any') { $params.Protocol = $rule.Protocol }
                    if ($rule.LocalPort -and @($rule.LocalPort)[0] -ne 'Any') { $params.LocalPort = @($rule.LocalPort) }
                    if ($rule.RemoteAddress -and @($rule.RemoteAddress)[0] -ne 'Any') { $params.RemoteAddress = @($rule.RemoteAddress) }
                    New-NetFirewallRule @params | Out-Null
                    $added++
                }
                catch { $log += "firewall rule '$($rule.DisplayName)' failed: $($_.Exception.Message)" }
            }
            if ($added -gt 0) { $log += "recreated $added firewall rule(s)" }
        }

        # -- scheduled tasks ---------------------------------------------------------
        $taskDir = Join-Path $work 'tasks'
        if (Test-Path $taskDir) {
            $added = 0
            foreach ($file in @(Get-ChildItem $taskDir -Filter '*.xml' -File)) {
                $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { continue }
                try {
                    Register-ScheduledTask -TaskName $name -Xml (Get-Content $file.FullName -Raw) -Force | Out-Null
                    $added++
                }
                catch { $log += "scheduled task '$name' failed: $($_.Exception.Message)" }
            }
            if ($added -gt 0) { $log += "recreated $added scheduled task(s)" }
        }

        return $log
    }

    foreach ($line in @($report)) {
        if ($line -match 'failed') { Write-LogEntry "  $line" 'WARN' } else { Write-LogEntry "  $line" 'OK' }
    }
}

function Restore-GuestVisualStudioState {
    param([Parameter(Mandatory)]$Manifest)

    if (-not $Manifest.VisualStudio) {
        Write-LogEntry '  no Visual Studio capture - skipping' 'INFO'
        return
    }

    $vs = Get-GuestVisualStudio
    if (-not $vs) {
        Write-LogEntry '  Visual Studio is not installed in the guest - skipping' 'WARN'
        return
    }

    $files = $Manifest.VisualStudio.Files
    $pushed = @{}
    foreach ($key in 'Settings', 'NuGetConfig', 'GitConfig', 'UserItems') {
        if (-not $files.PSObject.Properties[$key]) { continue }
        $hostPath = $files.$key
        if (-not $hostPath -or -not (Test-Path -LiteralPath $hostPath)) { continue }
        $guestPath = Join-Path $CFG.GuestSetupDir ([IO.Path]::GetFileName($hostPath))
        try {
            Copy-ToGuest -HostPath $hostPath -GuestPath $guestPath
            $pushed[$key] = $guestPath
        }
        catch { Write-LogEntry "  could not send $key to the guest: $($_.Exception.Message)" 'WARN' }
    }

    $report = Invoke-GuestScript -Activity 'Visual Studio restore' -TimeoutMinutes 30 -ArgumentList @(
        $pushed['NuGetConfig'], $pushed['GitConfig'], $pushed['UserItems'], "$($vs.ProductLine)"
    ) -ScriptBlock {
        param($nuget, $gitconfig, $userItems, $productLine)
        $ErrorActionPreference = 'Continue'
        $log = @()

        if ($nuget -and (Test-Path $nuget)) {
            $dest = Join-Path $env:APPDATA 'NuGet\NuGet.Config'
            $dir = Split-Path $dest -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item $nuget $dest -Force
            $log += 'restored NuGet.Config'
        }
        if ($gitconfig -and (Test-Path $gitconfig)) {
            Copy-Item $gitconfig (Join-Path $env:USERPROFILE '.gitconfig') -Force
            $log += 'restored .gitconfig'
        }
        if ($userItems -and (Test-Path $userItems)) {
            $dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Visual Studio $productLine"
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $tmp = Join-Path $env:TEMP 'vs-useritems'
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            [IO.Compression.ZipFile]::ExtractToDirectory($userItems, $tmp)
            Copy-Item (Join-Path $tmp '*') $dest -Recurse -Force
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            $log += 'restored snippets and templates'
        }
        return $log
    }
    foreach ($line in @($report)) { Write-LogEntry "  $line" 'OK' }

    # Settings have to be applied in the desktop session: the settings store
    # is per-user, and devenv needs a real session to write it.
    if ($pushed.ContainsKey('Settings')) {
        $settingsPath = $pushed['Settings']
        $script = @"
    `$devenv = '$($vs.DevEnvPath)'
    if (-not (Test-Path `$devenv)) { throw "devenv.exe not found at `$devenv" }
    `$proc = Start-Process -FilePath `$devenv -ArgumentList '/NoSplash','/ResetSettings','"$settingsPath"','/Command','Exit' -Wait -PassThru
    if (`$proc.ExitCode -ne 0) { throw "devenv exited with `$(`$proc.ExitCode)" }
"@
        try {
            Invoke-GuestScriptAsInteractiveUser -ScriptText $script -TaskName 'LazyVM-VSSettingsRestore' `
                -Activity 'Visual Studio settings restore' -TimeoutMinutes 25
            Write-LogEntry '  applied Visual Studio settings' 'OK'
        }
        catch { Write-LogEntry "  settings import failed: $($_.Exception.Message)" 'WARN' }
    }
}

function Restore-GuestSqlState {
    param([Parameter(Mandatory)]$Manifest)

    if (-not $Manifest.Sql) {
        Write-LogEntry '  no SQL capture - skipping' 'INFO'
        return
    }

    $instance = Get-GuestSqlInstance
    if (-not $instance) {
        Write-LogEntry '  SQL Server is not installed in the guest - skipping' 'WARN'
        return
    }
    Set-GuestSqlServer -Instance $instance.Instance

    $logins = @($Manifest.Sql.Logins) | ForEach-Object {
        @{
            Name = $_.Name; TypeDesc = $_.TypeDesc; IsDisabled = $_.IsDisabled
            DefaultDb = $_.DefaultDb; DefaultLang = $_.DefaultLang
            SidHex = $_.SidHex; HashHex = $_.HashHex
            PolicyChecked = $_.PolicyChecked; ExpirationChecked = $_.ExpirationChecked
            ServerRoles = @($_.ServerRoles)
        }
    }
    $databases = @($Manifest.Sql.Databases) | ForEach-Object {
        @{ Name = $_.Name; BackupFile = $_.BackupFile; Recovery = $_.Recovery; CompatLevel = $_.CompatLevel }
    }
    $configs = @($Manifest.Sql.Configs) | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }

    $report = Invoke-GuestScript -Activity 'SQL restore' -TimeoutMinutes 180 -ArgumentList @(
        (Get-GuestSqlServer), $CFG.GuestSqlDataDir, $CFG.GuestSqlLogDir, $CFG.GuestSqlBackupDir,
        $logins, $databases, $configs
    ) -ScriptBlock {
        param($server, $dataDir, $logDir, $backupDir, $logins, $databases, $configs)
        $ErrorActionPreference = 'Stop'
        $log = @()

        $cs = "Server=$server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
        $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
        $conn.Open()

        function Invoke-Sql($c, $sql, $timeout = 3600) {
            $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = $timeout
            return $cmd.ExecuteNonQuery()
        }
        function Get-Scalar($c, $sql) {
            $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
            return $cmd.ExecuteScalar()
        }
        function Get-SqlRow($c, $sql) {
            $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
            $r = $cmd.ExecuteReader(); $rows = @()
            try {
                while ($r.Read()) {
                    $h = @{}
                    for ($i = 0; $i -lt $r.FieldCount; $i++) { $h[$r.GetName($i)] = $r.GetValue($i) }
                    $rows += [pscustomobject]$h
                }
            }
            finally { $r.Close() }
            return $rows
        }

        try {
            # -- instance settings first ------------------------------------
            foreach ($cfg in $configs) {
                $name = "$($cfg.Name)".Replace("'", "''")
                try {
                    Invoke-Sql $conn "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure N'$name', $($cfg.Value); RECONFIGURE;" | Out-Null
                }
                catch { $log += "sp_configure '$name' failed: $($_.Exception.Message)" }
            }

            # -- logins, with original SIDs so users are not orphaned -------
            $added = 0
            foreach ($login in $logins) {
                $name = "$($login.Name)"
                $quoted = '[' + $name.Replace(']', ']]') + ']'
                $literal = "N'" + $name.Replace("'", "''") + "'"
                if ([int](Get-Scalar $conn "SELECT COUNT(*) FROM sys.server_principals WHERE name = $literal") -gt 0) { continue }
                try {
                    if ($login.TypeDesc -eq 'SQL_LOGIN' -and $login.HashHex) {
                        $sql = "CREATE LOGIN $quoted WITH PASSWORD = $($login.HashHex) HASHED, SID = $($login.SidHex)"
                        $sql += ", CHECK_POLICY = " + $(if ($login.PolicyChecked) { 'ON' } else { 'OFF' })
                        $sql += ", CHECK_EXPIRATION = " + $(if ($login.ExpirationChecked) { 'ON' } else { 'OFF' })
                        if ($login.DefaultDb) { $sql += ", DEFAULT_DATABASE = [" + "$($login.DefaultDb)".Replace(']', ']]') + "]" }
                    }
                    else {
                        $sql = "CREATE LOGIN $quoted FROM WINDOWS"
                        if ($login.DefaultDb) { $sql += " WITH DEFAULT_DATABASE = [" + "$($login.DefaultDb)".Replace(']', ']]') + "]" }
                    }
                    Invoke-Sql $conn $sql | Out-Null
                    if ($login.IsDisabled) { Invoke-Sql $conn "ALTER LOGIN $quoted DISABLE" | Out-Null }
                    foreach ($role in @($login.ServerRoles)) {
                        $r = '[' + "$role".Replace(']', ']]') + ']'
                        Invoke-Sql $conn "ALTER SERVER ROLE $r ADD MEMBER $quoted" | Out-Null
                    }
                    $added++
                }
                catch { $log += "login '$name' failed: $($_.Exception.Message)" }
            }
            if ($added -gt 0) { $log += "created $added login(s) with their original SIDs" }

            # -- databases ---------------------------------------------------
            foreach ($db in $databases) {
                $name = "$($db.Name)"
                $quoted = '[' + $name.Replace(']', ']]') + ']'
                $literal = "N'" + $name.Replace("'", "''") + "'"

                if ([int](Get-Scalar $conn "SELECT COUNT(*) FROM sys.databases WHERE name = $literal") -gt 0) {
                    $log += "skipped $name (already exists)"
                    continue
                }

                # Prefer the captured path; fall back to the backup folder in
                # case the data disk came back on a different drive letter.
                $backup = "$($db.BackupFile)"
                if (-not (Test-Path $backup)) {
                    $alt = Join-Path $backupDir "$name.bak"
                    if (Test-Path $alt) { $backup = $alt }
                    else { $log += "MISSING backup for $name (looked in $backup and $alt)"; continue }
                }
                $backupEsc = "N'" + $backup.Replace("'", "''") + "'"

                try {
                    $files = @(Get-SqlRow $conn "RESTORE FILELISTONLY FROM DISK = $backupEsc")
                    $moves = @()
                    foreach ($f in $files) {
                        $logical = "$($f.LogicalName)"
                        $leaf = [IO.Path]::GetFileName("$($f.PhysicalName)")
                        $targetDir = if ("$($f.Type)".ToUpperInvariant() -eq 'L') { $logDir } else { $dataDir }
                        $target = Join-Path $targetDir $leaf
                        $moves += "MOVE N'" + $logical.Replace("'", "''") + "' TO N'" + $target.Replace("'", "''") + "'"
                    }
                    if ($moves.Count -eq 0) { $log += "skipped $name (empty file list)"; continue }

                    Invoke-Sql $conn "RESTORE DATABASE $quoted FROM DISK = $backupEsc WITH $($moves -join ', '), STATS = 10" | Out-Null

                    if ($db.Recovery) {
                        Invoke-Sql $conn "ALTER DATABASE $quoted SET RECOVERY $($db.Recovery)" | Out-Null
                    }
                    if ($db.CompatLevel) {
                        Invoke-Sql $conn "ALTER DATABASE $quoted SET COMPATIBILITY_LEVEL = $([int]$db.CompatLevel)" | Out-Null
                    }
                    # Belt and braces: SIDs above should already prevent this.
                    Invoke-Sql $conn "USE $quoted; DECLARE @u sysname; DECLARE c CURSOR FOR SELECT dp.name FROM sys.database_principals dp LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid WHERE dp.type IN ('S','U') AND dp.principal_id > 4 AND sp.sid IS NULL; OPEN c; FETCH NEXT FROM c INTO @u; WHILE @@FETCH_STATUS = 0 BEGIN BEGIN TRY EXEC('ALTER USER [' + REPLACE(@u,']',']]') + '] WITH LOGIN = [' + REPLACE(@u,']',']]') + ']'); END TRY BEGIN CATCH END CATCH; FETCH NEXT FROM c INTO @u; END; CLOSE c; DEALLOCATE c;" | Out-Null

                    $log += "restored $name"
                }
                catch { $log += "FAILED $name - $($_.Exception.Message)" }
            }
        }
        finally { $conn.Close() }

        return $log
    }

    foreach ($line in @($report)) {
        if ($line -like 'FAILED*' -or $line -like 'MISSING*') { Write-LogEntry "  $line" 'ERROR' }
        elseif ($line -match 'failed') { Write-LogEntry "  $line" 'WARN' }
        elseif ($line -like 'skipped*') { Write-LogEntry "  $line" 'INFO' }
        else { Write-LogEntry "  $line" 'OK' }
    }

    foreach ($item in @($Manifest.Sql.NotMigrated)) {
        Write-LogEntry "  reminder - not migrated: $item" 'WARN'
    }
}

function Restore-GuestProjectFolder {
    param([Parameter(Mandatory)]$Manifest)

    if (-not $Manifest.Projects -or -not $Manifest.Projects.Archive) {
        Write-LogEntry '  no guest-side project capture - skipping' 'INFO'
        return
    }
    $archive = $Manifest.Projects.Archive
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-LogEntry "  project archive missing at $archive - skipping" 'WARN'
        return
    }

    $guestZip = Join-Path $CFG.GuestSetupDir 'projects.zip'
    Copy-ToGuest -HostPath $archive -GuestPath $guestZip

    $report = Invoke-GuestScript -Activity 'project restore' -TimeoutMinutes 60 -ArgumentList @(
        $guestZip, $CFG.GuestRestoreRoot
    ) -ScriptBlock {
        param($zip, $restoreRoot)
        $ErrorActionPreference = 'Stop'
        $root = [Environment]::ExpandEnvironmentVariables($restoreRoot)
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

        # Extracted into a dated folder rather than over the top of anything,
        # so a restore can never overwrite work already in the new guest.
        $dest = Join-Path $root ('restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)

        $files = @(Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue)
        $bytes = ($files | Measure-Object -Property Length -Sum).Sum
        return [pscustomobject]@{ Path = $dest; Files = $files.Count; Bytes = $bytes }
    }

    Write-LogEntry "  restored $($report.Files) file(s), $(Format-Size $report.Bytes) to $($report.Path)" 'OK'
    Write-LogEntry '  Extracted to a dated folder so nothing in the new guest is overwritten.' 'INFO'
}

function Restore-GuestAppSetting {
    <# Imports each captured application settings file into the guest's registry. #>
    param([Parameter(Mandatory)]$Manifest)

    $saved = @()
    if ($Manifest.PSObject.Properties['AppSettings'] -and $Manifest.AppSettings) { $saved = @($Manifest.AppSettings) }
    if ($saved.Count -eq 0) {
        Write-LogEntry '  no application settings captured - skipping' 'INFO'
        return
    }

    foreach ($entry in $saved) {
        if (-not (Test-Path -LiteralPath $entry.File)) {
            Write-LogEntry "  $($entry.Name) - settings file missing at $($entry.File)" 'WARN'
            continue
        }
        $guestFile = Join-Path $CFG.GuestSetupDir "app-$($entry.Name).reg"
        Copy-ToGuest -HostPath $entry.File -GuestPath $guestFile
        $imported = Invoke-GuestScript -Activity "$($entry.Name) settings import" -TimeoutMinutes 5 `
            -ArgumentList @($guestFile) -ScriptBlock {
            param($file)
            & reg.exe import $file 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        if ($imported) { Write-LogEntry "  restored $($entry.Name) settings" 'OK' }
        else { Write-LogEntry "  $($entry.Name) settings import failed" 'WARN' }
    }
}
