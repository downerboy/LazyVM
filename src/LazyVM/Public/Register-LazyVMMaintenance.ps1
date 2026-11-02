function Register-LazyVMMaintenance {
    <#
    .SYNOPSIS
    Schedules a VM's daily maintenance.

    .DESCRIPTION
    Registers a scheduled task that runs Invoke-LazyVMMaintenance for the VM
    every day at its MaintenanceTime, as you, elevated, whether or not you
    are signed in. It wakes the host if needed and catches up if the host
    was off. Running this again replaces the task, for example after
    changing MaintenanceTime.

    Task Scheduler needs your Windows password to run the task while you
    are signed out: you are asked for it once per PowerShell session, and
    Task Scheduler, not LazyVM, keeps it. Use your account's password, not
    your PIN. After you change your password the task cannot start; every
    LazyVM command then warns, and running this again with the new
    password fixes it.

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
