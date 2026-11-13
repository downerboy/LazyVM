function Approve-LazyVMSecurityFinding {
    <#
    .SYNOPSIS
    Accepts a security finding you expect, so the nightly scan stops reporting it.

    .DESCRIPTION
    Records the finding in the VM's Config\SecurityBaseline.json: its Id,
    severity and title, the date and your reason. Nothing of what was found
    is recorded. Do not put a password in the reason.

    An approved setting or persistence item, such as a scheduled task or a
    service you added, stays out of the findings while it is found with the
    same Id. When it changes, its Id changes, so the change is reported. An
    approved event, such as a Defender detection, covers that one
    occurrence: another one has an Id of its own. Once a scan no longer
    finds an approved finding, its approval ends.

    The finding is left out of Get-LazyVMSecurityFinding and the reminder
    straight away. LazyVM Findings.html in the VM still lists it until the
    next nightly scan replaces the file.

    Only an open finding of the last scan can be approved. It asks first,
    naming the finding; -Confirm:$false approves without asking. A finding
    that cannot be approved is reported as an error, and the rest of the
    pipeline is still approved. Revoke-LazyVMSecurityFinding undoes an
    approval.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Id
    The finding's Id, as Get-LazyVMSecurityFinding and the findings file show it.

    .PARAMETER Reason
    Why you expect it, kept with the approval.

    .EXAMPLE
    Approve-LazyVMSecurityFinding -Name DevBox -Id 'AutoLogon:Winlogon:On' -Reason 'LazyVM keeps it on by design'

    .EXAMPLE
    Get-LazyVMSecurityFinding -Name DevBox | Where-Object Id -like 'Service:MyService:*' | Approve-LazyVMSecurityFinding -Reason 'my own service'

    Approves the findings the pipeline gives it, by their Name and Id. Pick
    them by Id: a title is made from names that whatever is in the VM chose.

    .OUTPUTS
    None.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [string]$Reason = ''
    )

    process {
        Invoke-CommandRun -Title 'Approve a security finding' -Name $Name -FailureMessage 'Approving the security finding failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            try { $finding = Get-ApprovableSecurityFinding -VM $VM -Id $Id }
            catch {
                Write-CommandItemError -Cmdlet $PSCmdlet -ErrorRecord $_
                return
            }
            if ($PSCmdlet.ShouldProcess($VM.Name, "Approve the security finding $Id ($($finding.Title)), so the nightly scan stops reporting it until it changes")) {
                Add-SecurityApproval -VM $VM -Finding $finding -Reason $Reason
            }
        }
    }
}
