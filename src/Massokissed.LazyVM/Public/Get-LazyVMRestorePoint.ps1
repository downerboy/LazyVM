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
        [Parameter(Position = 0)]
        [string]$Name
    )

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Restore points' -Name $Name
        Get-ToolingRestorePoint
    }
    catch {
        if ($script:LogReady) { Write-LogError 'Listing the restore points failed' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
