function Remove-LazyVM {
    <#
    .SYNOPSIS
    Deletes a VM and everything LazyVM created for it.

    .DESCRIPTION
    Removes the Hyper-V VM with its checkpoints, its disks (including the SQL
    data disk and the Dev Drive with its source code), its scheduled tasks
    and registry key, its stored passwords, captured state, logs, and its
    profile and tooling history.

    What every VM uses is kept: the LazyVM folder itself, the ISOs and
    installers, and your settings file. So is anything another VM also uses,
    such as the key that encrypts the stored passwords.

    Everything that would be deleted is listed first, with sizes, and you are
    asked to confirm. Use -WhatIf to see the list without deleting anything.
    This cannot be undone.

    .PARAMETER Name
    The VM to remove. Always required, so the wrong VM is never removed by
    accident.

    .PARAMETER Force
    Do not ask for confirmation. Needed when nobody is there to answer, such
    as in a script.

    .EXAMPLE
    Remove-LazyVM -Name OldBox -WhatIf

    Lists what would be deleted, and deletes nothing.

    .EXAMPLE
    Remove-LazyVM -Name OldBox
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [switch]$Force
    )

    process {
        Set-ForceConfirmation -Force:$Force -BoundParameters $PSBoundParameters
        $moduleDir = $MyInvocation.MyCommand.Module.ModuleBase
        Invoke-CommandRun -Title 'Remove' -Name $Name -FailureMessage 'Remove stopped' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            $context = Get-VMRemovalContext -VM $VM -ScriptDir $moduleDir
            if (-not $context) { return }

            if (-not $PSCmdlet.ShouldProcess($VM.Name, 'Delete the VM and everything listed above, which cannot be undone')) {
                Write-LogEntry 'Removal cancelled - nothing has been changed.' 'INFO'
                return
            }
            if ((Invoke-VMRemoval -VM $VM -Context $context) -eq [RemovalOutcome]::Incomplete) {
                throw "'$($VM.Name)' was only partly removed. The log lists what is left: $($VM.Settings.LogFile)"
            }
        }
    }
}
