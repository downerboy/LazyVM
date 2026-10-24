# VMBuild.ps1 - Build phase 6: the VM itself, its TPM, and starting it from the ISO.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function New-GuestVM {
    <#
      Creates the Generation 2 VM with Secure Boot, a TPM, dynamic memory, the
      Windows ISO and, with -UseUnattend, the answer-file disc. A VM that
      already exists is left alone. An OS disk left behind by a VM deleted in
      Hyper-V Manager is reused; delete it first for a clean install.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$UseUnattend
    )

    $settings = $VM.Settings
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not available. Enable Microsoft-Hyper-V-Management-PowerShell (Phase 2) and re-run.'
    }

    $switchName = Initialize-VMSwitch -VM $VM

    $existing = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LogEntry "VM '$($VM.Name)' already exists (State: $($existing.State)) - skipping creation" 'INFO'
        Write-LogEntry "To rebuild: Invoke-LazyVMRebuild -Name $($VM.Name)" 'INFO'
        return
    }

    $osDiskPath = $settings.OSDiskPath
    $reusingDisk = Test-Path -LiteralPath $osDiskPath
    if ($reusingDisk) {
        Write-LogEntry "OS VHDX already exists ($(Format-Size (Get-Item -LiteralPath $osDiskPath).Length) allocated) - reusing it" 'WARN'
        Write-LogEntry "  Delete $osDiskPath first if you want a clean install." 'INFO'
    }
    else {
        Write-LogEntry "Creating OS VHDX: $osDiskPath ($($settings.OSDiskSizeGB) GB dynamic)" 'INFO'
        New-VHD -Path $osDiskPath -SizeBytes ($settings.OSDiskSizeGB * 1GB) -Dynamic | Out-Null
    }

    Write-LogEntry "Creating VM '$($VM.Name)' (Generation 2) on switch '$switchName'..." 'INFO'
    New-VM -Name $VM.Name -Generation 2 -VHDPath $osDiskPath -Path $settings.Root -SwitchName $switchName | Out-Null

    Set-VMProcessor -VMName $VM.Name -Count $settings.vCPU
    Write-LogEntry "vCPUs: $($settings.vCPU)" 'OK'

    Set-VMMemory -VMName $VM.Name -DynamicMemoryEnabled $true `
        -MinimumBytes ([long]$settings.MemMinGB * 1GB) `
        -StartupBytes ([long]$settings.MemStartGB * 1GB) `
        -MaximumBytes ([long]$settings.MemMaxGB * 1GB) `
        -Priority 80
    Write-LogEntry "Dynamic Memory: min $($settings.MemMinGB) GB / startup $($settings.MemStartGB) GB / max $($settings.MemMaxGB) GB" 'OK'

    Set-VMFirmware -VMName $VM.Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
    Write-LogEntry 'Secure Boot: enabled (MicrosoftWindows template)' 'OK'

    Enable-GuestTpm -VM $VM

    $isoPath = $VM.Runtime.ISOPath
    Add-VMDvdDrive -VMName $VM.Name -Path $isoPath
    Write-LogEntry "ISO attached: $isoPath" 'OK'

    if ($UseUnattend) {
        # A second DVD drive: Windows Setup only reads autounattend.xml from
        # removable media. The OS disk is then the only hard disk Setup sees,
        # so the answer file's DiskID 0 always targets it; the SQL data disk
        # and Dev Drive are attached later, in Phase 7.
        Add-VMDvdDrive -VMName $VM.Name -Path $settings.SeedDiskPath
        Write-LogEntry 'Answer-file disc attached' 'OK'
    }

    # The Windows ISO's drive, not the answer-file disc's, is the one to boot.
    $dvd = @(Get-VMDvdDrive -VMName $VM.Name | Where-Object { $_.Path -eq $isoPath })[0]
    $vhd = @(Get-VMHardDiskDrive -VMName $VM.Name | Where-Object { $_.Path -eq $osDiskPath })[0]
    $nic = Get-VMNetworkAdapter -VMName $VM.Name
    Set-VMFirmware -VMName $VM.Name -BootOrder $dvd, $vhd, $nic
    Write-LogEntry 'Boot order: DVD -> VHD -> NIC' 'OK'

    # Integration services, checked after enabling rather than assumed.
    $wanted = 'Guest Service Interface', 'Heartbeat', 'Key-Value Pair Exchange', 'Shutdown', 'Time Synchronization', 'VSS'
    $failed = @()
    foreach ($name in $wanted) {
        try {
            Enable-VMIntegrationService -VMName $VM.Name -Name $name -ErrorAction Stop
            if (-not (Get-VMIntegrationService -VMName $VM.Name -Name $name).Enabled) { $failed += $name }
        }
        catch { $failed += "$name ($($_.Exception.Message))" }
    }
    if ($failed.Count -gt 0) {
        Write-LogEntry "Integration services NOT enabled: $($failed -join ', ')" 'WARN'
        Write-LogEntry '  Copy-VMFile needs Guest Service Interface; Phase 7 will fail without it.' 'WARN'
    }
    else {
        Write-LogEntry "Integration services enabled: $($wanted -join ', ')" 'OK'
    }

    # Automatic checkpoints off, but manual ones kept available, in CheckpointDir.
    Set-VM -VMName $VM.Name -AutomaticCheckpointsEnabled $false
    if (Test-Path -LiteralPath $settings.CheckpointDir) {
        Set-VM -VMName $VM.Name -SnapshotFileLocation $settings.CheckpointDir
    }
    Write-LogEntry "Automatic checkpoints disabled; manual checkpoints -> $($settings.CheckpointDir)" 'OK'

    $note = "LazyVM | Built $(Get-Date -Format 'yyyy-MM-dd') | guest admin: $($VM.Runtime.GuestAdminUser)"
    if ($reusingDisk) { $note += ' | reused existing OS VHDX' }
    Set-VM -VMName $VM.Name -Notes $note

    Write-LogEntry "VM '$($VM.Name)' built" 'OK'
}

function Start-VMFromInstallMedia {
    <#
      Starts a VM that is to boot Windows Setup from the ISO. The ISO's boot
      loader shows "Press any key to boot from CD or DVD..." for a few
      seconds; with no key pressed it falls through to the empty OS disk and
      stops at "No operating system was loaded". An unattended build has
      nobody at the console, so Enter is pressed here, through the VM's
      virtual keyboard, for the first seconds after power-on. A press that
      lands after the prompt has gone does nothing.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [int]$Seconds = 15
    )

    Start-VM -Name $VM.Name | Out-Null

    $presses = @{ Count = 0 }
    # Never "done": this presses Enter for the whole time given.
    $null = Wait-Until -Timeout ([timespan]::FromSeconds($Seconds)) -Interval ([timespan]::FromMilliseconds(500)) -State $presses -NoThrow -Condition {
        param($p)
        # The keyboard appears a moment after power-on, so it is looked up each time.
        try {
            $system = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ComputerSystem' -Filter "ElementName='$($VM.Name)'" -ErrorAction Stop
            $keyboard = Get-CimAssociatedInstance -InputObject $system -ResultClassName 'Msvm_Keyboard' -ErrorAction Stop
            if ($keyboard) {
                $null = Invoke-CimMethod -InputObject $keyboard -MethodName 'TypeKey' -Arguments @{ keyCode = [uint32]0x0D } -ErrorAction Stop
                $p.Count++
            }
        }
        catch {
            Write-Verbose "The VM's keyboard is not ready yet: $($_.Exception.Message)"
        }
        $false
    }

    if ($presses.Count -gt 0) {
        Write-LogEntry "VM started; Enter pressed $($presses.Count) time(s) to boot Windows Setup from the ISO" 'OK'
    }
    else {
        Write-LogEntry 'VM started, but its virtual keyboard could not be reached to boot from the ISO.' 'WARN'
        Write-LogEntry "  If the console shows 'No operating system was loaded', turn the VM off and run" 'INFO'
        Write-LogEntry '  this again with -FromPhase 7, or press a key in the console when it asks.' 'INFO'
    }
}

function Enable-GuestTpm {
    <# A virtual TPM, which Windows 11 Setup requires; checked after enabling. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        $guardian = Get-HgsGuardian -Name 'UntrustedGuardian' -ErrorAction SilentlyContinue
        if (-not $guardian) {
            Write-LogEntry 'Creating HGS guardian for vTPM...' 'INFO'
            $guardian = New-HgsGuardian -Name 'UntrustedGuardian' -GenerateCertificates
        }
        $protector = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot
        Set-VMKeyProtector -VMName $VM.Name -KeyProtector $protector.RawData
        Enable-VMTPM -VMName $VM.Name -ErrorAction Stop

        if ((Get-VMSecurity -VMName $VM.Name).TpmEnabled) {
            Write-LogEntry 'vTPM: enabled' 'OK'
        }
        else {
            Write-LogEntry 'vTPM: Enable-VMTPM reported success but the VM still shows TpmEnabled = False' 'WARN'
        }
    }
    catch {
        Write-LogError 'vTPM could not be enabled' $_
        Write-LogEntry '  Windows 11 Setup requires a TPM. Install will fail without it.' 'WARN'
    }
}
