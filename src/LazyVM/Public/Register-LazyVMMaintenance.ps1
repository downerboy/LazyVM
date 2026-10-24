function Register-LazyVMMaintenance {
    <#
    .SYNOPSIS
    Schedules a VM's daily maintenance.

    .DESCRIPTION
    Registers a scheduled task that runs Invoke-LazyVMMaintenance for the VM
    every day at its MaintenanceTime, as SYSTEM, whether or not anyone is
    signed in. It wakes the host if needed and catches up if the host was
    off. Running this again replaces the task, for example after changing
    MaintenanceTime.

    A guest credential must be stored first: Build-LazyVM stores one, or use
    Set-LazyVMCredential.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Register-LazyVMMaintenance -Name DevBox
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Schedule maintenance' -Name $Name -FailureMessage 'Scheduling maintenance failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            if ($PSCmdlet.ShouldProcess($VM.Settings.ScheduleTaskName, "Run maintenance of $($VM.Name) daily at $($VM.Settings.MaintenanceTime)")) {
                Register-RebuildSchedule -VM $VM
            }
        }
    }
}
