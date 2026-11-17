function Stop-LazyVMBuild {
    <#
    .SYNOPSIS
    Asks a running build of a VM to stop.

    .DESCRIPTION
    Asks the build of the VM that is running now, by hand or as the resume
    task after a host restart, to stop, and returns at once. The build stops
    at its next safe point: before the next phase, before the next step, or
    while it waits for the VM or for work in the guest to finish. Work
    already started inside the guest, such as an install, is not
    interrupted: it carries on by itself.

    As it stops, the build cleans up as it does when it fails: the
    answer-file disc, which holds the guest password, is removed, and the
    resume task is removed so the build does not start again by itself.
    Build-LazyVM then ends with the error LazyVM.RunStopped, and
    Get-LazyVMDashboard shows the build as Stopped, with the phase it was
    in as UnfinishedPhase: run Build-LazyVM -FromPhase with that number to
    carry on, once an install still running in the VM has finished, so two
    installers do not run at once.

    Only a build is stopped. While maintenance or a rebuild is running, this
    says so and changes nothing. Nothing is written when no build is
    running.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Stop-LazyVMBuild -Name DevBox

    .OUTPUTS
    LazyVM.VMRun: the running build, with StopRequested true, as
    Get-LazyVMDashboard shows it in Run.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('LazyVM.VMRun')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        $root = (Resolve-LazyVMRoot).Path
        $settings = (Read-VMSetting -Root $root -VMName $Name -ReadOnly).Settings
        $vmName = $settings.VMName
        $run = Get-VMRunState -Settings $settings
        if (-not $run -or $run.Status -ne 'Running') {
            Write-Warning "No build of $vmName is running, so there is nothing to stop."
            return
        }
        if ($run.Command -and $run.Command -ne 'Build') {
            $what = if ($run.Command -eq 'Rebuild') { 'A rebuild' } else { $run.Command }
            $message = "$what of $vmName is running, not a build, so nothing was stopped. Stop-LazyVMBuild stops only a build."
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message), 'LazyVM.NotABuild', [System.Management.Automation.ErrorCategory]::InvalidOperation, $vmName))
            return
        }
        if (-not $run.ProcessId -or -not $run.Started) {
            $message = "A run of $vmName is just starting and has not recorded itself yet, so nothing was stopped. Try again in a moment."
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message), 'LazyVM.RunStarting', [System.Management.Automation.ErrorCategory]::ResourceBusy, $vmName))
            return
        }
        if ($run.StopRequested) { return $run }

        if (-not $PSCmdlet.ShouldProcess($vmName, "Stop the build running in process $($run.ProcessId), at its next safe point")) { return }
        Request-VMRunStop -Settings $settings -Run $run
        Get-VMRunState -Settings $settings
    }
}
