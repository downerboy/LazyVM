function Save-LazyVMState {
    <#
    .SYNOPSIS
    Captures a VM's state to the host, ready for a rebuild.

    .DESCRIPTION
    Copies what a rebuild would otherwise lose to the VM's State folder on
    the host: SQL Server databases (as backups), logins and settings, Visual
    Studio settings, the Windows environment (variables, certificates,
    firewall rules, scheduled tasks), project folders listed in
    GuestProjectPaths, and application settings listed in AppSettings.

    The daily maintenance captures automatically before a rearm or rebuild.
    The Dev Drive needs no capture: it is never deleted by a rebuild.

    Starts the VM if it is off.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Save-LazyVMState -Name DevBox
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [string]$Name
    )

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Capture' -Name $Name
        if ($PSCmdlet.ShouldProcess($CFG.VMName, "Capture the VM's state to $($CFG.StateDir)")) {
            $null = Save-GuestState
        }
    }
    catch {
        if ($script:LogReady) { Write-LogError 'The capture failed' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
