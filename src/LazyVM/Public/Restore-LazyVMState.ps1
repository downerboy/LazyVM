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
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Restore' -Name $Name -FailureMessage 'The restore failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            if (-not $PSCmdlet.ShouldProcess($VM.Name, "Apply the capture in $($VM.Settings.StateDir) to the VM")) {
                return
            }
            $restored = Restore-GuestState -VM $VM
            Restore-GuestVisualStudioSetting -VM $VM
            if ($restored -eq $false) {
                throw "The restore into '$($VM.Name)' did not complete. The log says what failed: $($VM.Settings.LogFile)"
            }
        }
    }
}
