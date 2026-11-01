function Invoke-LazyVMMaintenance {
    <#
    .SYNOPSIS
    Runs a VM's daily maintenance: the scheduled task's command.

    .DESCRIPTION
    Records in VM.json any hardware change made to the VM in Hyper-V. Then,
    in the VM: extends C: into new space, sees to the User disk and
    BitLocker, copies the User disk when it changed, records any tooling
    change (see Save-LazyVMTooling) and the environment, firewall rules,
    scheduled tasks, SQL logins and application settings, checks and backs
    up the databases, asks the Store to update its apps, keeps Sysmon set
    up, applies the Visual Studio settings if a build could not, upgrades
    the winget packages and installs Windows updates. A step that fails is
    logged and the rest still run.

    Then it checks the Windows evaluation. Until it is within
    RebuildThresholdDays of expiring, nothing more happens, except a
    capture when the certificates or Visual Studio settings changed. Then the VM's state is captured and
    Windows rearmed, which gives another 90 days for the price of a restart.
    Only when no rearms are left is the VM rebuilt (see
    Invoke-LazyVMRebuild). A VM that does not exist yet is built.

    Register-LazyVMMaintenance schedules this to run daily, unattended. If a
    settings file has a problem when it runs, the copy from the last time
    the file loaded cleanly is used and the problem is written to the log,
    so maintenance is never stopped by a typo.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    With -WhatIf, says what a run would do without doing any of it: build
    the VM, rearm, rebuild, or only the daily checks. It reads the VM's
    evaluation while the VM is running, and starts nothing.

    .EXAMPLE
    Invoke-LazyVMMaintenance -Name DevBox

    .EXAMPLE
    Invoke-LazyVMMaintenance -Name DevBox -WhatIf

    Says whether tonight's run would rearm or rebuild DevBox, changing nothing.

    .OUTPUTS
    System.String: what was done - None, Rearmed, Rebuilt or Built.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        # -WhatIf reads, but records nothing: not even a hardware change in VM.json.
        Invoke-CommandRun -Title 'Maintenance' -Name $Name -FailureMessage 'Maintenance stopped' -Cmdlet $PSCmdlet -RecordHardware:(-not $WhatIfPreference) -ScriptBlock {
            param($VM)
            if ($WhatIfPreference) {
                $null = $PSCmdlet.ShouldProcess($VM.Name, (Get-MaintenancePreview -VM $VM))
                return
            }
            if (-not $PSCmdlet.ShouldProcess($VM.Name, 'Run the daily maintenance')) { return }
            Sync-VMProfile -VM $VM
            $step = [MaintenanceStep](Invoke-Maintenance -VM $VM)
            switch ($step) {
                ([MaintenanceStep]::None) {
                    Write-LogEntry 'Maintenance complete - nothing needed' 'OK'
                    return 'None'
                }
                ([MaintenanceStep]::Rearmed) {
                    Write-LogEntry 'Maintenance complete - evaluation rearmed, no rebuild needed' 'OK'
                    return 'Rearmed'
                }
                ([MaintenanceStep]::Rebuild) {
                    Write-LogEntry 'Maintenance is escalating to a full rebuild' 'WARN'
                    # The capture already ran inside Invoke-Maintenance.
                    if ((Invoke-Rebuild -VM $VM -SkipCapture) -ne $true) {
                        throw "The rebuild of '$($VM.Name)' did not complete cleanly. The log says what happened and how to go back: $($VM.Settings.LogFile)"
                    }
                    return 'Rebuilt'
                }
                ([MaintenanceStep]::Build) {
                    Write-LogEntry 'Maintenance found no VM - building one' 'INFO'
                    if ((Invoke-Rebuild -VM $VM) -ne $true) {
                        throw "Building '$($VM.Name)' did not complete cleanly. The log says what happened: $($VM.Settings.LogFile)"
                    }
                    return 'Built'
                }
                default {
                    throw "Maintenance of '$($VM.Name)' could not run. The log says why: $($VM.Settings.LogFile)"
                }
            }
        }
    }
}
