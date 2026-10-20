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
        Assert-Administrator
        try {
            $null = Initialize-CommandRun -Title 'Maintenance' -Name $Name

            $action = @(Invoke-Maintenance)[-1]
            switch ($action) {
                'none' {
                    Write-LogEntry 'Maintenance complete - nothing needed' 'OK'
                    return 'None'
                }
                'rearmed' {
                    Write-LogEntry 'Maintenance complete - evaluation rearmed, no rebuild needed' 'OK'
                    return 'Rearmed'
                }
                'rebuild' {
                    Write-LogEntry 'Maintenance is escalating to a full rebuild' 'WARN'
                    # The capture already ran inside Invoke-Maintenance.
                    if (@(Invoke-Rebuild -SkipCapture)[-1] -ne $true) {
                        throw "The rebuild of '$($CFG.VMName)' did not complete cleanly. The log says what happened and how to go back: $($CFG.LogFile)"
                    }
                    return 'Rebuilt'
                }
                'build' {
                    Write-LogEntry 'Maintenance found no VM - building one' 'INFO'
                    if (@(Invoke-Rebuild)[-1] -ne $true) {
                        throw "Building '$($CFG.VMName)' did not complete cleanly. The log says what happened: $($CFG.LogFile)"
                    }
                    return 'Built'
                }
                default {
                    throw "Maintenance of '$($CFG.VMName)' could not run. The log says why: $($CFG.LogFile)"
                }
            }
        }
        catch {
            if ($script:LogReady) { Write-LogError 'Maintenance stopped' $_ }
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            Complete-CommandRun
        }
    }
}
