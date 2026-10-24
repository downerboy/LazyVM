# HyperV.ps1 - Build phases 0-2: Hyper-V services, host readiness, turning Hyper-V on.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Repair-HyperVService {
    <#
      Phase 0. Only vmms and, if disabled, vmcompute are corrected: they are
      the host services PowerShell Direct and Copy-VMFile rely on. Returns
      $true when the Hyper-V feature looks missing or broken.
    #>
    $needsFeatureInstall = $false
    $hostServices = @(
        [pscustomobject]@{ Name = 'vmms'; Display = 'Hyper-V Virtual Machine Management'; Want = 'Automatic'; MustRun = $true }
        [pscustomobject]@{ Name = 'vmcompute'; Display = 'Hyper-V Host Compute Service'; Want = 'Manual'; MustRun = $false }
    )

    foreach ($svc in $hostServices) {
        $service = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-LogEntry "$($svc.Display) - NOT FOUND. Hyper-V feature is not installed." 'WARN'
            $needsFeatureInstall = $true
            continue
        }

        $startType = "$($service.StartType)"
        if ($startType -eq 'Disabled' -or ($svc.Want -eq 'Automatic' -and $startType -ne 'Automatic')) {
            Write-LogEntry "$($svc.Display) - startup type '$startType' -> setting $($svc.Want)" 'WARN'
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
            Write-LogEntry "$($svc.Display) - startup type $startType (expected $($svc.Want))" 'INFO'
        }

        if (-not $svc.MustRun) { continue }
        if ($service.Status -eq 'Running') {
            Write-LogEntry "$($svc.Display) - Running" 'OK'
            continue
        }
        Write-LogEntry "$($svc.Display) - State='$($service.Status)' -> starting..." 'WARN'
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
    return $needsFeatureInstall
}

function Test-HostReadiness {
    <# Phase 1: virtualization support, memory and free space for this VM. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem

    Write-LogEntry "CPU  : $($cpu.Name)" 'INFO'
    Write-LogEntry "Cores: $($cpu.NumberOfCores)  Threads: $($cpu.NumberOfLogicalProcessors)" 'INFO'
    if ($cpu.NumberOfLogicalProcessors -lt $settings.vCPU) {
        Write-LogEntry "Host has $($cpu.NumberOfLogicalProcessors) logical processors but the VM is configured for $($settings.vCPU) vCPU" 'WARN'
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
            $slatLine = @(& systeminfo.exe 2>&1 | Where-Object { $_ -match 'Second Level Address Translation' })
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
        throw 'SLAT (Intel EPT / AMD RVI) not detected. Enable Intel VT-x / AMD-V and EPT/RVI in UEFI firmware, then re-run.'
    }
    if ($cpu.VMMonitorModeExtensions) {
        Write-LogEntry 'VM Monitor Mode Extensions - supported' 'OK'
    }
    else {
        Write-LogEntry 'VM Monitor Mode Extensions not reported (expected when a hypervisor is already active)' 'INFO'
    }

    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-LogEntry "Host RAM: $ramGB GB" 'INFO'
    if ($ramGB -lt ($settings.MemMaxGB + 4)) {
        Write-LogEntry "Host RAM is within 4 GB of the VM maximum ($($settings.MemMaxGB) GB) - the host may page under load" 'WARN'
    }
    else {
        Write-LogEntry "Host RAM comfortably supports Dynamic Memory $($settings.MemMinGB)-$($settings.MemMaxGB) GB" 'OK'
    }

    # Free space on the volumes actually used, sized from the settings and
    # rolled up by volume so two needs on one drive are not checked apart.
    $requirements = @(
        [pscustomobject]@{ Path = $settings.DiskDir; NeedGB = $settings.OSDiskSizeGB; What = 'OS VHDX' }
        [pscustomobject]@{ Path = (Split-Path $settings.SQLDiskPath -Parent); NeedGB = 20; What = 'SQL data disk (initial allocation)' }
        [pscustomobject]@{ Path = $settings.ISOSearchRoot; NeedGB = $settings.ISOMinSizeGB + 2; What = 'ISO + installers' }
    )
    $byVolume = @{}
    foreach ($req in $requirements) {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($req.Path))
        if (-not $byVolume.ContainsKey($root)) { $byVolume[$root] = 0 }
        $byVolume[$root] += $req.NeedGB
        Write-LogEntry "  needs $($req.NeedGB) GB on $root for $($req.What)" 'INFO'
    }
    foreach ($root in $byVolume.Keys) {
        $freeGB = Get-FreeSpaceGB -Path $root
        $needGB = $byVolume[$root]
        if ($freeGB -lt 0) { Write-LogEntry "$root - could not determine free space" 'WARN' }
        elseif ($freeGB -lt $needGB) { Write-LogEntry "$root - $freeGB GB free, about $needGB GB needed. Dynamic disks will grow into this over time." 'WARN' }
        else { Write-LogEntry "$root - $freeGB GB free (need ~$needGB GB)" 'OK' }
    }
}

function Enable-HyperVFeature {
    <#
      Phase 2. Returns $true when the host is restarting to finish turning on
      Hyper-V; the build stops, and the resume task carries on at phase 3.
      The resume task runs at startup as SYSTEM, which works whoever signs
      in next, or if nobody does.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    # Hyper-V is not offered on Home editions; say so now rather than fail
    # obscurely when the VM is created.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-LogEntry "OS: $($os.Caption) (build $($os.BuildNumber))" 'INFO'
    if ($os.Caption -match '(?i)\bHome\b') {
        throw "Hyper-V is not available on $($os.Caption). Windows Pro, Enterprise or Education is required."
    }

    # Each feature is classified explicitly, so a name that does not exist on
    # this edition is reported rather than taken as already enabled.
    $wanted = 'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Tools-All'
    $enabled = @(); $disabled = @(); $absent = @()
    foreach ($name in $wanted) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
        if (-not $feature) { $absent += $name }
        elseif ($feature.State -eq 'Enabled') { $enabled += $name }
        else { $disabled += "$name ($($feature.State))" }
    }

    if ($absent.Count -gt 0) { Write-LogEntry "Feature names not present on this edition: $($absent -join ', ')" 'WARN' }
    if ($enabled.Count -gt 0) { Write-LogEntry "Already enabled: $($enabled -join ', ')" 'OK' }
    if ($disabled.Count -eq 0) {
        if ($enabled.Count -eq 0) {
            throw 'No Hyper-V features are available on this system. Check the Windows edition and firmware virtualization settings.'
        }
        Write-LogEntry 'All required Hyper-V features are enabled' 'OK'
        return $false
    }

    Write-LogEntry "Not yet enabled: $($disabled -join ', ')" 'WARN'
    Register-ResumeTask -VM $VM -Phase 3

    Write-LogEntry 'Enabling Microsoft-Hyper-V-All (several minutes)...' 'WARN'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart
    if ($result.RestartNeeded) {
        Write-LogEntry 'Hyper-V enabled. Rebooting in 30 seconds; the build resumes automatically at Phase 3.' 'WARN'
        Write-LogEntry "Cancel with: Unregister-ScheduledTask -TaskName '$($VM.Settings.ResumeTaskName)' -Confirm:`$false" 'INFO'
        Start-Sleep -Seconds 30
        Restart-Computer -Force
        return $true
    }

    Write-LogEntry 'Hyper-V enabled without requiring a restart' 'OK'
    Unregister-ResumeTask -VM $VM
    return $false
}

function Register-ResumeTask {
    <# Records where the build is to carry on, and a startup task that runs it. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][int]$Phase
    )

    $settings = $VM.Settings
    if (-not (Test-Path -LiteralPath $settings.ResumeRegKey)) {
        New-Item -Path $settings.ResumeRegKey -Force | Out-Null
    }
    Set-ItemProperty -Path $settings.ResumeRegKey -Name 'ResumePhase' -Value $Phase -Type DWord

    # Build-LazyVM reads the resume phase from the registry key above.
    $action = New-LazyVMTaskAction -Command "Build-LazyVM -Name '$($VM.Name)'"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT2M'   # let services settle before the build resumes
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $settings.ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Force | Out-Null

    Write-LogEntry "Resume task '$($settings.ResumeTaskName)' registered (resumes at Phase $Phase after reboot)" 'OK'
}

function Unregister-ResumeTask {
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    if (Get-ScheduledTask -TaskName $settings.ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $settings.ResumeTaskName -Confirm:$false
        Write-LogEntry "Resume task '$($settings.ResumeTaskName)' removed" 'INFO'
    }
    if (Test-Path -LiteralPath $settings.ResumeRegKey) {
        Remove-ItemProperty -Path $settings.ResumeRegKey -Name 'ResumePhase' -ErrorAction SilentlyContinue
    }
}

function Get-ResumePhase {
    <#
      The phase a build interrupted by a host restart carries on from, or 0.
      Read, not cleared: it is cleared only once the build succeeds, so a
      crash while resuming keeps it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $props = Get-ItemProperty -Path $VM.Settings.ResumeRegKey -ErrorAction SilentlyContinue
    if (-not $props -or -not $props.PSObject.Properties['ResumePhase']) { return 0 }
    return [int]$props.ResumePhase
}
