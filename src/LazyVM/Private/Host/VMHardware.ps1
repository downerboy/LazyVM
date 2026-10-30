# VMHardware.ps1 - Keeps VM.json true to the VM's hardware as set in Hyper-V.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A change made to the VM directly (more processors or memory, a bigger
# disk, another switch) is recorded in VM.json before maintenance or a
# rebuild uses the settings, so a rebuild makes the VM as it actually is.
# Only configured values are read, never what Hyper-V changes on its own,
# such as the memory dynamic memory has assigned right now.

# Each disk size setting, with the setting that says where that disk is.
$script:HardwareDiskSettings = [ordered]@{
    OSDiskSizeGB   = 'OSDiskPath'
    SQLDiskSizeGB  = 'SQLDiskPath'
    DevDriveSizeGB = 'DevDrivePath'
    UserDiskSizeGB = 'UserDiskPath'
}

function Get-VMHardware {
    <#
      What Hyper-V says the VM is configured with: its processor count,
      memory in bytes, the switches its network adapters are on and the size
      in bytes of each of its disks that exists. $null when the VM does not
      exist.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $hyperVM = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if (-not $hyperVM) { return $null }

    $memory = Get-VMMemory -VM $hyperVM
    $diskBytes = @{}
    foreach ($setting in $script:HardwareDiskSettings.Keys) {
        $path = $VM.Settings[$script:HardwareDiskSettings[$setting]]
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $diskBytes[$setting] = (Get-VHD -Path $path).Size
        }
    }
    return [pscustomobject]@{
        ProcessorCount       = (Get-VMProcessor -VM $hyperVM).Count
        DynamicMemoryEnabled = $memory.DynamicMemoryEnabled
        StartupBytes         = $memory.Startup
        MinimumBytes         = $memory.Minimum
        MaximumBytes         = $memory.Maximum
        SwitchNames          = @(Get-VMNetworkAdapter -VM $hyperVM | ForEach-Object { $_.SwitchName })
        DiskBytes            = $diskBytes
    }
}

function Get-HardwareChange {
    <#
      Each setting whose value in Hyper-V ($Hardware, from Get-VMHardware)
      differs from $Settings: its name, old and new value, and whether it can
      be recorded. Sizes are in GB; one that is not a whole number of GB
      cannot be, because VM.json holds whole GB. Minimum and maximum memory
      count only while dynamic memory is on. The switch counts only when the
      VM has one network adapter, on a switch that is neither SwitchName nor
      the NAT switch LazyVM falls back to.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][object]$Hardware
    )

    $reported = [ordered]@{ vCPU = $Hardware.ProcessorCount }
    $bytes = [ordered]@{ MemStartGB = $Hardware.StartupBytes }
    if ($Hardware.DynamicMemoryEnabled) {
        $bytes.MemMinGB = $Hardware.MinimumBytes
        $bytes.MemMaxGB = $Hardware.MaximumBytes
    }
    foreach ($setting in $script:HardwareDiskSettings.Keys) {
        if ($Hardware.DiskBytes.ContainsKey($setting)) { $bytes[$setting] = $Hardware.DiskBytes[$setting] }
    }

    foreach ($setting in $reported.Keys) {
        if ($Settings[$setting] -ne $reported[$setting]) {
            [pscustomobject]@{ Setting = $setting; Old = $Settings[$setting]; New = $reported[$setting]; Recordable = $true }
        }
    }
    foreach ($setting in $bytes.Keys) {
        $whole = $bytes[$setting] % 1GB -eq 0
        $gb = if ($whole) { [long]($bytes[$setting] / 1GB) } else { $bytes[$setting] / 1GB }
        if ($Settings[$setting] -ne $gb) {
            [pscustomobject]@{ Setting = $setting; Old = $Settings[$setting]; New = $gb; Recordable = $whole }
        }
    }

    $switches = @($Hardware.SwitchNames | Where-Object { $_ })
    if ($switches.Count -eq 1 -and $switches[0] -notin @($Settings.SwitchName, $Settings.NatSwitchName)) {
        [pscustomobject]@{ Setting = 'SwitchName'; Old = $Settings.SwitchName; New = $switches[0]; Recordable = $true }
    }
}

function Save-VMHardware {
    <#
      Records in VM.json each hardware setting changed in Hyper-V, logging
      its old and new value. Returns whether VM.json changed. Never fails: a
      value the schema refuses, or Hyper-V not answering, is logged and
      VM.json is left as it was.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        $hardware = Get-VMHardware -VM $VM
        if (-not $hardware) { return $false }
        $changes = @(Get-HardwareChange -Settings $VM.Settings -Hardware $hardware)
        if ($changes.Count -eq 0) { return $false }

        Write-LogEntry 'Hardware changed in Hyper-V:' 'INFO'
        $record = @{}
        foreach ($change in $changes) {
            if ($change.Recordable) {
                Write-LogEntry "  $($change.Setting): $($change.Old) -> $($change.New)" 'INFO'
                $record[$change.Setting] = $change.New
            }
            else {
                Write-LogEntry "  $($change.Setting): $($change.Old) -> $($change.New) - not recorded: VM.json holds whole GB" 'WARN'
            }
        }
        if ($record.Count -eq 0) { return $false }
        return @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $record -Reason 'hardware changed in Hyper-V').Count -gt 0
    }
    catch {
        Write-LogError 'The hardware change was not recorded (non-fatal)' $_
        return $false
    }
}
