function Save-LazyVMState {
    <#
    .SYNOPSIS
    Captures a VM's state to the host, ready for a rebuild.

    .DESCRIPTION
    Copies what a rebuild would otherwise lose to the VM's State folder on
    the host: SQL Server databases (as backups), logins and settings, Visual
    Studio settings, the Windows environment (variables, certificates,
    firewall rules, scheduled tasks), and application settings listed in
    AppSettings.

    The daily maintenance captures automatically before a rearm or rebuild.
    The Dev Drive and the User disk, which holds Documents, Desktop,
    Downloads, .ssh and source\repos, need no capture: a rebuild never
    deletes them.

    Starts the VM if it is off.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Save-LazyVMState -Name DevBox
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Capture' -Name $Name -FailureMessage 'The capture failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            if ($PSCmdlet.ShouldProcess($VM.Name, "Capture the VM's state to $($VM.Settings.StateDir)")) {
                $null = Save-GuestState -VM $VM
            }
        }
    }
}
