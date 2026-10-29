function Invoke-LazyVMRebuild {
    <#
    .SYNOPSIS
    Rebuilds a VM from scratch, keeping its work.

    .DESCRIPTION
    Records in VM.json any hardware change made to the VM in Hyper-V, so the
    new VM is made as the VM is now. Then captures the VM's state, retires
    its Windows disk by renaming it, builds a fresh VM from the profile and
    tooling list, puts the captured state
    back and checks the result. The old Windows disk is deleted only once the
    new VM has passed the check; if anything goes wrong it is kept, and the
    log says how to go back to it.

    The SQL data disk and the Dev Drive are never touched.

    The daily maintenance does this by itself when the Windows evaluation is
    about to expire and no rearms are left.

    .PARAMETER Name
    The VM to rebuild.

    .PARAMETER SkipCapture
    Use the capture already on the host instead of taking a new one.

    .PARAMETER NoUnattend
    Do not give the new VM an answer file: Windows Setup has to be completed
    by hand.

    .PARAMETER Force
    Do not ask for confirmation.

    .EXAMPLE
    Invoke-LazyVMRebuild -Name DevBox
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [switch]$SkipCapture,

        [switch]$NoUnattend,

        [switch]$Force
    )

    process {
        Set-ForceConfirmation -Force:$Force -BoundParameters $PSBoundParameters
        Invoke-CommandRun -Title 'Rebuild' -Name $Name -FailureMessage 'The rebuild stopped' -Cmdlet $PSCmdlet -RecordHardware -ScriptBlock {
            param($VM)
            $action = 'Rebuild from scratch. State is captured first and restored afterwards, and the old Windows disk is kept until the new VM is checked'
            if (-not $PSCmdlet.ShouldProcess($VM.Name, $action)) {
                Write-LogEntry 'Rebuild cancelled' 'INFO'
                return
            }
            Sync-VMProfile -VM $VM
            if (@(Invoke-Rebuild -VM $VM -SkipCapture:$SkipCapture -NoUnattend:$NoUnattend)[-1] -ne $true) {
                throw "The rebuild of '$($VM.Name)' did not complete cleanly. The log says what happened and how to go back: $($VM.Settings.LogFile)"
            }
        }
    }
}
