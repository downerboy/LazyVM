function Revoke-LazyVMSecurityFinding {
    <#
    .SYNOPSIS
    Undoes the approval of a security finding, so the nightly scan reports it again.

    .DESCRIPTION
    Removes the approval Approve-LazyVMSecurityFinding recorded in the VM's
    Config\SecurityBaseline.json. The next nightly scan reports the finding
    again, as new, if it still finds it.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Id
    The approved finding's Id, as Get-LazyVMSecurityFinding -Approved shows it.

    .EXAMPLE
    Revoke-LazyVMSecurityFinding -Name DevBox -Id 'AutoLogon:Winlogon:On'

    .EXAMPLE
    Get-LazyVMSecurityFinding -Name DevBox -Approved | Revoke-LazyVMSecurityFinding

    Revokes every approval of the VM.

    .OUTPUTS
    None.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Id
    )

    process {
        Invoke-CommandRun -Title 'Revoke a security finding approval' -Name $Name -FailureMessage 'Revoking the approval failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            $approval = Get-SecurityApproval -VM $VM -Id $Id
            if ($PSCmdlet.ShouldProcess($VM.Name, "Revoke the approval of the security finding $Id ($($approval.Title)), so the nightly scan reports it again")) {
                Remove-SecurityApproval -VM $VM -Id $Id
            }
        }
    }
}
