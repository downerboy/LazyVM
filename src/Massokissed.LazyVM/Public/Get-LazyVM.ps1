function Get-LazyVM {
    <#
    .SYNOPSIS
    Lists the VMs LazyVM looks after on this host.

    .DESCRIPTION
    One object per VM profile in the LazyVM folder, with the VM's state in
    Hyper-V, its daily maintenance time and whether the maintenance task is
    registered. A VM whose profile exists but has not been built yet shows
    as 'Not built'. A VM whose settings file has a problem says so in
    Settings, rather than being left out.

    .PARAMETER Name
    The VM or VMs to list. Wildcards are allowed. All of them by default.

    .EXAMPLE
    Get-LazyVM

    .EXAMPLE
    Get-LazyVM -Name Dev* | Format-List

    .OUTPUTS
    LazyVM.VM
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.VM')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name = '*'
    )

    $root = (Resolve-LazyVMRoot).Path
    $configDir = Get-ConfigDir -Root $root
    $hyperV = [bool](Get-Command -Name Get-VM -ErrorAction SilentlyContinue)
    $scheduledTasks = [bool](Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)

    foreach ($vmName in @(Get-VMProfileName -ConfigDir $configDir | Where-Object { $_ -like $Name })) {
        $state = 'Not built'
        if ($hyperV) {
            $lookupErrors = $null
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue -ErrorVariable lookupErrors
            if ($vm) {
                $state = "$($vm.State)"
            }
            elseif (@($lookupErrors | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' }).Count -gt 0) {
                # Not "missing" but unreadable, usually for want of Hyper-V rights.
                $state = 'Unknown'
            }
        }

        $maintenanceTime = $null
        $settingsStatus = 'OK'
        try {
            $maintenanceTime = (Read-VMSetting -Root $root -VMName $vmName).Settings.MaintenanceTime
        }
        catch {
            $settingsStatus = $_.Exception.Message
        }

        $task = $null
        if ($scheduledTasks) { $task = Get-ScheduledTask -TaskName "LazyVM-Maintain-$vmName" -ErrorAction SilentlyContinue }

        [pscustomobject]@{
            PSTypeName      = 'LazyVM.VM'
            Name            = $vmName
            State           = $state
            MaintenanceTime = $maintenanceTime
            MaintenanceTask = $(if ($task) { 'Registered' } else { 'Not registered' })
            Settings        = $settingsStatus
            ProfilePath     = Get-VMProfilePath -ConfigDir $configDir -Name $vmName
        }
    }
}
