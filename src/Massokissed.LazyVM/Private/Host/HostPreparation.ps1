# HostPreparation.ps1 - Phases 0-5: Hyper-V service check, readiness, feature enable, folders, assets, SQL disk.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 0 — Hyper-V Service Health Check
#
#  Only vmms (and, if disabled, vmcompute) are corrected. The vmic* services
#  are GUEST-side integration components: on a Hyper-V host they are
#  trigger-start Manual by design, and the host's copies play no part in
#  Copy-VMFile or PowerShell Direct — those are served by vmms worker
#  processes. The previous version forced all ten to Automatic, which fought
#  Windows' defaults for no benefit, so they are now reported only.
# ─────────────────────────────────────────────────────────────────────────────
function Repair-HyperVService {
    Write-LogEntry 'PHASE 0 - Hyper-V Service Health Check' 'PHASE'

    $needsFeatureInstall = $false

    # Services the host genuinely needs, with the startup type they should have.
    $hostServices = @(
        [pscustomobject]@{ Name = 'vmms'; Display = 'Hyper-V Virtual Machine Management'; Want = 'Automatic'; MustRun = $true }
        [pscustomobject]@{ Name = 'vmcompute'; Display = 'Hyper-V Host Compute Service'; Want = 'Manual'; MustRun = $false }
    )

    # Guest-side components. Reported for diagnostics; never reconfigured.
    $guestServices = @(
        'vmicheartbeat', 'vmickvpexchange', 'vmicguestinterface', 'vmicrdv',
        'vmicshutdown', 'vmictimesync', 'vmicvmsession', 'vmicvss'
    )

    foreach ($svc in $hostServices) {
        # Win32_Service is used for reading because ServiceController.StartType
        # is not present on every PowerShell 5.1 / .NET combination, and
        # StrictMode turns a missing property into a terminating error.
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue

        if (-not $cim) {
            Write-LogEntry "$($svc.Display) - NOT FOUND. Hyper-V feature is not installed." 'WARN'
            $needsFeatureInstall = $true
            continue
        }

        $startMode = $cim.StartMode      # Auto | Manual | Disabled | Boot | System
        $wantMode = if ($svc.Want -eq 'Automatic') { 'Auto' } else { $svc.Want }

        if ($startMode -eq 'Disabled' -or ($svc.Want -eq 'Automatic' -and $startMode -ne 'Auto')) {
            Write-LogEntry "$($svc.Display) - StartMode='$startMode' -> setting $($svc.Want)" 'WARN'
            try {
                Set-Service -Name $svc.Name -StartupType $svc.Want -ErrorAction Stop
                Write-LogEntry "$($svc.Display) - startup type set to $($svc.Want)" 'OK'
            }
            catch {
                Write-LogError "$($svc.Display) - could not set startup type" $_
                $needsFeatureInstall = $true
                continue
            }
        }
        else {
            Write-LogEntry "$($svc.Display) - StartMode=$startMode (expected $wantMode)" 'INFO'
        }

        if ($svc.MustRun -and $cim.State -ne 'Running') {
            Write-LogEntry "$($svc.Display) - State='$($cim.State)' -> starting..." 'WARN'
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                (Get-Service -Name $svc.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                Write-LogEntry "$($svc.Display) - now Running" 'OK'
            }
            catch {
                Write-LogError "$($svc.Display) - failed to start" $_
                $needsFeatureInstall = $true
            }
        }
        elseif ($svc.MustRun) {
            Write-LogEntry "$($svc.Display) - Running" 'OK'
        }
    }

    $present = @()
    $missing = @()
    foreach ($name in $guestServices) {
        if (Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue) {
            $present += $name
        }
        else { $missing += $name }
    }
    Write-LogEntry "Guest integration components on host: $($present.Count) present, $($missing.Count) absent (informational - not reconfigured)" 'INFO'

    Write-LogEntry 'Phase 0 complete' 'OK'
    return $needsFeatureInstall
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — CPU / Firmware / Capacity Readiness
# ─────────────────────────────────────────────────────────────────────────────
function Test-HostReadiness {
    Write-LogEntry 'PHASE 1 - CPU, Firmware and Capacity Readiness' 'PHASE'

    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem

    Write-LogEntry "CPU  : $($cpu.Name)" 'INFO'
    Write-LogEntry "Cores: $($cpu.NumberOfCores)  Threads: $($cpu.NumberOfLogicalProcessors)" 'INFO'

    if ($cpu.NumberOfLogicalProcessors -lt $CFG.vCPU) {
        Write-LogEntry "Host has $($cpu.NumberOfLogicalProcessors) logical processors but the VM is configured for $($CFG.vCPU) vCPU" 'WARN'
    }

    # SLAT. WMI hides raw CPU flags once Hyper-V owns the machine, so
    # SecondLevelAddressTranslationExtensions reads False on any running
    # Hyper-V host. Cheapest reliable signals first; systeminfo (slow, and
    # its output is localised) only as a last resort.
    $slatConfirmed = $false
    if ($cs.HypervisorPresent) {
        Write-LogEntry 'SLAT confirmed - a hypervisor is already running (HypervisorPresent = True)' 'OK'
        $slatConfirmed = $true
    }
    elseif ($cpu.SecondLevelAddressTranslationExtensions) {
        Write-LogEntry 'SLAT confirmed via WMI' 'OK'
        $slatConfirmed = $true
    }
    else {
        Write-LogEntry 'SLAT not visible via WMI - falling back to systeminfo (this takes ~30s)' 'INFO'
        try {
            $sysinfo = & systeminfo.exe 2>&1
            $slatLine = @($sysinfo | Where-Object { $_ -match 'Second Level Address Translation' })
            if ($slatLine.Count -gt 0 -and ($slatLine -join ' ') -match '(?i)\byes\b') {
                Write-LogEntry 'SLAT confirmed via systeminfo' 'OK'
                $slatConfirmed = $true
            }
            elseif ($slatLine.Count -eq 0) {
                Write-LogEntry 'systeminfo did not report a SLAT line (non-English Windows?) - cannot confirm' 'WARN'
            }
        }
        catch {
            Write-LogError 'systeminfo check failed' $_
        }
    }

    if (-not $slatConfirmed) {
        Stop-WithError 'SLAT (Intel EPT / AMD RVI) not detected. Enable Intel VT-x / AMD-V and EPT/RVI in UEFI firmware, then re-run.'
    }

    if ($cpu.VMMonitorModeExtensions) {
        Write-LogEntry 'VM Monitor Mode Extensions - supported' 'OK'
    }
    else {
        Write-LogEntry 'VM Monitor Mode Extensions not reported (expected when a hypervisor is already active)' 'INFO'
    }

    # RAM
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-LogEntry "Host RAM: $ramGB GB" 'INFO'
    if ($ramGB -lt ($CFG.MemMaxGB + 4)) {
        Write-LogEntry "Host RAM is within 4 GB of the VM maximum ($($CFG.MemMaxGB) GB) - the host may page under load" 'WARN'
    }
    else {
        Write-LogEntry "Host RAM comfortably supports Dynamic Memory $($CFG.MemMinGB)-$($CFG.MemMaxGB) GB" 'OK'
    }

    # Free space, measured on the volumes actually used and sized from config.
    $requirements = @(
        [pscustomobject]@{ Path = $CFG.VHDXRoot; NeedGB = $CFG.OSDiskSizeGB; What = 'OS VHDX' }
        [pscustomobject]@{ Path = (Split-Path $CFG.SQLDiskPath -Parent); NeedGB = 20; What = 'SQL data disk (initial allocation)' }
        [pscustomobject]@{ Path = $CFG.ISOSearchRoot; NeedGB = $CFG.ISOMinSizeGB + 2; What = 'ISO + installers' }
    )

    # Roll up by volume so two requirements on C: are not each checked in isolation.
    $byVolume = @{}
    foreach ($req in $requirements) {
        $root = [IO.Path]::GetPathRoot((Resolve-PathForce $req.Path))
        if (-not $byVolume.ContainsKey($root)) { $byVolume[$root] = 0 }
        $byVolume[$root] += $req.NeedGB
        Write-LogEntry "  needs $($req.NeedGB) GB on $root for $($req.What)" 'INFO'
    }

    foreach ($root in $byVolume.Keys) {
        $freeGB = Get-FreeSpaceGB -Path $root
        $needGB = $byVolume[$root]
        if ($freeGB -lt 0) {
            Write-LogEntry "$root - could not determine free space" 'WARN'
        }
        elseif ($freeGB -lt $needGB) {
            Write-LogEntry "$root - $freeGB GB free, about $needGB GB needed. Dynamic disks will grow into this over time." 'WARN'
        }
        else {
            Write-LogEntry "$root - $freeGB GB free (need ~$needGB GB)" 'OK'
        }
    }

    Write-LogEntry 'Phase 1 complete' 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — Hyper-V Feature Enable (reboot + self-resuming scheduled task)
#
#  The previous version resumed via HKLM\...\RunOnce, which fires in the next
#  interactive user's context, is usually unelevated (so #Requires
#  -RunAsAdministrator fails immediately) and never fires at all under a SYSTEM
#  scheduled task. A one-shot startup task as SYSTEM works in every case.
# ─────────────────────────────────────────────────────────────────────────────
function Enable-HyperVFeature {
    <#
      Returns $true when the host is restarting to finish enabling Hyper-V;
      the build then stops, and the resume task carries on at Phase 3.
    #>
    Write-LogEntry 'PHASE 2 - Hyper-V Feature Installation' 'PHASE'

    # Hyper-V is not offered on Home editions. Detect that now rather than
    # failing obscurely in Phase 6.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-LogEntry "OS: $($os.Caption) (build $($os.BuildNumber))" 'INFO'
    if ($os.Caption -match '(?i)\bHome\b') {
        Stop-WithError "Hyper-V is not available on $($os.Caption). Windows Pro, Enterprise or Education is required."
    }

    # Microsoft-Hyper-V-All is the umbrella feature; enabling it with -All
    # pulls in the hypervisor, management tools and PowerShell module. Each
    # feature is classified explicitly so a name that does not exist on this
    # edition is reported rather than silently treated as "already enabled",
    # which is what the previous `$f -and ($f.State -ne 'Enabled')` filter did.
    $wanted = @(
        'Microsoft-Hyper-V-All'
        'Microsoft-Hyper-V'
        'Microsoft-Hyper-V-Hypervisor'
        'Microsoft-Hyper-V-Management-PowerShell'
        'Microsoft-Hyper-V-Tools-All'
    )

    $enabled = @()
    $disabled = @()
    $absent = @()

    foreach ($name in $wanted) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
        if (-not $feature) { $absent += $name }
        elseif ($feature.State -eq 'Enabled') { $enabled += $name }
        else { $disabled += "$name ($($feature.State))" }
    }

    if ($absent.Count -gt 0) {
        Write-LogEntry "Feature names not present on this edition: $($absent -join ', ')" 'WARN'
    }
    if ($enabled.Count -gt 0) {
        Write-LogEntry "Already enabled: $($enabled -join ', ')" 'OK'
    }

    if ($disabled.Count -eq 0) {
        if ($enabled.Count -eq 0) {
            Stop-WithError 'No Hyper-V features are available on this system. Check the Windows edition and firmware virtualization settings.'
        }
        Write-LogEntry 'All required Hyper-V features are enabled' 'OK'
        return $false
    }

    Write-LogEntry "Not yet enabled: $($disabled -join ', ')" 'WARN'

    Register-ResumeTask -Phase 3

    Write-LogEntry 'Enabling Microsoft-Hyper-V-All (several minutes)...' 'WARN'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart

    if ($result.RestartNeeded) {
        Write-LogEntry 'Hyper-V enabled. Rebooting in 30 seconds; the build resumes automatically at Phase 3.' 'WARN'
        Write-LogEntry "Cancel with: Unregister-ScheduledTask -TaskName '$($CFG.ResumeTaskName)' -Confirm:`$false" 'INFO'
        Start-Sleep -Seconds 30
        Restart-Computer -Force
        # Restart-Computer returns immediately; the caller stops here so no
        # later phase starts work that the imminent restart would tear down.
        return $true
    }

    Write-LogEntry 'Hyper-V enabled without requiring a restart' 'OK'
    Unregister-ResumeTask
    return $false
}

function Register-ResumeTask {
    param([Parameter(Mandatory)][int]$Phase)

    if (-not (Test-Path -LiteralPath $CFG.ResumeRegKey)) {
        New-Item -Path $CFG.ResumeRegKey -Force | Out-Null
    }
    Set-ItemProperty -Path $CFG.ResumeRegKey -Name 'ResumePhase' -Value $Phase -Type DWord

    # Build-LazyVM reads the resume phase from the registry key above.
    $action = New-LazyVMTaskAction -Command "Build-LazyVM -Name '$($CFG.VMName)'"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT2M'   # let services settle before the build resumes
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $CFG.ResumeTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    Write-LogEntry "Resume task '$($CFG.ResumeTaskName)' registered (resumes at Phase $Phase after reboot)" 'OK'
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $CFG.ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $CFG.ResumeTaskName -Confirm:$false
        Write-LogEntry "Resume task '$($CFG.ResumeTaskName)' removed" 'INFO'
    }
    if (Test-Path -LiteralPath $CFG.ResumeRegKey) {
        Remove-ItemProperty -Path $CFG.ResumeRegKey -Name 'ResumePhase' -ErrorAction SilentlyContinue
    }
}

function Get-ResumePhase {
    <# Reads the resume point WITHOUT clearing it. The previous version deleted
       the key before the resumed run did any work, so a crash during resume
       lost the resume point entirely. It is cleared only on success. #>
    if (-not (Test-Path -LiteralPath $CFG.ResumeRegKey)) { return 0 }
    $props = Get-ItemProperty -Path $CFG.ResumeRegKey -ErrorAction SilentlyContinue
    if (-not $props -or -not $props.PSObject.Properties['ResumePhase']) { return 0 }
    $phase = [int]$props.ResumePhase
    if ($phase -gt 0) { Write-LogEntry "Resuming after reboot from Phase $phase" 'INFO' }
    return $phase
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 3 — Folder Structure
# ─────────────────────────────────────────────────────────────────────────────
function Initialize-HostFolder {
    Write-LogEntry 'PHASE 3 - Folder Structure' 'PHASE'

    $folders = @(
        $CFG.Root
        $CFG.ISOSearchRoot
        (Split-Path $CFG.SQLIsoPath -Parent)
        $CFG.VHDXRoot
        (Split-Path $CFG.SQLDiskPath -Parent)
        $CFG.CredStoreDir
        (Split-Path $CFG.GuestCredFile -Parent)
        (Split-Path $CFG.VSSettingsBackup -Parent)
        (Split-Path $CFG.LogFile -Parent)
        $CFG.CheckpointDir
    ) | Select-Object -Unique

    $created = 0
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-LogEntry "Created : $folder" 'OK'
            $created++
        }
    }
    Write-LogEntry "Phase 3 complete - $($folders.Count) folders verified, $created created" 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 4 — Asset Verification
#
#  The ISO is VERIFIED, never downloaded. Microsoft's evaluation fwlink returns
#  an HTML registration page, not an image: the previous version saved that
#  48 KB page as Win11Ent_Eval.iso, then deleted and re-downloaded it on every
#  subsequent run. Validity is proved by the ISO 9660 'CD001' signature rather
#  than by file size alone.
#
#  The SQL Server ISO, by contrast, is a direct download (Resolve-SqlServerIso).
# ─────────────────────────────────────────────────────────────────────────────
function Confirm-InstallMedia {
    Write-LogEntry 'PHASE 4 - Asset Verification' 'PHASE'

    Resolve-InstallationIso
    Resolve-SqlServerIso

    Write-LogEntry 'Phase 4 complete' 'OK'
}

function Resolve-SqlServerIso {
    <#
      The SQL Server installation media, downloaded to the host once and
      mounted in the guest at install time. Full media rather than the small
      web installer: Microsoft retires web installer builds, and a retired one
      shows a modal "no longer supported" dialog even with /QUIET, which in an
      unattended guest waits, unseen, until the install times out.

      Called by Phase 4 and again just before the install, so a run started
      at a later phase still gets the media.

      The download goes to a .tmp file and is validated before replacing the
      existing copy, so a failed download can never destroy a good one.
    #>
    if (Test-IsoFile -Path $CFG.SQLIsoPath) {
        $size = Format-Size ((Get-Item -LiteralPath $CFG.SQLIsoPath).Length)
        Write-LogEntry "SQL Server ISO - OK ($size) at $($CFG.SQLIsoPath)" 'OK'
        return
    }

    if (Test-Path -LiteralPath $CFG.SQLIsoPath) {
        Write-LogEntry 'SQL Server ISO - present but not a valid image; re-downloading' 'WARN'
    }
    else {
        Write-LogEntry 'SQL Server ISO - not found; downloading (a few GB, this can take a while)' 'INFO'
    }

    $temp = "$($CFG.SQLIsoPath).tmp"
    $client = New-Object System.Net.WebClient
    try {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        $client.DownloadFile($CFG.SQLIsoUrl, $temp)

        if (-not (Test-IsoFile -Path $temp)) {
            throw "downloaded file is not an ISO image (got $(Format-Size (Get-Item -LiteralPath $temp).Length) - the URL probably returned an HTML page)"
        }

        # Only now is the existing copy replaced.
        Move-Item -LiteralPath $temp -Destination $CFG.SQLIsoPath -Force
        Write-LogEntry "SQL Server ISO - downloaded ($(Format-Size (Get-Item -LiteralPath $CFG.SQLIsoPath).Length))" 'OK'
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-LogError 'SQL Server ISO - download failed' $_
        Stop-WithError "Cannot continue without the SQL Server ISO. Download it from $($CFG.SQLIsoUrl) and save it to $($CFG.SQLIsoPath)."
    }
    finally {
        $client.Dispose()
    }
}

function Test-WindowsIsoName {
    <#
      Whether a file name looks like the Windows 11 evaluation ISO, so a
      search of the Downloads folder never adopts some other ISO. Microsoft
      names it like ...CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso.
    #>
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -match '(?i)\.iso$' -and $Name -match '(?i)ENTERPRISEEVAL|Win(dows)?[ _.-]?11')
}

function Get-DownloadsFolder {
    <# The signed-in user's Downloads folder, wherever it has been moved to. #>
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $value = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($value) { return [Environment]::ExpandEnvironmentVariables($value) }
    return Join-Path -Path $env:USERPROFILE -ChildPath 'Downloads'
}

function Resolve-InstallationIso {
    <#
      Finds the Windows ISO: at ISOPath; else any valid image in the ISO
      folder; else the evaluation ISO in the user's Downloads folder, which is
      moved to ISOPath so the scheduled runs, which run as SYSTEM and cannot
      see anyone's Downloads, find it later. When there is none, opens the
      download page for whoever is there and stops.
    #>
    $minimum = $CFG.ISOMinSizeGB * 1GB

    if ((Test-IsoFile -Path $CFG.ISOPath) -and (Get-Item -LiteralPath $CFG.ISOPath).Length -ge $minimum) {
        Write-LogEntry "Windows ISO - OK ($(Format-Size (Get-Item -LiteralPath $CFG.ISOPath).Length)) at $($CFG.ISOPath)" 'OK'
        return
    }

    $inIsoFolder = @(
        Get-ChildItem -LiteralPath $CFG.ISOSearchRoot -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $minimum -and (Test-IsoFile -Path $_.FullName) } |
            Sort-Object LastWriteTime -Descending
    )
    if ($inIsoFolder.Count -gt 0) {
        $CFG.ISOPath = $inIsoFolder[0].FullName
        Write-LogEntry "Windows ISO - using $($CFG.ISOPath) ($(Format-Size $inIsoFolder[0].Length))" 'OK'
        return
    }

    $downloads = Get-DownloadsFolder
    $downloaded = @(
        Get-ChildItem -LiteralPath $downloads -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { (Test-WindowsIsoName -Name $_.Name) -and $_.Length -ge $minimum -and (Test-IsoFile -Path $_.FullName) } |
            Sort-Object LastWriteTime -Descending
    )
    if ($downloaded.Count -gt 0) {
        $folder = Split-Path -Path $CFG.ISOPath -Parent
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        Write-LogEntry "Moving the Windows ISO from $downloads to $($CFG.ISOPath), where the scheduled rebuilds can find it..." 'INFO'
        Move-Item -LiteralPath $downloaded[0].FullName -Destination $CFG.ISOPath
        Write-LogEntry "Windows ISO - OK ($(Format-Size (Get-Item -LiteralPath $CFG.ISOPath).Length)) at $($CFG.ISOPath)" 'OK'
        return
    }

    Write-LogEntry 'No Windows 11 Enterprise evaluation ISO was found.' 'ERROR'
    Write-LogEntry '  It cannot be downloaded automatically: the download is behind a registration form.' 'INFO'
    Write-LogEntry "  Download it from $($CFG.ISODownloadPage)" 'INFO'
    Write-LogEntry "  into your Downloads folder, then run the same Build-LazyVM command again." 'INFO'

    # Someone is at the keyboard, so take them straight to the form. A
    # scheduled run has nobody to read the page and skips this.
    if (-not (Test-Unattended)) {
        try {
            Start-Process -FilePath $CFG.ISODownloadPage
            Write-LogEntry '  The download page has been opened in your browser.' 'INFO'
        }
        catch {
            Write-LogEntry "  Could not open the download page: $($_.Exception.Message)" 'WARN'
        }
    }
    Stop-WithError "No Windows ISO yet. Download it into $downloads, then run Build-LazyVM again."
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 5 — SQL Data Disk
# ─────────────────────────────────────────────────────────────────────────────
function Initialize-SqlDataVhd {
    Write-LogEntry 'PHASE 5 - SQL Data Disk' 'PHASE'

    if (Test-Path -LiteralPath $CFG.SQLDiskPath) {
        # .Length is the allocated size of a dynamic VHDX, not its configured
        # capacity — the previous version reported the two as if they were the
        # same thing. Report both.
        $onDisk = (Get-Item -LiteralPath $CFG.SQLDiskPath).Length
        try {
            $vhd = Get-VHD -Path $CFG.SQLDiskPath
            Write-LogEntry ("SQLDisk.vhdx exists - capacity {0}, currently allocated {1}, type {2}" -f `
                (Format-Size $vhd.Size), (Format-Size $onDisk), $vhd.VhdType) 'OK'
            if ($vhd.Size -lt ($CFG.SQLDiskSizeGB * 1GB)) {
                Write-LogEntry "  Configured capacity is smaller than the requested $($CFG.SQLDiskSizeGB) GB. Expand with Resize-VHD if needed." 'WARN'
            }
        }
        catch {
            Write-LogEntry "SQLDisk.vhdx exists ($(Format-Size $onDisk) on disk) - could not read VHD metadata: $($_.Exception.Message)" 'WARN'
        }
        Write-LogEntry 'Existing database data preserved' 'INFO'
        return
    }

    Write-LogEntry "Creating $($CFG.SQLDiskSizeGB) GB dynamic VHDX..." 'INFO'
    New-VHD -Path $CFG.SQLDiskPath -SizeBytes ($CFG.SQLDiskSizeGB * 1GB) -Dynamic | Out-Null
    Write-LogEntry "SQLDisk.vhdx created at $($CFG.SQLDiskPath)" 'OK'
}

function Initialize-DevDriveVhd {
    Write-LogEntry 'PHASE 5b - Dev Drive Disk' 'PHASE'
    if (-not $CFG.UseDevDrive) {
        Write-LogEntry 'Dev Drive disabled in config - skipping' 'INFO'
        return
    }
    New-DevDriveDisk
}
