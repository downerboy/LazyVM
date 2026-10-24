function Get-LazyVMLicense {
    <#
    .SYNOPSIS
    Shows how long a VM's Windows evaluation has left.

    .DESCRIPTION
    Reads the Windows 11 Enterprise evaluation license from inside the VM:
    days left, rearms left, and what the daily maintenance will do about it.
    Each rearm gives another 90 days for the price of a restart; only when
    none are left does maintenance rebuild the VM. Also shows when the VM's
    state was last captured.

    Starts the VM if it is off.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Get-LazyVMLicense -Name DevBox

    .OUTPUTS
    LazyVM.License
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.License')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'License' -Name $Name -FailureMessage 'Reading the license failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            Get-LicenseReport -VM $VM
        }
    }
}
