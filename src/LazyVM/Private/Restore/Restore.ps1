# Restore.ps1 - Putting a capture back into a guest.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Every area is isolated: a firewall rule that cannot be added must not cost
# the databases. Visual Studio's settings are applied by the build's
# Restore-GuestVisualStudioSetting, from VSSettingsBackup, which the capture
# refreshes.

function Restore-GuestState {
    <# Applies the VM's capture. Returns $false when an area failed; having no capture is not a failure. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $manifest = Get-CaptureManifest -VM $VM
    if (-not $manifest) {
        Write-LogEntry 'No usable capture found - nothing to restore' 'WARN'
        Write-LogEntry "  Expected at $(Get-CaptureManifestPath -VM $VM)" 'INFO'
        return $true
    }
    Write-LogEntry "Restoring the capture taken at $($manifest.CapturedAt)" 'INFO'

    $null = Open-GuestSession -VM $VM -Purpose 'restore its state'
    $null = Initialize-GuestSqlDisk -VM $VM

    $run = Invoke-IsolatedStep -What 'restore' -Steps @(
        [pscustomobject]@{ Name = '10a - Windows environment'; Action = { Restore-GuestWindowsState -VM $VM -Manifest $manifest } }
        [pscustomobject]@{ Name = '10b - Visual Studio files'; Action = { Restore-GuestVisualStudioState -VM $VM -Manifest $manifest } }
        [pscustomobject]@{ Name = '10c - SQL Server'; Action = { Restore-GuestSqlState -VM $VM -Manifest $manifest } }
        [pscustomobject]@{ Name = '10e - application settings'; Action = { Restore-GuestAppSetting -VM $VM -Manifest $manifest } }
    )
    if ($run.Failures.Count -eq 0) { Write-LogEntry 'Restore complete' 'OK' }
    return ($run.Failures.Count -eq 0)
}

function Send-CaptureArchive {
    <# Copies a capture archive into the guest and returns its path there, or $null when the capture has none. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowNull()][object]$Area,
        [Parameter(Mandatory)][string]$What
    )

    $archive = [RecordReader]::Text($Area, 'Archive')
    if (-not $archive) {
        Write-LogEntry "  no $What capture - skipping" 'INFO'
        return $null
    }
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-LogEntry "  $What capture archive missing at $archive - skipping" 'WARN'
        return $null
    }
    $guestZip = Join-Path $VM.Settings.GuestSetupDir ([IO.Path]::GetFileName($archive))
    Copy-ToGuest -VM $VM -HostPath $archive -GuestPath $guestZip
    return $guestZip
}

# ── Windows environment ──────────────────────────────────────────────────────

function Restore-GuestWindowsState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The certificate PFX password has to cross into the guest as text, where it becomes a SecureString again.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The PFX password arrives in the guest as text and becomes a SecureString there.')]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][CaptureManifest]$Manifest
    )

    # The environment, firewall rules and scheduled tasks are in VM.json (#131), so they come back even without an archive.
    $guestZip = Send-CaptureArchive -VM $VM -Area $Manifest.Windows -What 'Windows environment'
    if (-not $guestZip) {
        Write-GuestNote -Notes (@(Restore-GuestEnvironment -VM $VM) + @(Restore-GuestFirewallRule -VM $VM) + @(Restore-GuestScheduledTask -VM $VM))
        return
    }

    $work = Invoke-GuestScript -VM $VM -Activity 'Windows restore staging' -TimeoutMinutes 10 -ArgumentList @($guestZip, $VM.Settings.GuestSetupDir) -ScriptBlock {
        param($zip, $setupDir)
        $work = Join-Path $setupDir 'winstate-restore'
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        Expand-GuestZip -Archive $zip -Destination $work
        return $work
    }

    $certificate = Get-StoredCredential -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.CertCredFile
    $certPassword = if ($certificate) { ConvertTo-PlainText -Secure $certificate.Password } else { '' }

    $notes = @()
    $notes += Restore-GuestEnvironment -VM $VM -Work $work
    $notes += Invoke-GuestScript -VM $VM -Activity 'certificate restore' -TimeoutMinutes 10 -ArgumentList @($work, $certPassword) -ScriptBlock {
        param($work, $certPassword)
        $state = Get-Content (Join-Path $work 'environment.json') -Raw | ConvertFrom-Json
        $securePassword = if ($certPassword) { ConvertTo-SecureString -String $certPassword -AsPlainText -Force } else { $null }
        $notes = @(); $restored = 0
        foreach ($cert in @($state.Certificates)) {
            $file = Join-Path $work "certs\$($cert.File)"
            if (-not $cert -or -not (Test-Path $file)) { continue }
            try {
                if ($cert.HasKey -and $securePassword) { Import-PfxCertificate -FilePath $file -CertStoreLocation $cert.Store -Password $securePassword -Exportable | Out-Null }
                else { Import-Certificate -FilePath $file -CertStoreLocation $cert.Store | Out-Null }
                $restored++
            }
            catch { $notes += New-GuestNote -Level WARN -Text "certificate $($cert.Thumbprint) failed: $($_.Exception.Message)" }
        }
        if ($restored -gt 0) { $notes += New-GuestNote -Level OK -Text "restored $restored certificate(s)" }
        return $notes
    }
    $notes += Restore-GuestFirewallRule -VM $VM -Work $work
    $notes += Restore-GuestScheduledTask -VM $VM -Work $work
    Write-GuestNote -Notes $notes
}

function Restore-GuestScheduledTask {
    <#
      Registers the scheduled tasks VM.json records, skipping any the guest
      already has by name. A VM whose tasks were never recorded gets them
      from the capture archive unpacked at $Work instead.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [string]$Work
    )

    $saved = Get-GuestScheduledTaskRestore -VM $VM
    if (-not $saved -and -not $Work) { return }
    $tasksJson = if ($saved) { ConvertTo-Json -InputObject @($saved.Tasks) -Depth 5 -Compress } else { '' }

    return Invoke-GuestScript -VM $VM -Activity 'scheduled task restore' -TimeoutMinutes 10 -ArgumentList @($tasksJson, $Work) -ScriptBlock {
        param($tasksJson, $work)
        if ($tasksJson) { $tasks = @($tasksJson | ConvertFrom-Json) }
        else {
            # Before #131 each task was a file of its own, named after the task.
            $tasks = @(foreach ($file in @(Get-ChildItem (Join-Path $work 'tasks') -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
                    [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($file.Name); Xml = (Get-Content $file.FullName -Raw) }
                })
        }
        $notes = @(); $added = 0
        foreach ($task in $tasks) {
            if (-not $task -or (Get-ScheduledTask -TaskName $task.Name -ErrorAction SilentlyContinue)) { continue }
            try {
                Register-ScheduledTask -TaskName $task.Name -Xml $task.Xml -Force | Out-Null
                $added++
            }
            catch { $notes += New-GuestNote -Level WARN -Text "scheduled task '$($task.Name)' failed: $($_.Exception.Message)" }
        }
        if ($added -gt 0) { $notes += New-GuestNote -Level OK -Text "recreated $added scheduled task(s)" }
        return $notes
    }
}

function Restore-GuestFirewallRule {
    <#
      Recreates the firewall rules VM.json records, skipping any the guest
      already has by name. A VM whose rules were never recorded gets them
      from the capture archive unpacked at $Work instead.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [string]$Work
    )

    $saved = Get-GuestFirewallRestore -VM $VM
    if (-not $saved -and -not $Work) { return }
    $rulesJson = if ($saved) { ConvertTo-Json -InputObject @($saved.Rules) -Depth 5 -Compress } else { '' }

    return Invoke-GuestScript -VM $VM -Activity 'firewall restore' -TimeoutMinutes 10 -ArgumentList @($rulesJson, $Work) -ScriptBlock {
        param($rulesJson, $work)
        if ($rulesJson) { $rules = @($rulesJson | ConvertFrom-Json) }
        else {
            $file = Join-Path $work 'firewall.json'
            if (-not (Test-Path $file)) { return }
            $rules = @(Get-Content $file -Raw | ConvertFrom-Json)
        }
        $notes = @(); $added = 0
        foreach ($rule in $rules) {
            if (-not $rule -or (Get-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue)) { continue }
            try {
                $parameters = @{ DisplayName = $rule.DisplayName; Direction = $rule.Direction; Action = $rule.Action; Profile = $rule.Profile }
                if ($rule.Protocol -and $rule.Protocol -ne 'Any') { $parameters.Protocol = $rule.Protocol }
                if ($rule.LocalPort -and @($rule.LocalPort)[0] -ne 'Any') { $parameters.LocalPort = @($rule.LocalPort) }
                if ($rule.RemoteAddress -and @($rule.RemoteAddress)[0] -ne 'Any') { $parameters.RemoteAddress = @($rule.RemoteAddress) }
                New-NetFirewallRule @parameters | Out-Null
                $added++
            }
            catch { $notes += New-GuestNote -Level WARN -Text "firewall rule '$($rule.DisplayName)' failed: $($_.Exception.Message)" }
        }
        if ($added -gt 0) { $notes += New-GuestNote -Level OK -Text "recreated $added firewall rule(s)" }
        return $notes
    }
}

function Restore-GuestEnvironment {
    <#
      Puts back the environment VM.json records: environment variables,
      the secret ones from the credential store, then PATH, merged rather
      than replaced so the fresh install's own entries survive, then the
      hosts entries the new hosts file lacks, then the mapped drives, which
      Windows reconnects at sign-in. A VM whose environment was never
      recorded gets it from the capture archive unpacked at $Work instead.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [string]$Work
    )

    $saved = Get-GuestEnvironmentRestore -VM $VM
    if (-not $saved) {
        if (-not $Work) { return }
        return Restore-GuestEnvironmentFromArchive -VM $VM -Work $Work
    }

    $recordJson = ConvertTo-Json -InputObject $saved.Record -Depth 10 -Compress
    $secretsJson = ConvertTo-Json -InputObject $saved.Secrets -Compress
    return Invoke-GuestScript -VM $VM -Activity 'environment restore' -TimeoutMinutes 10 -ArgumentList @($recordJson, $secretsJson) -ScriptBlock {
        param($recordJson, $secretsJson)
        $record = $recordJson | ConvertFrom-Json
        $secrets = $secretsJson | ConvertFrom-Json
        $notes = @()

        $count = 0
        foreach ($scope in 'Machine', 'User') {
            $table = $record."${scope}Variables"
            if (-not $table) { continue }
            foreach ($property in $table.PSObject.Properties) {
                [Environment]::SetEnvironmentVariable($property.Name, $property.Value, $scope)
                $count++
            }
        }
        foreach ($variable in @($record.SecretVariables | Where-Object { $_ })) {
            $value = if ($secrets) { $secrets."$($variable.Scope)\$($variable.Name)" } else { $null }
            if ($null -eq $value) {
                $notes += New-GuestNote -Level WARN -Text "no stored value for the secret variable $($variable.Name) ($($variable.Scope)) - set it again by hand"
                continue
            }
            [Environment]::SetEnvironmentVariable($variable.Name, $value, $variable.Scope)
            $count++
        }
        $notes += New-GuestNote -Level OK -Text "restored $count environment variable(s)"

        foreach ($scope in 'Machine', 'User') {
            $saved = @($record."${scope}Path" | Where-Object { $_ })
            if ($saved.Count -eq 0) { continue }
            $current = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ })
            $added = @($saved | Where-Object { $current -notcontains $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) })
            if ($added.Count -gt 0) {
                [Environment]::SetEnvironmentVariable('Path', (($current + $added) -join ';'), $scope)
                $notes += New-GuestNote -Level OK -Text "added $($added.Count) entr(ies) to the $scope PATH"
            }
        }

        $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
        $present = @(Get-Content $hostsFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() })
        $missing = @($record.Hosts | Where-Object { $_ -and $present -notcontains $_ })
        if ($missing.Count -gt 0) {
            Add-Content -Path $hostsFile -Value $missing -Encoding ASCII
            $notes += New-GuestNote -Level OK -Text "added $($missing.Count) entr(ies) to the hosts file"
        }

        $mapped = 0
        foreach ($drive in @($record.MappedDrives | Where-Object { $_ })) {
            $key = "HKCU:\Network\$($drive.Letter.TrimEnd(':'))"
            if (Test-Path $key) { continue }
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name RemotePath -Value $drive.Path -PropertyType String | Out-Null
            New-ItemProperty -Path $key -Name UserName -Value '' -PropertyType String | Out-Null
            New-ItemProperty -Path $key -Name ProviderName -Value 'Microsoft Windows Network' -PropertyType String | Out-Null
            New-ItemProperty -Path $key -Name ProviderType -Value 0x20000 -PropertyType DWord | Out-Null
            New-ItemProperty -Path $key -Name ConnectionType -Value 1 -PropertyType DWord | Out-Null
            New-ItemProperty -Path $key -Name DeferFlags -Value 4 -PropertyType DWord | Out-Null
            $mapped++
        }
        if ($mapped -gt 0) { $notes += New-GuestNote -Level OK -Text "mapped $mapped network drive(s); Windows connects them at sign-in" }
        return $notes
    }
}

function Restore-GuestEnvironmentFromArchive {
    <#
      The environment from a capture taken before #131, unpacked at $Work:
      environment variables, then PATH, merged rather than replaced, then the
      hosts file, keeping the new one as hosts.lazyvm-original.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Work
    )

    return Invoke-GuestScript -VM $VM -Activity 'environment restore' -TimeoutMinutes 10 -ArgumentList @($Work) -ScriptBlock {
        param($work)
        $state = Get-Content (Join-Path $work 'environment.json') -Raw | ConvertFrom-Json
        $notes = @()

        $count = 0
        foreach ($scope in 'Machine', 'User') {
            $table = $state."Env$scope"
            if (-not $table) { continue }
            foreach ($property in $table.PSObject.Properties) {
                [Environment]::SetEnvironmentVariable($property.Name, $property.Value, $scope)
                $count++
            }
        }
        $notes += New-GuestNote -Level OK -Text "restored $count environment variable(s)"

        foreach ($scope in 'Machine', 'User') {
            $saved = @($state.PathEntries.$scope | Where-Object { $_ })
            if ($saved.Count -eq 0) { continue }
            $current = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ })
            $added = @($saved | Where-Object { $current -notcontains $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) })
            if ($added.Count -gt 0) {
                [Environment]::SetEnvironmentVariable('Path', (($current + $added) -join ';'), $scope)
                $notes += New-GuestNote -Level OK -Text "added $($added.Count) entr(ies) to the $scope PATH"
            }
        }

        $hostsSource = Join-Path $work 'hosts'
        if (Test-Path $hostsSource) {
            $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
            Copy-Item $hostsFile "$hostsFile.lazyvm-original" -Force -ErrorAction SilentlyContinue
            Copy-Item $hostsSource $hostsFile -Force
            $notes += New-GuestNote -Level OK -Text 'restored the hosts file (the new one kept as hosts.lazyvm-original)'
        }
        return $notes
    }
}

# ── Visual Studio ────────────────────────────────────────────────────────────

function Restore-GuestVisualStudioState {
    <# NuGet.Config, .gitconfig and the snippets and templates; the settings themselves come from Restore-GuestVisualStudioSetting. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][CaptureManifest]$Manifest
    )

    if (-not $Manifest.VisualStudio) {
        Write-LogEntry '  no Visual Studio capture - skipping' 'INFO'
        return
    }
    $vs = Get-GuestVisualStudio -VM $VM
    if (-not $vs) {
        Write-LogEntry '  Visual Studio is not installed in the guest - skipping' 'WARN'
        return
    }

    $files = [RecordReader]::Field($Manifest.VisualStudio, 'Files')
    $pushed = @{}
    foreach ($key in 'NuGetConfig', 'GitConfig', 'UserItems') {
        $hostPath = [RecordReader]::Text($files, $key)
        if (-not $hostPath -or -not (Test-Path -LiteralPath $hostPath)) { continue }
        $guestPath = Join-Path $VM.Settings.GuestSetupDir ([IO.Path]::GetFileName($hostPath))
        try {
            Copy-ToGuest -VM $VM -HostPath $hostPath -GuestPath $guestPath
            $pushed[$key] = $guestPath
        }
        catch { Write-LogEntry "  could not send $key to the guest: $($_.Exception.Message)" 'WARN' }
    }

    $notes = Invoke-GuestScript -VM $VM -Activity 'Visual Studio restore' -TimeoutMinutes 30 -ArgumentList @(
        $pushed['NuGetConfig'], $pushed['GitConfig'], $pushed['UserItems'], "$($vs.ProductLine)"
    ) -ScriptBlock {
        param($nuget, $gitconfig, $userItems, $productLine)
        $notes = @()
        if ($nuget) {
            $destination = Join-Path $env:APPDATA 'NuGet\NuGet.Config'
            New-GuestFolder -Path (Split-Path $destination -Parent)
            Copy-Item $nuget $destination -Force
            $notes += New-GuestNote -Level OK -Text 'restored NuGet.Config'
        }
        if ($gitconfig) {
            Copy-Item $gitconfig (Join-Path $env:USERPROFILE '.gitconfig') -Force
            $notes += New-GuestNote -Level OK -Text 'restored .gitconfig'
        }
        if ($userItems) {
            $destination = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Visual Studio $productLine"
            New-GuestFolder -Path $destination
            $temp = Join-Path $env:TEMP 'vs-useritems'
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
            Expand-GuestZip -Archive $userItems -Destination $temp
            Copy-Item (Join-Path $temp '*') $destination -Recurse -Force
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
            $notes += New-GuestNote -Level OK -Text 'restored snippets and templates'
        }
        return $notes
    }
    Write-GuestNote -Notes $notes
}

# ── SQL Server ───────────────────────────────────────────────────────────────

function Restore-GuestSqlState {
    <#
      Instance settings, then logins with their original SIDs, then the
      databases, then the SQL Agent jobs, operators and alerts, whose job
      steps need their databases. Each database VM.json records is attached
      from its files on the SQL data disk (#132); one that cannot be, and one
      VM.json does not record, comes from its backup on the data disk. All
      but the backups come from VM.json (#131); a VM recorded before that
      gets its settings and logins from the capture.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][CaptureManifest]$Manifest
    )

    $sql = $Manifest.Sql
    $recorded = Get-GuestSqlRestore -VM $VM
    if (-not $sql -and -not $recorded) {
        Write-LogEntry '  no SQL capture - skipping' 'INFO'
        return
    }
    if (-not (Connect-GuestSqlInstance -VM $VM)) {
        Write-LogEntry '  SQL Server is not installed in the guest - skipping' 'WARN'
        return
    }

    $runtime = $VM.Runtime
    $notes = @()
    $logins = if ($recorded) { $recorded } else { $sql }
    $notes += Restore-GuestSqlLogin -VM $VM -Configs @($logins.Configs) -Logins @($logins.Logins)

    $attached = @()
    foreach ($database in @(if ($recorded) { $recorded.Databases })) {
        $result = Invoke-GuestScript -VM $VM -Activity "attaching the database $($database.Name)" -TimeoutMinutes 30 `
            -ArgumentList @($runtime.SqlServer, "$($database.Name)", @($database.Files), $runtime.GuestDataDriveLetter) -ScriptBlock {
            param($server, $name, $files, $dataLetter)
            $ErrorActionPreference = 'Stop'
            $connection = Open-GuestSqlConnection -Server $server
            try {
                switch (Mount-GuestSqlDatabase -Connection $connection -Name $name -Files $files -DriveLetter $dataLetter) {
                    'Exists' { return [pscustomobject]@{ Attached = $true; Notes = @(New-GuestNote -Level INFO -Text "skipped $name (already exists)") } }
                    'Missing' { return [pscustomobject]@{ Attached = $false; Notes = @(New-GuestNote -Level INFO -Text "$name's files are not on the SQL data disk - restoring it from its backup instead") } }
                    default { return [pscustomobject]@{ Attached = $true; Notes = @(New-GuestNote -Level OK -Text "attached $name") + @(Repair-GuestSqlOrphanedUser -Connection $connection -Name $name) } }
                }
            }
            catch { return [pscustomobject]@{ Attached = $false; Notes = @(New-GuestNote -Level WARN -Text "could not attach $name - $($_.Exception.Message); restoring it from its backup instead") } }
            finally { $connection.Close() }
        }
        $notes += @($result.Notes)
        if ($result.Attached) { $attached += "$($database.Name)" }
    }

    $databases = if ($sql) { @($sql.Databases | Where-Object { $_ -and $attached -notcontains $_.Name }) } else { @() }
    foreach ($database in $databases) {
        $notes += Invoke-GuestScript -VM $VM -Activity "restoring the database $($database.Name)" -TimeoutMinutes 180 `
            -ArgumentList @($runtime.SqlServer, $database.Name, "$($database.BackupFile)", $runtime.GuestSqlBackupDir, $runtime.GuestSqlDataDir, $runtime.GuestSqlLogDir, "$($database.Recovery)", [int]$database.CompatLevel) -ScriptBlock {
            param($server, $name, $backupFile, $backupDir, $dataDir, $logDir, $recovery, $compatLevel)
            $ErrorActionPreference = 'Stop'
            # The captured path, or the backup folder when the data disk came
            # back on a different drive letter.
            if (-not (Test-Path $backupFile)) {
                $alternative = Join-Path $backupDir "$name.bak"
                if (-not (Test-Path $alternative)) { return New-GuestNote -Level ERROR -Text "no backup of $name (looked in $backupFile and $alternative)" }
                $backupFile = $alternative
            }

            $connection = Open-GuestSqlConnection -Server $server
            try {
                if (-not (Restore-GuestSqlBackup -Connection $connection -Name $name -BackupFile $backupFile -DataDir $dataDir -LogDir $logDir)) {
                    return New-GuestNote -Level INFO -Text "skipped $name (already exists)"
                }
                $quoted = ConvertTo-SqlName -Name $name
                if ($recovery) { $null = Invoke-GuestSql -Connection $connection -Sql "ALTER DATABASE $quoted SET RECOVERY $recovery" }
                if ($compatLevel) { $null = Invoke-GuestSql -Connection $connection -Sql "ALTER DATABASE $quoted SET COMPATIBILITY_LEVEL = $compatLevel" }

                return @(New-GuestNote -Level OK -Text "restored $name") + @(Repair-GuestSqlOrphanedUser -Connection $connection -Name $name)
            }
            catch { return New-GuestNote -Level ERROR -Text "failed to restore $name - $($_.Exception.Message)" }
            finally { $connection.Close() }
        }
    }
    if ($recorded -and $recorded.Agent) { $notes += Restore-GuestSqlAgent -VM $VM -Agent $recorded.Agent }
    Write-GuestNote -Notes $notes
    if ($sql) {
        foreach ($item in @($sql.NotMigrated)) { Write-LogEntry "  reminder - not migrated: $item" 'WARN' }
    }
}

function Restore-GuestSqlLogin {
    <# Instance settings, then each login not already there, with its original SID and server roles. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowEmptyCollection()][object[]]$Configs = @(),
        [AllowEmptyCollection()][object[]]$Logins = @()
    )

    $configList = @($Configs | Where-Object { $_ } | ForEach-Object { @{ Name = "$($_.Name)"; Value = "$($_.Value)" } })
    $loginList = @($Logins | Where-Object { $_ } | ForEach-Object {
            @{
                Name = "$($_.Name)"; TypeDesc = "$($_.TypeDesc)"; IsDisabled = [bool]$_.IsDisabled
                DefaultDb = "$($_.DefaultDb)"; SidHex = "$($_.SidHex)"; HashHex = "$($_.HashHex)"
                PolicyChecked = [bool]$_.PolicyChecked; ExpirationChecked = [bool]$_.ExpirationChecked
                ServerRoles = @($_.ServerRoles)
            }
        })

    return Invoke-GuestScript -VM $VM -Activity 'SQL settings and logins restore' -TimeoutMinutes 15 -ArgumentList @($VM.Runtime.SqlServer, $configList, $loginList) -ScriptBlock {
        param($server, $configs, $logins)
        $ErrorActionPreference = 'Stop'
        $notes = @()
        $connection = Open-GuestSqlConnection -Server $server
        try {
            foreach ($config in @($configs)) {
                try { $null = Invoke-GuestSql -Connection $connection -Sql "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure $(ConvertTo-SqlString -Text $config.Name), $([long]$config.Value); RECONFIGURE;" }
                catch { $notes += New-GuestNote -Level WARN -Text "sp_configure '$($config.Name)' failed: $($_.Exception.Message)" }
            }

            $added = 0
            foreach ($login in @($logins)) {
                $quoted = ConvertTo-SqlName -Name $login.Name
                if ([int](Get-GuestSqlScalar -Connection $connection -Sql "SELECT COUNT(*) FROM sys.server_principals WHERE name = $(ConvertTo-SqlString -Text $login.Name)") -gt 0) { continue }
                try {
                    $defaultDb = if ($login.DefaultDb) { "DEFAULT_DATABASE = $(ConvertTo-SqlName -Name $login.DefaultDb)" } else { '' }
                    if ($login.TypeDesc -eq 'SQL_LOGIN' -and $login.HashHex) {
                        $options = @("PASSWORD = $($login.HashHex) HASHED", "SID = $($login.SidHex)",
                            "CHECK_POLICY = $(if ($login.PolicyChecked) { 'ON' } else { 'OFF' })",
                            "CHECK_EXPIRATION = $(if ($login.ExpirationChecked) { 'ON' } else { 'OFF' })") + @($defaultDb | Where-Object { $_ })
                        $null = Invoke-GuestSql -Connection $connection -Sql "CREATE LOGIN $quoted WITH $($options -join ', ')"
                    }
                    else {
                        $with = if ($defaultDb) { " WITH $defaultDb" } else { '' }
                        $null = Invoke-GuestSql -Connection $connection -Sql "CREATE LOGIN $quoted FROM WINDOWS$with"
                    }
                    if ($login.IsDisabled) { $null = Invoke-GuestSql -Connection $connection -Sql "ALTER LOGIN $quoted DISABLE" }
                    foreach ($role in @($login.ServerRoles | Where-Object { $_ })) {
                        $null = Invoke-GuestSql -Connection $connection -Sql "ALTER SERVER ROLE $(ConvertTo-SqlName -Name $role) ADD MEMBER $quoted"
                    }
                    $added++
                }
                catch { $notes += New-GuestNote -Level WARN -Text "login '$($login.Name)' failed: $($_.Exception.Message)" }
            }
            if ($added -gt 0) { $notes += New-GuestNote -Level OK -Text "created $added login(s) with their original SIDs" }
        }
        finally { $connection.Close() }
        return $notes
    }
}

# ── Application settings ─────────────────────────────────────────────────────

function Restore-GuestAppSetting {
    <#
      Writes the application settings VM.json records into the guest's
      registry, the secret values from the credential store. A VM whose
      settings were never recorded gets the .reg files its capture has
      instead.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][CaptureManifest]$Manifest
    )

    $recorded = Get-GuestAppSettingRestore -VM $VM
    if ($recorded) {
        Write-GuestNote -Notes @(Restore-GuestAppSettingValue -VM $VM -Recorded $recorded)
        return
    }

    $saved = @($Manifest.AppSettings | Where-Object { $_ })
    if ($saved.Count -eq 0) {
        Write-LogEntry '  no application settings captured - skipping' 'INFO'
        return
    }

    foreach ($entry in $saved) {
        if (-not (Test-Path -LiteralPath $entry.File)) {
            Write-LogEntry "  $($entry.Name) - settings file missing at $($entry.File)" 'WARN'
            continue
        }
        $guestFile = Join-Path $VM.Settings.GuestSetupDir "app-$($entry.Name).reg"
        Copy-ToGuest -VM $VM -HostPath $entry.File -GuestPath $guestFile
        $imported = Invoke-GuestScript -VM $VM -Activity "$($entry.Name) settings import" -TimeoutMinutes 5 -ArgumentList @($guestFile) -ScriptBlock {
            param($file)
            & reg.exe import $file 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        if ($imported) { Write-LogEntry "  restored $($entry.Name) settings" 'OK' }
        else { Write-LogEntry "  $($entry.Name) settings import failed" 'WARN' }
    }
}

function Restore-GuestAppSettingValue {
    <#
      Sets each value $Recorded (from Get-GuestAppSettingRestore) holds in
      the guest's registry, creating the keys it needs and replacing values
      already there. Returns the guest's notes.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][object]$Recorded
    )

    $keysJson = ConvertTo-Json -InputObject @($Recorded.Keys) -Depth 10 -Compress
    $secretsJson = ConvertTo-Json -InputObject $Recorded.Secrets -Depth 5 -Compress
    return Invoke-GuestScript -VM $VM -Activity 'application settings restore' -TimeoutMinutes 5 -ArgumentList @($keysJson, $secretsJson) -ScriptBlock {
        param($keysJson, $secretsJson)
        $secrets = $secretsJson | ConvertFrom-Json
        $notes = @()
        foreach ($key in @($keysJson | ConvertFrom-Json)) {
            if (-not $key) { continue }
            $values = @($key.Values | Where-Object { $_ })
            foreach ($secret in @($key.SecretValues | Where-Object { $_ })) {
                $stored = if ($secrets) { $secrets."$($key.Name)\$($secret.Path)\$($secret.Name)" } else { $null }
                if ($null -eq $stored) {
                    $notes += New-GuestNote -Level WARN -Text "no stored value for $($key.Name)'s secret setting $($secret.Name) - set it again by hand"
                    continue
                }
                $values += [pscustomobject]@{ Path = $secret.Path; Name = $secret.Name; Kind = $stored.Kind; Data = $stored.Data }
            }
            try {
                $hive, $subKey = $key.RegistryKey -split '\\', 2
                $base = if ($hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
                foreach ($value in $values) {
                    $target = $base.CreateSubKey($(if ($value.Path) { "$subKey\$($value.Path)" } else { $subKey }))
                    try {
                        if ($value.Kind -eq 'Binary') { $data = [Convert]::FromBase64String($value.Data) }
                        elseif ($value.Kind -eq 'MultiString') { $data = [string[]]@($value.Data) }
                        elseif ($value.Kind -eq 'DWord') { $data = [int]$value.Data }
                        elseif ($value.Kind -eq 'QWord') { $data = [long]$value.Data }
                        else { $data = [string]$value.Data }
                        $target.SetValue($value.Name, $data, [Microsoft.Win32.RegistryValueKind]$value.Kind)
                    }
                    finally { $target.Dispose() }
                }
                $notes += New-GuestNote -Level OK -Text "restored $($key.Name) settings ($($values.Count) value(s))"
            }
            catch { $notes += New-GuestNote -Level WARN -Text "$($key.Name) settings could not be restored: $($_.Exception.Message)" }
        }
        return $notes
    }
}
