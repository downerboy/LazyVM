function Get-LazyVMDashboard {
    <#
    .SYNOPSIS
    Lists every VM with what the LazyVM dashboard shows about it.

    .DESCRIPTION
    One object per VM profile: everything Get-LazyVM gives, and when the VM
    was created, the memory it is using, its disks and the space they take,
    its last maintenance run and how it ended, its last security scan and
    the findings still open, the configuration it was first built from, and
    its green template: the config template LazyVM keeps up to date with
    every change to the VM, to build another VM just like it.

    It only reads. What it cannot read for a VM is listed in that VM's
    Problems, and the rest is still filled in, so one VM never hides
    another. Hyper-V details need Hyper-V rights; without them State is
    'Unknown' and those details are empty, as for a VM not built yet.

    .PARAMETER Name
    The VM or VMs to list. Wildcards are allowed. All of them by default.

    .EXAMPLE
    Get-LazyVMDashboard

    .EXAMPLE
    Get-LazyVMDashboard -Name DevBox | Format-List

    .EXAMPLE
    Get-LazyVMDashboard | Where-Object OpenFindings -gt 0

    The VMs with security findings still open.

    .OUTPUTS
    LazyVM.Dashboard
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.Dashboard')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [SupportsWildcards()]
        [string]$Name = '*'
    )

    process {
        $root = (Resolve-LazyVMRoot).Path
        foreach ($vm in @(Get-LazyVM -Name $Name)) {
            New-DashboardEntry -Root $root -VM $vm
        }
    }
}
