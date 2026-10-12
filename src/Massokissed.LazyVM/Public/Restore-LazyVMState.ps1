function Restore-LazyVMState {
    <#
    .SYNOPSIS
    Puts a VM's captured state back into it.

    .DESCRIPTION
    Applies the capture Save-LazyVMState made: databases, logins, Visual
    Studio settings, the Windows environment, project folders and
    application settings. A rebuild does this by itself; run it on its own
    to bring a capture into a VM built some other way.

    Starts the VM if it is off.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Restore-LazyVMState -Name DevBox
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [string]$Name
    )

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Restore' -Name $Name
        if (-not $PSCmdlet.ShouldProcess($CFG.VMName, "Apply the capture in $($CFG.StateDir) to the VM")) {
            return
        }
        $restoreOk = @(Restore-GuestState)[-1]
        if ($restoreOk -eq $false) {
            throw "The restore into '$($CFG.VMName)' did not complete. The log says what failed: $($CFG.LogFile)"
        }
    }
    catch {
        if ($script:LogReady) { Write-LogError 'The restore failed' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
