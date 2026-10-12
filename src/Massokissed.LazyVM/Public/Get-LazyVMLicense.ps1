function Get-LazyVMLicense {
    <#
    .SYNOPSIS
    Shows how long a VM's Windows evaluation has left.

    .DESCRIPTION
    Reads the Windows 11 Enterprise evaluation licence from inside the VM:
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
        [Parameter(Position = 0)]
        [string]$Name
    )

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Licence' -Name $Name
        Get-LicenseReport
    }
    catch {
        if ($script:LogReady) { Write-LogError 'Reading the licence failed' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
