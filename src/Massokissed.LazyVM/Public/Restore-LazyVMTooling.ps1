function Restore-LazyVMTooling {
    <#
    .SYNOPSIS
    Returns a VM to a recorded tooling version.

    .DESCRIPTION
    Applies the checkpoint taken when that tooling version was recorded, and
    restores the matching tooling list.

    The checkpoint covers ALL of the VM's disks, including the Dev Drive and
    the SQL data disk: code not yet pushed and database changes made since
    then are lost. A checkpoint of the current state is taken first, so the
    revert itself can be undone.

    .PARAMETER Name
    The VM.

    .PARAMETER RestorePoint
    The version to return to, as Get-LazyVMRestorePoint lists it, such as
    20261008-193000.

    .PARAMETER Force
    Do not ask for confirmation.

    .EXAMPLE
    Get-LazyVMRestorePoint -Name DevBox

    Restore-LazyVMTooling -Name DevBox -RestorePoint 20261008-193000

    .EXAMPLE
    Get-LazyVMRestorePoint -Name DevBox | Select-Object -Last 1 | Restore-LazyVMTooling
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory, Position = 1, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^\d{8}-\d{6}$', ErrorMessage = "'{0}' is not a restore point. They look like 20261008-193000: see Get-LazyVMRestorePoint.")]
        [string]$RestorePoint,

        [switch]$Force
    )

    process {
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $ConfirmPreference = 'None'
        }

        Assert-Administrator
        try {
            $null = Initialize-CommandRun -Title 'Revert tooling' -Name $Name
            $action = "Return to tooling version $RestorePoint. ALL its disks go back to then, including the Dev Drive and SQL data disk"
            if (-not $PSCmdlet.ShouldProcess($CFG.VMName, $action)) {
                Write-LogEntry 'Revert cancelled' 'INFO'
                return
            }
            Invoke-ToolingRevert -Stamp $RestorePoint
        }
        catch {
            if ($script:LogReady) { Write-LogError 'The revert failed' $_ }
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            Complete-CommandRun
        }
    }
}
