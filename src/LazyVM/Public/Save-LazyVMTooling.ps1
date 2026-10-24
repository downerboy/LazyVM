function Save-LazyVMTooling {
    <#
    .SYNOPSIS
    Records a VM's tooling now, as the daily maintenance does.

    .DESCRIPTION
    Compares what is installed in the VM with its recorded tooling list. If
    anything was added or removed, a Hyper-V checkpoint is taken first and
    then the new list is recorded, so the VM can be returned to the previous
    version with Restore-LazyVMTooling. A rebuild installs from this list.

    Version updates are not changes: updating Visual Studio or an SDK never
    takes a checkpoint.

    Starts the VM if it is off, and shuts it down again afterwards.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Save-LazyVMTooling -Name DevBox

    .OUTPUTS
    System.String: each change recorded. Nothing when there were none.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Record tooling' -Name $Name -FailureMessage 'Recording the tooling failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            if (-not $PSCmdlet.ShouldProcess($VM.Name, 'Record the tooling, with a checkpoint if it changed')) {
                return
            }
            $startedHere = Open-GuestSession -VM $VM -Purpose 'record its tooling'
            Update-ToolingRecord -VM $VM
            if ($startedHere) { Stop-GuestGracefully -VM $VM }
        }
    }
}
