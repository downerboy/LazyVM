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
    up and the event logs and audit policy at LazyVM's settings, applies the Visual Studio settings if a build could not, upgrades
    the winget packages and installs Windows updates. A step that fails is
    logged and the rest still run.

    Then it checks the Windows evaluation. Until it is within
    RebuildThresholdDays of expiring, nothing more happens, except a
    capture when the certificates or Visual Studio settings changed. Then the VM's state is captured and
    Windows rearmed, which gives another 90 days for the price of a restart.
    Only when no rearms are left is the VM rebuilt (see
    Invoke-LazyVMRebuild). A VM whose build is still in progress - one
    waiting to carry on after a host restart, or not there yet - is left
    alone that night, so maintenance never starts a second build.

    Register-LazyVMMaintenance schedules this to run daily, unattended. If a
    settings file has a problem when it runs, the copy from the last time
    the file loaded cleanly is used and the problem is written to the log,
    so maintenance is never stopped by a typo.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    With -WhatIf, says what a run would do without doing any of it: nothing
    while the build is still in progress, rearm, rebuild, or only the daily
    checks. It reads the VM's
    evaluation while the VM is running, and starts nothing.

    .PARAMETER Root
    The LazyVM folder, instead of the one recorded for you. LazyVM's
    scheduled tasks pass it, since they run as SYSTEM, which cannot read
    your registry. It must be a LazyVM folder locked to its owner and
    SYSTEM (see Set-LazyVMRoot).

    .PARAMETER OwnerSid
    The security identifier of the user the LazyVM folder belongs to, with
    -Root. LazyVM's scheduled tasks pass it; the folder must be locked to
    that user and SYSTEM. The account running the command if left out.

    .EXAMPLE
    Invoke-LazyVMMaintenance -Name DevBox

    .EXAMPLE
    Invoke-LazyVMMaintenance -Name DevBox -WhatIf

    Says whether tonight's run would rearm or rebuild DevBox, changing nothing.

    .OUTPUTS
    System.String: what was done - None, Rearmed or Rebuilt.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [string]$Root,

        [ValidatePattern('^S-1-\d+(-\d+)+$')]
        [string]$OwnerSid
    )

    process {
        # -WhatIf reads, but records nothing: not even a hardware change in VM.json.
        Invoke-CommandRun -Title 'Maintenance' -Name $Name -Root $Root -OwnerSid $OwnerSid -FailureMessage 'Maintenance stopped' -Cmdlet $PSCmdlet -RecordHardware:(-not $WhatIfPreference) -ScriptBlock {
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
                default {
                    throw "Maintenance of '$($VM.Name)' could not run. The log says why: $($VM.Settings.LogFile)"
                }
            }
        }
    }
}
