function Get-LazyVMTooling {
    <#
    .SYNOPSIS
    Shows what is installed in a VM, and what the next maintenance run would record.

    .DESCRIPTION
    Takes an inventory inside the VM without changing anything: every Visual
    Studio Installer product (Visual Studio, SSMS) with its workloads and
    extensions, winget packages, and every other program Windows lists.

    PendingChanges lists what differs from the VM's recorded tooling list:
    what the next maintenance run, or Save-LazyVMTooling, would adopt.
    UnmatchedExtensions lists extensions a rebuild cannot reinstall by
    itself, because they are not in the Visual Studio Marketplace.

    The raw inventory is also saved under the VM's State folder.

    Starts the VM if it is off.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Get-LazyVMTooling -Name DevBox

    .EXAMPLE
    (Get-LazyVMTooling -Name DevBox).PendingChanges

    .OUTPUTS
    LazyVM.Tooling
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.Tooling')]
    param(
        [Parameter(Position = 0)]
        [string]$Name
    )

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Tooling inventory' -Name $Name
        Get-GuestToolingReport
    }
    catch {
        if ($script:LogReady) { Write-LogError 'The tooling inventory failed' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
