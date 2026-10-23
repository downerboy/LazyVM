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
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $ConfirmPreference = 'None'
        }

        Assert-Administrator
        try {
            $null = Initialize-CommandRun -Title 'Remove' -Name $Name

            $context = Get-VMRemovalContext -ScriptDir $MyInvocation.MyCommand.Module.ModuleBase
            if (-not $context) { return }

            if (-not $PSCmdlet.ShouldProcess($CFG.VMName, 'Delete the VM and everything listed above, which cannot be undone')) {
                Write-LogEntry 'Removal cancelled - nothing has been changed.' 'INFO'
                return
            }

            $outcome = Invoke-VMRemoval -Context $context
            if ($outcome -eq 'incomplete') {
                throw "'$($CFG.VMName)' was only partly removed. The log lists what is left: $($CFG.LogFile)"
            }
        }
        catch {
            if ($script:LogReady) { Write-LogError 'Remove stopped' $_ }
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            Complete-CommandRun
        }
    }
}
