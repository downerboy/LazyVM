function Get-LazyVMRemovalPlan {
    <#
    .SYNOPSIS
    Lists what Remove-LazyVM would delete for a VM, and what it would keep.

    .DESCRIPTION
    The same list Remove-LazyVM writes to the log before it asks, as an
    object: the Hyper-V VM with its state and checkpoints, its scheduled
    tasks, each file and folder with its size, the total, what is kept and
    why, and the disks holding your own work that go too (the Dev Drive and
    the User disk), each with advice on what to save first.

    It only reads, and writes nothing, not even the VM's log. When nothing
    of the VM is left to remove, Items, Tasks and HyperVState are empty.
    When the VM folder holds something another VM uses, it stops with the
    error Remove-LazyVM would give, since nothing could be removed.

    .PARAMETER Name
    The VM. Always required, as for Remove-LazyVM.

    .EXAMPLE
    Get-LazyVMRemovalPlan -Name OldBox

    .EXAMPLE
    (Get-LazyVMRemovalPlan -Name OldBox).Items | Format-Table Kind, Path, Size

    .EXAMPLE
    Get-LazyVMRemovalPlan -Name OldBox | Remove-LazyVM

    Removes the VM the list is for, after asking.

    .OUTPUTS
    LazyVM.RemovalPlan
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.RemovalPlan')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        # What Hyper-V reports needs the same rights as the removal itself.
        Assert-Administrator
        $root = (Resolve-LazyVMRoot).Path
        $vm = [VMContext]::new((Read-VMSetting -Root $root -VMName $Name -ReadOnly).Settings)
        $preview = Get-VMRemovalPreview -VM $vm -ScriptDir $MyInvocation.MyCommand.Module.ModuleBase -ReadOnly

        [pscustomobject]@{
            PSTypeName      = 'LazyVM.RemovalPlan'
            Name            = $vm.Name
            HyperVState     = if ($preview -and $preview.Machine) { "$($preview.Machine.State)" } else { $null }
            CheckpointCount = if ($preview) { [int]$preview.CheckpointCount } else { 0 }
            Tasks           = @(if ($preview) { $preview.Tasks })
            Items           = @(if ($preview) { $preview.Items | ForEach-Object { [pscustomobject]@{ PSTypeName = 'LazyVM.RemovalItem'; Kind = $_.Kind; Path = $_.Path; Size = $_.Size } } })
            Total           = if ($preview) { $preview.Total } else { [double]0 }
            Kept            = @(if ($preview) { $preview.Kept | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Reason = $_.Reason } } })
            WorkDisks       = @(if ($preview) { $preview.WorkDisks })
        }
    }
}
