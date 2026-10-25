function Invoke-LazyVMMaintenance {
    <#
    .SYNOPSIS
    Runs a VM's daily maintenance: the scheduled task's command.

    .DESCRIPTION
    Records any tooling change in the VM (see Save-LazyVMTooling), then
    checks the Windows evaluation. Until it is within RebuildThresholdDays of
    expiring, nothing more happens. Then the VM's state is captured and
    Windows rearmed, which gives another 90 days for the price of a restart.
    Only when no rearms are left is the VM rebuilt (see
    Invoke-LazyVMRebuild). A VM that does not exist yet is built.

    Register-LazyVMMaintenance schedules this to run daily, unattended. If a
    settings file has a problem when it runs, the copy from the last time
    the file loaded cleanly is used and the problem is written to the log,
    so maintenance is never stopped by a typo.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Invoke-LazyVMMaintenance -Name DevBox

    .OUTPUTS
    System.String: what was done - None, Rearmed, Rebuilt or Built.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Maintenance' -Name $Name -FailureMessage 'Maintenance stopped' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            Sync-VMProfile -VM $VM
            $step = [MaintenanceStep]@(Invoke-Maintenance -VM $VM)[-1]
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
                    if (@(Invoke-Rebuild -VM $VM -SkipCapture)[-1] -ne $true) {
                        throw "The rebuild of '$($VM.Name)' did not complete cleanly. The log says what happened and how to go back: $($VM.Settings.LogFile)"
                    }
                    return 'Rebuilt'
                }
                ([MaintenanceStep]::Build) {
                    Write-LogEntry 'Maintenance found no VM - building one' 'INFO'
                    if (@(Invoke-Rebuild -VM $VM)[-1] -ne $true) {
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
