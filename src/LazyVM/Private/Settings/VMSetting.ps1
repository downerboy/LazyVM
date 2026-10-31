# VMSetting.ps1 - One VM's settings, with every path and name worked out.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# Settings that name a file or folder on the HOST, and so are resolved against
# the root folder. Paths inside the guest (GuestSetupDir, ...) are
# deliberately absent: they are not host paths.
$script:HostPathSettings = @(
    'DiskDir'
    'ISOPath'
    'ISOSearchRoot'
    'SQLIsoPath'
    'SQLDiskPath'
    'DevDrivePath'
    'UserDiskPath'
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
    $Settings.EnvironmentCredFile = "$vmRoot\Credentials\environment.cred"
    $Settings.AppSettingsCredFile = "$vmRoot\Credentials\appsettings.cred"
    $Settings.BitLockerCredFile = "$vmRoot\Credentials\bitlocker.cred"
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
      Reads the settings for one VM. Its VM.json holds every setting; any it
      lacks (a profile made before VM.json held every setting, or a setting
      added by a newer LazyVM) come from the shared template until
      Sync-VMProfile writes them in. Then names everything after the VM,
      resolves every host path against the root and adds the derived values.
      Returns them with where each value came from. Writes nothing but the
      settings files' last-good copies (none with -ReadOnly), and nothing is
      shared between calls, so several VMs can be read at once.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$VMName,
        [switch]$Unattended,
        [switch]$ReadOnly
    )

    $configDir = Get-ConfigDir -Root $Root
    $template = Get-SharedTemplateSetting -Root $Root -Unattended:$Unattended -ReadOnly:$ReadOnly
    $settings = $template.Values
    $sources = $template.Sources
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($template.Warning) { $warnings.Add($template.Warning) }

    $vm = Resolve-VMSelection -Root $Root -Requested $VMName
    $profilePath = Get-VMProfilePath -Root $Root -Name $vm
    $loaded = Import-SettingsFile -Path $profilePath -Unattended:$Unattended -ReadOnly:$ReadOnly
    if ($loaded.Warning) { $warnings.Add($loaded.Warning) }
    $profileSource = "$vm\$script:ConfigFolderName\$script:ProfileFileName"
    foreach ($key in $loaded.Values.Keys) {
        $settings[$key] = $loaded.Values[$key]
        $sources[$key] = $profileSource
    }
    $missingKeys = @($settings.Keys | Where-Object { -not $loaded.Values.Contains($_) } | Sort-Object)

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
        HostFile    = $template.HostFile
        MissingKeys = $missingKeys
        VMName      = $vm
        ProfilePath = $profilePath
        Root        = $Root
        Warnings    = @($warnings)
    }
}
