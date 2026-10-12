# GuestInstalls.ps1 - Phase 7: guest provisioning and installing the tooling list.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 7 — Guest Provisioning and Silent Installs
# ─────────────────────────────────────────────────────────────────────────────
function Install-GuestSoftware {
    param([switch]$UsedUnattend)

    Write-LogEntry 'PHASE 7 - Guest Provisioning and Silent Installs' 'PHASE'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-LogEntry "VM '$($CFG.VMName)' not found - skipping Phase 7" 'WARN'
        return
    }

    $credential = Get-GuestCredential
    if (-not $credential) {
        Write-LogEntry 'No stored guest credential.' 'ERROR'
        Write-LogEntry "  Store one with: Set-LazyVMCredential -Name $($CFG.VMName)" 'INFO'
        Stop-WithError 'PowerShell Direct requires an explicit guest credential.'
    }

    if ($vm.State -ne 'Running') {
        Write-LogEntry "VM is '$($vm.State)' - starting it" 'INFO'
        if ($UsedUnattend) {
            # Windows is still to be installed from the ISO.
            Start-VMFromInstallMedia -VMName $CFG.VMName
        }
        else {
            Start-VM -Name $CFG.VMName | Out-Null
        }
    }

    if (-not $UsedUnattend) {
        # This is equally true of a VM that was set up by hand long ago, so the
        # wording must not read as an error in that case.
        Write-LogEntry 'No answer-file disc is attached to this VM.' 'INFO'
        Write-LogEntry '  If the guest is already installed and signed in, that is expected - carry on.' 'INFO'
        Write-LogEntry "  If Windows Setup has not run yet, complete it by hand and create a local" 'INFO'
        Write-LogEntry "  administrator named '$($CFG.GuestAdminUser)' with the stored password." 'INFO'
    }

    Wait-GuestReady -Credential $credential -TimeoutMinutes $CFG.GuestWaitMinutes -RequireProvisioned:$UsedUnattend

    # Provisioning is done, so the answer-file disc (which holds the guest password in
    # clear text) is removed before anything else runs. Doing it here also
    # leaves the SQL disk as the only extra disk, so guest-side disk
    # identification below is unambiguous.
    if ($UsedUnattend) { Remove-UnattendSeedDisk -VMName $CFG.VMName }

    # The SQL data disk is attached HERE, before SQL Server is installed. The
    # previous version pointed SQL's data directories at D: in Phase 7 but only
    # attached the disk in Phase 8, so setup could never have succeeded.
    Add-SqlDataDisk
    Add-DevDriveDisk
    Connect-Guest -Credential $credential | Out-Null
    Initialize-GuestSqlDisk
    Initialize-GuestDevDrive | Out-Null
    Enable-GuestEnhancedSession
    Set-GuestCustomization

    # The tooling list says what this VM gets: the VM's own recorded list, or
    # the default list for a VM that has none yet.
    $tooling = Get-BuildTooling

    # Products from the Visual Studio Installer (Visual Studio, SSMS) first,
    # then SQL Server, then winget packages. Anything already present is
    # skipped: SQL setup with /ACTION=Install against an existing instance
    # fails outright, and re-running a bootstrapper would needlessly modify a
    # working installation.
    $networkReady = Wait-GuestNetwork -TimeoutMinutes $CFG.GuestNetworkWaitMinutes
    if (-not $networkReady) {
        Write-LogEntry 'The guest has no working DNS: products and packages that download cannot be installed' 'WARN'
        Write-LogEntry '  Re-run with -FromPhase 7 once the guest has internet.' 'INFO'
    }
    else {
        Install-ToolingProduct -Tooling $tooling
    }

    $sql = Get-GuestSqlInstance
    if ($sql) {
        Write-LogEntry "SQL Server instance '$($sql.Instance)' already present ($($sql.Edition)) - skipping the install" 'OK'
        Write-LogEntry "  Data directories are whatever that instance was configured with, not necessarily D:." 'INFO'
    }
    else {
        Install-SqlServer
    }

    if ($networkReady) {
        Install-WingetPackage -Packages @($tooling.WingetPackages)
    }

    Write-ToolingReinstallReport -Tooling $tooling

    Write-LogEntry 'Phase 7 complete' 'OK'
}

function Wait-GuestNetwork {
    <#
      Waits for the guest to have working DNS and outbound HTTPS.

      PowerShell Direct runs over the VMBus and works with no network at all,
      so "the guest is reachable" says nothing about whether it can download
      anything. Every network-dependent step needs this first.
    #>
    param([int]$TimeoutMinutes = 10)

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = $false
    $lastDetail = ''

    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-GuestScript -Activity 'guest network check' -TimeoutMinutes 3 -ScriptBlock {
                $result = [pscustomobject]@{ Dns = $false; Https = $false; Detail = '' }
                try {
                    $null = [System.Net.Dns]::GetHostEntry('winget.azureedge.net')
                    $result.Dns = $true
                }
                catch {
                    try {
                        $null = [System.Net.Dns]::GetHostEntry('www.microsoft.com')
                        $result.Dns = $true
                    }
                    catch { $result.Detail = "DNS: $($_.Exception.Message)" }
                }
                if ($result.Dns) {
                    try {
                        $client = New-Object System.Net.Sockets.TcpClient
                        $async = $client.BeginConnect('www.microsoft.com', 443, $null, $null)
                        $result.Https = $async.AsyncWaitHandle.WaitOne(8000, $false) -and $client.Connected
                        $client.Close()
                        if (-not $result.Https) { $result.Detail = 'DNS resolves but port 443 did not connect' }
                    }
                    catch { $result.Detail = "HTTPS: $($_.Exception.Message)" }
                }
                return $result
            }

            if ($state.Dns -and $state.Https) {
                Write-LogEntry 'Guest network is up (DNS and HTTPS both working)' 'OK'
                return $true
            }
            $lastDetail = "$($state.Detail)"
        }
        catch {
            $lastDetail = $_.Exception.Message
        }

        if (-not $announced) {
            Write-LogEntry "Waiting up to $TimeoutMinutes minutes for the guest network to come up..." 'INFO'
            if ($lastDetail) { Write-LogEntry "  $lastDetail" 'INFO' }
            $announced = $true
        }
        Start-Sleep -Seconds 15
    }

    Write-LogEntry "Guest network did not come up within $TimeoutMinutes minutes" 'WARN'
    if ($lastDetail) { Write-LogEntry "  last error: $lastDetail" 'WARN' }
    Write-LogEntry '  Check inside the guest:  Resolve-DnsName www.microsoft.com' 'INFO'
    return $false
}

function Install-WingetPackage {
    <#
      Installs the winget packages in the VM's tooling list. The caller has
      already waited for the guest network: PowerShell Direct works long before
      DNS does, and without that wait installs fail with 0x80072EE7.

      Every package is independent: one that fails is reported and the rest
      carry on. None of them are load-bearing, so nothing here aborts the build.
    #>
    param([object[]]$Packages = @())

    $tools = @()
    foreach ($package in $Packages) {
        $tools += @{ Id = "$($package.Id)"; Source = "$($package.Source)" }
    }
    if ($tools.Count -eq 0) { return }

    Write-LogEntry "Checking $($tools.Count) winget package(s) from the tooling list..." 'INFO'

    try {
        $report = Invoke-GuestScript -Activity 'winget packages' -TimeoutMinutes 60 `
            -ArgumentList @(, $tools) -ScriptBlock {
            param($tools)
            $ErrorActionPreference = 'Continue'
            $log = @()

            # A bare winget exit code tells you nothing. These are the ones
            # that actually come up, so the log explains itself.
            $exitMeanings = @{
                -2147012889 = 'DNS could not be resolved - the guest has no working internet'
                -2147012894 = 'the connection timed out - the guest network is slow or blocked'
                -2147012867 = 'could not connect to the server'
                -2147012721 = 'content decoding failed - check for a proxy intercepting HTTPS'
                -2147012739 = 'a secure channel error - check the date, time and certificates in the guest'
                -1978335189 = 'already installed and up to date'
                -1978335212 = 'no package matched that identifier'
                -1978335215 = 'no applicable installer for this system'
                -1978334972 = 'the installer hash did not match'
                -1978335216 = 'the source could not be updated'
            }
            # Worth one retry; everything else is a real failure.
            $transientCodes = @(-2147012889, -2147012894, -2147012867, -2147012716)

            # winget ships as an MSIX app alias, which is not always on PATH in
            # a PowerShell Direct session. Fall back to the real path.
            $winget = $null
            $cmd = Get-Command winget -ErrorAction SilentlyContinue
            if ($cmd) { $winget = $cmd.Source }
            else {
                $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
                if (Test-Path $candidate) { $winget = $candidate }
                else {
                    $found = @(Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending)
                    if ($found.Count -gt 0) { $winget = $found[0].FullName }
                }
            }
            if (-not $winget) {
                return @('SKIPPED ALL: winget is not available in the guest - install App Installer from the Microsoft Store')
            }

            foreach ($tool in $tools) {
                $id = "$($tool['Id'])"
                $name = $id
                if (-not $id) { continue }
                $sourceArgs = @()
                if ("$($tool['Source'])") { $sourceArgs = @('--source', "$($tool['Source'])") }

                # Already present? winget list exits non-zero when nothing matches.
                $listed = & $winget list --id $id --exact --accept-source-agreements 2>&1
                if ($LASTEXITCODE -eq 0 -and ($listed -join ' ') -match [regex]::Escape($id)) {
                    $log += "present: $name"
                    continue
                }

                # Transient network faults are worth one retry; a package that
                # genuinely does not exist is not.
                $exit = $null
                foreach ($attempt in 1, 2) {
                    # Output is discarded deliberately: winget prints a
                    # progress table whose last line is never the reason for a
                    # failure. The decoded exit code below is.
                    & $winget install --id $id --exact --silent @sourceArgs `
                        --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
                    $exit = $LASTEXITCODE
                    if ($exit -eq 0 -or $transientCodes -notcontains $exit) { break }
                    if ($attempt -eq 1) {
                        $log += "retrying $name after a network error"
                        Start-Sleep -Seconds 20
                    }
                }

                # 0 = installed. -1978335189 (0x8A15002B) = already installed,
                # which winget reports as a failure but is a success for us.
                if ($exit -eq 0) { $log += "installed: $name" }
                elseif ($exit -eq -1978335189) { $log += "present: $name" }
                else {
                    # winget's own output is a progress table, so its last line
                    # is noise. The decoded code is what actually explains it.
                    $meaning = if ($exitMeanings.ContainsKey($exit)) { $exitMeanings[$exit] } else { 'see the winget documentation for this code' }
                    $hex = '0x{0:X8}' -f [uint32]($exit -band 0xFFFFFFFF)
                    $log += "FAILED $name ($id) - exit $exit [$hex] $meaning"
                }
            }
            return $log
        }

        foreach ($line in @($report)) {
            if ($line -like 'FAILED*' -or $line -like 'SKIPPED*') { Write-LogEntry "  $line" 'WARN' }
            elseif ($line -like 'installed:*') { Write-LogEntry "  $line" 'OK' }
            else { Write-LogEntry "  $line" 'INFO' }
        }
    }
    catch {
        Write-LogError 'winget package installation failed (non-fatal)' $_
    }
}

function Get-GuestVisualStudio {
    <#
      The newest Visual Studio of any edition and version. Products the Visual
      Studio Installer also manages, such as SSMS 21 and later, are excluded:
      vswhere lists them alongside Visual Studio, and taking SSMS for Visual
      Studio skipped the Visual Studio install and captured SSMS's settings.
      Returns $null when Visual Studio is not installed.
    #>
    $products = @(Get-GuestInstallerProduct | Where-Object { $_.ProductId -notlike '*.Ssms' })
    if ($products.Count -eq 0) { return $null }
    return ($products | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
}

function Get-GuestInstallerProduct {
    <# Every product the Visual Studio Installer manages in the guest, without exporting their configurations. #>
    try {
        return @(Invoke-GuestScript -Activity 'Visual Studio Installer product detection' -TimeoutMinutes 5 -ScriptBlock {
                $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
                if (-not (Test-Path $vswhere)) { return @() }
                $raw = & $vswhere -all -prerelease -products * -format json -utf8 2>$null
                if (-not $raw) { return @() }

                # Windows PowerShell 5.1 passes a JSON array down the pipeline
                # as one object; foreach splits it into its instances.
                $parsed = ($raw -join "`n") | ConvertFrom-Json
                $products = @()
                foreach ($instance in $parsed) {
                    $products += [pscustomobject]@{
                        InstanceId  = $instance.instanceId
                        ProductId   = $instance.productId
                        ChannelId   = $instance.channelId
                        DisplayName = $instance.displayName
                        Version     = $instance.installationVersion
                        ProductLine = $instance.catalog.productLineVersion
                        InstallPath = $instance.installationPath
                        DevEnvPath  = $instance.productPath
                    }
                }
                return $products
            })
    }
    catch {
        Write-LogEntry "Visual Studio Installer product detection failed, assuming none installed: $($_.Exception.Message)" 'WARN'
        return @()
    }
}

function Get-GuestSqlInstance {
    <# Returns $null when no SQL Server database engine instance is installed. #>
    try {
        return Invoke-GuestScript -Activity 'SQL Server detection' -TimeoutMinutes 5 -ScriptBlock {
            $key = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
            if (-not (Test-Path $key)) { return $null }

            $instances = Get-ItemProperty -Path $key
            $names = @($instances.PSObject.Properties |
                    Where-Object { $_.Name -notlike 'PS*' } |
                    ForEach-Object { $_.Name })
            if ($names.Count -eq 0) { return $null }

            $preferred = if ($names -contains 'MSSQLSERVER') { 'MSSQLSERVER' } else { $names[0] }
            $internal = $instances.$preferred

            $edition = 'unknown'
            $setupKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$internal\Setup"
            if (Test-Path $setupKey) {
                $setup = Get-ItemProperty -Path $setupKey -ErrorAction SilentlyContinue
                if ($setup -and $setup.PSObject.Properties['Edition']) { $edition = $setup.Edition }
            }

            return [pscustomobject]@{
                Instance     = $preferred
                AllInstances = $names
                Edition      = $edition
            }
        }
    }
    catch {
        Write-LogEntry "SQL Server detection failed, assuming not installed: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Add-SqlDataDisk {
    $attached = @(Get-VMHardDiskDrive -VMName $CFG.VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $CFG.SQLDiskPath })

    if ($attached.Count -gt 0) {
        Write-LogEntry 'SQL data disk already attached' 'OK'
        return
    }

    $location = Add-VMScsiHardDisk -VMName $CFG.VMName -Path $CFG.SQLDiskPath
    Write-LogEntry "SQL data disk attached (SCSI 0:$location)" 'OK'
    Start-Sleep -Seconds 5    # let the guest enumerate it
}

function Set-GuestSqlPath {
    <# Rebuilds the guest SQL directory paths around whichever drive letter the
       data disk actually ended up on. Nothing downstream should assume D:. #>
    param([Parameter(Mandatory)][string]$Letter)

    $CFG.GuestSqlDataDir = "${Letter}:\$($CFG.SqlDataFolder)"
    $CFG.GuestSqlLogDir = "${Letter}:\$($CFG.SqlLogFolder)"
    $CFG.GuestSqlTempDir = "${Letter}:\$($CFG.SqlTempFolder)"
    $CFG.GuestSqlBackupDir = "${Letter}:\$($CFG.SqlBackupFolder)"
    $CFG.GuestDataDriveLetter = $Letter
}

function Initialize-GuestSqlDisk {
    <#
      Prepares the SQL data disk and resolves its drive letter.

      The preferred letter is frequently already taken in a guest built by
      hand: on a Generation 2 VM the DVD drive usually claims D: once Windows
      is installed. Blindly assigning D: to the data disk therefore fails. This
      finds the right disk by size, moves an optical drive out of the way if it
      is squatting on the wanted letter, and falls back to whatever letter the
      volume already has rather than aborting the build.
    #>
    Write-LogEntry 'Preparing the SQL data disk inside the guest...' 'INFO'

    $result = Invoke-GuestScript -Activity 'SQL data disk initialisation' -TimeoutMinutes 15 -ArgumentList @(
        $CFG.GuestDataDriveLetter,
        $CFG.SQLDiskSizeGB,
        @($CFG.SqlDataFolder, $CFG.SqlLogFolder, $CFG.SqlTempFolder, $CFG.SqlBackupFolder)
    ) -ScriptBlock {
        param($desiredLetter, $expectedSizeGB, $folders)
        $ErrorActionPreference = 'Stop'
        $notes = @()

        function Get-VolumeByLetter([string]$letter) {
            return Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='${letter}:'" -ErrorAction SilentlyContinue
        }

        function Get-FreeLetter {
            # High letters first, so a relocated optical drive lands out of the way.
            foreach ($c in 'Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') {
                if (-not (Get-VolumeByLetter $c)) { return $c }
            }
            return $null
        }

        # Optical drives never appear in Get-Disk, so this only ever sees real
        # disks. Exclude boot/system rather than assuming the OS is disk 0.
        $candidates = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })
        if ($candidates.Count -eq 0) { throw 'no data disk found in the guest' }

        # Pick by closest size match, so an unrelated extra disk is not grabbed.
        $expectedBytes = [int64]$expectedSizeGB * 1GB
        $disk = $candidates | Sort-Object { [math]::Abs($_.Size - $expectedBytes) } | Select-Object -First 1
        if ($candidates.Count -gt 1) {
            $notes += "guest has $($candidates.Count) data disks; chose disk $($disk.Number) ($([math]::Round($disk.Size/1GB)) GB) as the closest match to $expectedSizeGB GB"
        }

        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false; $notes += 'brought the disk online' }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false; $notes += 'cleared the read-only flag' }
        $disk = Get-Disk -Number $disk.Number

        $formatted = $false
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
            $formatted = $true
        }

        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.Type -ne 'Reserved' -and $_.Size -gt 100MB })

        # Is the wanted letter free, ours already, or held by something else?
        $occupant = Get-VolumeByLetter $desiredLetter
        $ownedByUs = $false
        if ($partitions.Count -gt 0 -and $partitions[0].DriveLetter -eq $desiredLetter) { $ownedByUs = $true }

        if ($occupant -and -not $ownedByUs) {
            if ($occupant.DriveType -eq 5) {
                # 5 = CD-ROM. Move it aside; this is the common case on a
                # Generation 2 VM where the DVD drive took D:.
                $free = Get-FreeLetter
                if ($free) {
                    $occupant.DriveLetter = "${free}:"
                    Set-CimInstance -InputObject $occupant -ErrorAction Stop
                    $notes += "moved the DVD drive off ${desiredLetter}: to ${free}:"
                    Start-Sleep -Seconds 2
                    $occupant = Get-VolumeByLetter $desiredLetter
                }
                else {
                    $notes += "${desiredLetter}: is held by the DVD drive and no spare letter was free"
                }
            }
            else {
                $notes += "${desiredLetter}: is already in use by a $($occupant.FileSystem) volume that is not the SQL data disk"
            }
        }

        # Create or relocate the data volume.
        if ($partitions.Count -eq 0) {
            $target = if (Get-VolumeByLetter $desiredLetter) { $null } else { $desiredLetter }
            if ($target) {
                $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $target
            }
            else {
                $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            }
            Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'SQLDATA' -Confirm:$false -Force | Out-Null
            $formatted = $true
            $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
        }
        else {
            $part = $partitions[0]
            if ($part.DriveLetter -ne $desiredLetter -and -not (Get-VolumeByLetter $desiredLetter)) {
                Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $desiredLetter
                $notes += "moved the data volume to ${desiredLetter}:"
                $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
            }
        }

        $letter = "$($part.DriveLetter)".Trim()
        if (-not $letter) {
            # Last resort: assign anything rather than leave it unreachable.
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter (Get-FreeLetter)
            $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
            $letter = "$($part.DriveLetter)".Trim()
        }
        if (-not $letter) { throw 'the SQL data volume could not be assigned a drive letter' }
        if ($letter -ne $desiredLetter) {
            $notes += "using ${letter}: instead of ${desiredLetter}: - SQL paths follow the actual letter"
        }

        foreach ($folder in $folders) {
            $dir = "${letter}:\$folder"
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }

        return [pscustomobject]@{
            DiskNumber = $disk.Number
            Letter     = $letter
            Formatted  = $formatted
            SizeGB     = [math]::Round($disk.Size / 1GB, 1)
            FreeGB     = [math]::Round((Get-PSDrive -Name $letter).Free / 1GB, 1)
            Notes      = $notes
        }
    }

    foreach ($note in @($result.Notes)) { Write-LogEntry "  $note" 'WARN' }

    # Everything downstream — SQL setup arguments, the restore step — now uses
    # the letter the disk actually got.
    Set-GuestSqlPath -Letter $result.Letter

    if ($result.Formatted) {
        Write-LogEntry "SQL data disk formatted as $($result.Letter): ($($result.FreeGB) GB free of $($result.SizeGB) GB)" 'OK'
    }
    else {
        Write-LogEntry "SQL data disk already prepared, mounted as $($result.Letter): ($($result.FreeGB) GB free of $($result.SizeGB) GB)" 'OK'
    }
    Write-LogEntry "  SQL directories: $($CFG.GuestSqlDataDir), $($CFG.GuestSqlLogDir), $($CFG.GuestSqlTempDir), $($CFG.GuestSqlBackupDir)" 'INFO'
}

function Test-InstallExitCode {
    <# 0 = success, 3010/1641 = success, reboot required. #>
    param(
        [Parameter(Mandatory)][string]$Product,
        $ExitCode
    )
    if ($null -eq $ExitCode) {
        Write-LogEntry "$Product - installer returned no exit code" 'WARN'
        return $false
    }
    $code = [int]$ExitCode
    switch ($code) {
        0 { Write-LogEntry "$Product - installed (exit 0)" 'OK'; return $true }
        3010 { Write-LogEntry "$Product - installed, reboot required (exit 3010)" 'OK'; return $true }
        1641 { Write-LogEntry "$Product - installed, reboot initiated (exit 1641)" 'OK'; return $true }
        default {
            Write-LogEntry "$Product - installer exit code $code" 'ERROR'
            return $false
        }
    }
}

function Install-ToolingProduct {
    <#
      Installs each Visual Studio Installer product in the tooling list that
      the guest does not have yet, from its own channel's bootstrapper, with
      the recorded workloads, components and extensions. A product already
      present is left alone.

      Extensions go in the .vsconfig as marketplace links, which the installer
      installs for all users. Per-user extensions with no marketplace link are
      reported afterwards by Write-ToolingReinstallReport.
    #>
    param([Parameter(Mandatory)]$Tooling)

    $installed = @(Get-GuestInstallerProduct)

    foreach ($product in @($Tooling.Products)) {
        $label = "$($product.DisplayName)"
        $present = $installed | Where-Object { $_.ProductId -eq $product.ProductId -and $_.ChannelId -eq $product.ChannelId } | Select-Object -First 1
        if ($present) {
            Write-LogEntry "$label already installed - skipping" 'OK'
            continue
        }

        $url = Get-ProductBootstrapperUrl -ProductId $product.ProductId -ChannelId $product.ChannelId
        if (-not $url) {
            Write-LogEntry "$label - no bootstrapper is known for channel '$($product.ChannelId)'; add one to InstallerBootstrappers" 'ERROR'
            continue
        }

        $extensions = @(Get-ProductExtensionLink -Product $product)
        $config = [ordered]@{
            version    = '1.0'
            components = @($product.Components)
        }
        if ($extensions.Count -gt 0) { $config['extensions'] = $extensions }
        $configJson = $config | ConvertTo-Json -Depth 4

        $includeRecommended = [bool](Get-RecordField -Item $product -Name 'IncludeRecommended')
        $edition = ($product.ProductId -split '\.')[-1].ToLowerInvariant()

        Write-LogEntry "Installing $label from $url ($(@($product.Components).Count) workload/component id(s), $($extensions.Count) extension(s); up to $($CFG.VSInstallMinutes) minutes)..." 'INFO'
        try {
            $prepared = Invoke-GuestScript -Activity "$label download" -TimeoutMinutes 15 `
                -ArgumentList @($url, "bootstrap-$edition.exe", $CFG.GuestSetupDir, $configJson, $includeRecommended, ($extensions.Count -gt 0)) -ScriptBlock {
                param($url, $bootstrapperName, $setupDir, $configJson, $includeRecommended, $hasExtensions)
                $ErrorActionPreference = 'Stop'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

                $bootstrapper = Join-Path $setupDir $bootstrapperName
                Invoke-WebRequest -Uri $url -OutFile $bootstrapper -UseBasicParsing -TimeoutSec 600

                # Without a byte-order mark: the file is JSON for the installer.
                $configPath = Join-Path $setupDir "$bootstrapperName.vsconfig"
                [IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))

                $arguments = @('--quiet', '--wait', '--norestart', '--config', "`"$configPath`"")
                if ($includeRecommended) { $arguments += '--includeRecommended' }
                if ($hasExtensions) { $arguments += '--allowUnsignedExtensions' }

                return [pscustomobject]@{ FilePath = $bootstrapper; Arguments = ($arguments -join ' ') }
            }
            $exitCode = Invoke-GuestInstaller -FilePath $prepared.FilePath -ArgumentList $prepared.Arguments `
                -Name "install-$edition" -TimeoutMinutes $CFG.VSInstallMinutes -Activity "the $label install"
            if (-not (Test-InstallExitCode -Product $label -ExitCode $exitCode)) {
                Write-LogEntry '  Guest log: C:\Windows\Temp\dd_bootstrapper_*.log and dd_setup_*.log' 'INFO'
            }
        }
        catch {
            Write-LogError "$label install failed" $_
        }
    }
}

function Get-ProductBootstrapperUrl {
    <#
      The bootstrapper for a product's channel, from InstallerBootstrappers.
      {edition} becomes the last part of the product id, lower case:
      Microsoft.VisualStudio.Product.Community -> vs_community.exe.
    #>
    param(
        [Parameter(Mandatory)][string]$ProductId,
        [Parameter(Mandatory)][string]$ChannelId
    )

    $table = $CFG.InstallerBootstrappers
    $key = @($table.Keys) | Where-Object { $_ -eq $ChannelId } | Select-Object -First 1
    if (-not $key) { return $null }
    $edition = ($ProductId -split '\.')[-1].ToLowerInvariant()
    return ("$($table[$key])" -replace '\{edition\}', $edition)
}

function Get-ProductExtensionLink {
    <# Marketplace links for a product's extensions: the instance-wide ones, plus per-user ones that have a marketplace match. #>
    param([Parameter(Mandatory)]$Product)

    $links = @(@($Product.Extensions) | Where-Object { $_ })
    foreach ($extension in @($Product.UserExtensions)) {
        $item = Get-RecordField -Item $extension -Name 'MarketplaceItem'
        if ($item) { $links += "https://marketplace.visualstudio.com/items?itemName=$item" }
    }
    return @($links | Sort-Object -Unique)
}

function Install-SqlServer {
    <#
      Installs from the SQL Server ISO (see Resolve-SqlServerIso), placed in
      the VM's DVD drive for the install. Whatever the drive held before is
      put back afterwards, whether or not the install succeeded.
    #>
    Resolve-SqlServerIso

    $dvd = @(Get-VMDvdDrive -VMName $CFG.VMName)[0]
    if (-not $dvd) {
        Stop-WithError 'The VM has no DVD drive to mount the SQL Server ISO in.'
    }
    $previousMedia = $dvd.Path

    $setupArguments = @(
        '/Q'
        '/IACCEPTSQLSERVERLICENSETERMS'
        '/ACTION=Install'
        '/FEATURES=SQLEngine,FullText'
        '/INSTANCENAME=MSSQLSERVER'
        '/SQLSVCACCOUNT="NT Service\MSSQLSERVER"'
        '/SQLSVCSTARTUPTYPE=Automatic'
        '/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"'
        '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
        "/SQLUSERDBDIR=`"$($CFG.GuestSqlDataDir)`""
        "/SQLUSERDBLOGDIR=`"$($CFG.GuestSqlLogDir)`""
        "/SQLTEMPDBDIR=`"$($CFG.GuestSqlTempDir)`""
        '/SQLBACKUPDIR="' + $CFG.GuestSqlBackupDir + '"'
        '/TCPENABLED=1'
        '/UPDATEENABLED=False'
    ) -join ' '

    Set-VMDvdDrive -VMName $CFG.VMName -ControllerNumber $dvd.ControllerNumber `
        -ControllerLocation $dvd.ControllerLocation -Path $CFG.SQLIsoPath
    Write-LogEntry 'SQL Server ISO placed in the VM DVD drive' 'OK'
    Write-LogEntry "Installing SQL Server 2025 Enterprise Developer (up to $($CFG.SQLInstallMinutes) minutes)..." 'INFO'

    try {
        $setupExe = Invoke-GuestScript -Activity 'SQL Server media check' -TimeoutMinutes 5 -ScriptBlock {
            $ErrorActionPreference = 'Stop'

            # The guest takes a moment to notice the new media. The Windows
            # ISO also has a setup.exe at its root, so the SQL media is told
            # apart by its x64 folder.
            $setupExe = $null
            for ($attempt = 0; $attempt -lt 30 -and -not $setupExe; $attempt++) {
                $setupExe = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=5' |
                    ForEach-Object { "$($_.DeviceID)\" } |
                    Where-Object { (Test-Path "$($_)setup.exe") -and (Test-Path "$($_)x64") } |
                    ForEach-Object { "$($_)setup.exe" } |
                    Select-Object -First 1
                if (-not $setupExe) { Start-Sleep -Seconds 2 }
            }
            if (-not $setupExe) { throw 'the SQL Server media did not appear on any DVD drive in the guest' }
            return $setupExe
        }
        $exitCode = Invoke-GuestInstaller -FilePath $setupExe -ArgumentList $setupArguments `
            -Name 'install-sqlserver' -TimeoutMinutes $CFG.SQLInstallMinutes -Activity 'the SQL Server install'
    }
    finally {
        Set-VMDvdDrive -VMName $CFG.VMName -ControllerNumber $dvd.ControllerNumber `
            -ControllerLocation $dvd.ControllerLocation -Path $previousMedia
        Write-LogEntry 'VM DVD drive restored to its previous media' 'OK'
    }

    if (-not (Test-InstallExitCode -Product 'SQL Server 2025 Enterprise Developer' -ExitCode $exitCode)) {
        Write-LogEntry '  Guest log: C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log\Summary.txt' 'INFO'
        Stop-WithError "SQL Server installation failed (exit $exitCode)."
    }
}
