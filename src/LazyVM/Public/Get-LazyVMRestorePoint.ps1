function Get-LazyVMRestorePoint {
    <#
    .SYNOPSIS
    Lists the tooling versions a VM can be returned to.

    .DESCRIPTION
    Each time a tooling change is recorded, a Hyper-V checkpoint of the VM is
    taken first. These are the ones that still exist, oldest first. Return to
    one with Restore-LazyVMTooling.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Get-LazyVMRestorePoint -Name DevBox

    .OUTPUTS
    LazyVM.RestorePoint
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.RestorePoint')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Restore points' -Name $Name -FailureMessage 'Listing the restore points failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            Get-ToolingRestorePoint -VM $VM
        }
    }
}
