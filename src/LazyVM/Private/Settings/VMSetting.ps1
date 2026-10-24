# VMSetting.ps1 - One VM's settings, in layers, with every path and name worked out.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# Settings that name a file or folder on the HOST, and so are resolved against
# the root folder. Paths inside the guest (GuestSetupDir, GuestProjectPaths,
# ...) are deliberately absent: they are not host paths.
$script:HostPathSettings = @(
    'DiskDir'
    'ISOPath'
    'ISOSearchRoot'
    'SQLIsoPath'
    'SQLDiskPath'
    'DevDrivePath'
    'CheckpointDir'
    'VSSettingsBackup'
    'LogFile'
    'CredStoreDir'
    'StateDir'
)

function Resolve-HostPathSetting {
    <# Joins every relative host path to the root. Updates $Settings in place. #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $script:HostPathSettings) {
        $value = [string]$Settings[$name]

        if (Test-FullHostPath $value) {
            continue
        }
        if (-not $value -or $value -match '^[A-Za-z]:' -or $value.StartsWith('\')) {
            $problems.Add("'$name' must be a path inside the LazyVM folder (like 'Shared\ISO') or a full path (like 'E:\VMs'), not '$value'.")
            continue
        }

        $relative = $value -replace '^\.\\', ''
        $Settings[$name] = "$Root\$relative"
    }

    if ($problems.Count -gt 0) {
        throw (Format-ProblemList -Heading '{0} path setting(s) cannot be used:' -Problems $problems)
    }
}

function Add-DerivedSetting {
    <#
      Values worked out from the settings rather than set by the user: file
      and folder names, task and registry names, and the credential files.
      Runs after the host paths are resolved. Everything that needs one of
      these reads it from here rather than building it again.
    #>
    param([Parameter(Mandatory)][hashtable]$Settings)

    $vm = $Settings.VMName
    $vmRoot = Get-VMRoot -Root $Settings.Root -Name $vm
    $diskDir = "$($Settings.DiskDir)".TrimEnd('\')
    $Settings.VMRoot = $vmRoot
    $Settings.OSDiskPath = "$diskDir\$vm-OS.vhdx"
    $Settings.SeedDiskPath = "$diskDir\$vm-Seed.iso"
    # New-VM -Path <Root> makes <Root>\<Name>\Virtual Machines for the
    # VM's configuration, inside the VM's own folder.
    $Settings.VMConfigDir = "$vmRoot\Virtual Machines"
    $Settings.CredKeyFile = "$($Settings.CredStoreDir)\.lazyvm.key"
    $Settings.GuestCredFile = "$vmRoot\Credentials\guest.cred"
    $Settings.CertCredFile = "$vmRoot\Credentials\certs.cred"
    $Settings.ResumeRegKey = "$script:RootRegistryKey\$vm"
    $Settings.ResumeTaskName = "${script:TaskPrefix}ResumeAfterReboot-$vm"
    $Settings.ScheduleTaskName = Get-MaintenanceTaskName -VMName $vm
}

function Get-MaintenanceTaskName {
    <# The name of a VM's daily maintenance task. #>
    param([Parameter(Mandatory)][string]$VMName)

    return "${script:TaskPrefix}Maintain-$VMName"
}

function Expand-VMToken {
    <# Replaces {VM} in every text setting with the VM's name. Updates $Settings in place. #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$VMName
    )

    foreach ($name in @($Settings.Keys)) {
        $value = $Settings[$name]
        if ($value -is [string] -and $value.Contains('{VM}')) {
            $Settings[$name] = $value.Replace('{VM}', $VMName)
        }
    }
}

function Read-VMSetting {
    <#
      Reads the settings for one VM, in layers: the defaults, then the
      host-wide settings file, then the VM's own profile. Then names
      everything after the VM, resolves every host path against the root and
      adds the derived values. Returns them with where each value came from.
      Nothing is shared between calls, so several VMs can be read at once.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$VMName,
        [switch]$Unattended
    )

    $configDir = Get-ConfigDir -Root $Root
    $settings = Get-DefaultSetting
    $sources = @{}
    foreach ($key in $settings.Keys) { $sources[$key] = 'Default' }
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Each layer overrides the one before, and records where its values came from.
    $applyLayer = {
        param([string]$Path, [string]$Source, [bool]$Unattended)
        $loaded = Import-SettingsFile -Path $Path -Unattended:$Unattended
        if ($loaded.Warning) { $warnings.Add($loaded.Warning) }
        foreach ($key in $loaded.Values.Keys) {
            $settings[$key] = $loaded.Values[$key]
            $sources[$key] = $Source
        }
        return @($loaded.Values.Keys | Sort-Object)
    }

    $hostFile = Join-Path -Path $configDir -ChildPath $script:SettingsFileName
    $changedKeys = @()
    if (Test-Path -LiteralPath $hostFile -PathType Leaf) {
        $changedKeys = @(& $applyLayer $hostFile $script:SettingsFileName $Unattended.IsPresent)
    }

    $vm = Resolve-VMSelection -Root $Root -Requested $VMName
    $profilePath = Get-VMProfilePath -Root $Root -Name $vm
    $profileKeys = @(& $applyLayer $profilePath "$vm\$script:ConfigFolderName\$script:ProfileFileName" $Unattended.IsPresent)

    $settings.VMName = $vm
    $settings.Root = $Root
    $settings.ConfigDir = $configDir
    $settings.ProfileDir = Split-Path -Path $profilePath -Parent
    Expand-VMToken -Settings $settings -VMName $vm
    Resolve-HostPathSetting -Settings $settings -Root $Root
    Add-DerivedSetting -Settings $settings

    return [pscustomobject]@{
        Settings    = $settings
        Sources     = $sources
        HostFile    = $hostFile
        ChangedKeys = $changedKeys
        VMName      = $vm
        ProfilePath = $profilePath
        ProfileKeys = $profileKeys
        Root        = $Root
        Warnings    = @($warnings)
    }
}
