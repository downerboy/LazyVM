function Start-LazyVMMaintenance {
    <#
    .SYNOPSIS
    Runs a VM's maintenance now, as its nightly run does.

    .DESCRIPTION
    Starts the VM's daily maintenance task in Task Scheduler and returns at
    once, so maintenance runs exactly as it does each night: as SYSTEM, with
    the task's own time limit and settings. Get-LazyVMDashboard shows it in
    Run while it runs, and its log says how it went.

    Nothing is started while a build, maintenance or rebuild of the VM is
    running, or while the task is running already, or when maintenance is
    not scheduled: Register-LazyVMMaintenance schedules it.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Start-LazyVMMaintenance -Name DevBox

    .OUTPUTS
    LazyVM.MaintenanceStart: the VM's name, the task started and when.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('LazyVM.MaintenanceStart')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $root = (Resolve-LazyVMRoot).Path
        $settings = (Read-VMSetting -Root $root -VMName $Name -ReadOnly).Settings
        $vmName = $settings.VMName
        $taskName = $settings.ScheduleTaskName

        # The task would start, find the run lock taken and record a failed maintenance: refuse here instead.
        $run = Get-VMRunState -Settings $settings
        if ($run -and $run.Status -eq 'Running') {
            $what = switch ($run.Command) {
                'Build' { 'A build' }
                'Rebuild' { 'A rebuild' }
                'Maintenance' { 'Maintenance' }
                default { 'A run' }
            }
            $message = "$what of $vmName is running, so maintenance was not started. Run it again once that has ended."
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message), 'LazyVM.RunBusy', [System.Management.Automation.ErrorCategory]::ResourceBusy, $vmName))
            return
        }

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            $message = "The maintenance of $vmName is not scheduled, so there is no task to start. Schedule it with: Register-LazyVMMaintenance -Name $vmName"
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message), 'LazyVM.MaintenanceNotScheduled', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $vmName))
            return
        }
        if ("$($task.State)" -eq 'Running') {
            $message = "The maintenance of $vmName is running already, so it was not started again."
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message), 'LazyVM.RunBusy', [System.Management.Automation.ErrorCategory]::ResourceBusy, $vmName))
            return
        }

        if (-not $PSCmdlet.ShouldProcess($taskName, "Run the maintenance of $vmName now, as its nightly run does")) { return }
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        [pscustomobject]@{
            PSTypeName = 'LazyVM.MaintenanceStart'
            Name       = $vmName
            TaskName   = $taskName
            Started    = Get-Date
        }
    }
}
