function Get-LazyVMSecurityFinding {
    <#
    .SYNOPSIS
    Lists what the last nightly security scan of a VM found.

    .DESCRIPTION
    Every night, as the last step of maintenance, LazyVM scans each VM: a
    Microsoft Defender quick scan, Defender's own protection and what it
    detected since the last scan, and security settings measured against
    the Microsoft security baseline. It only reports; it changes nothing in
    the VM.

    Each finding has an Id made from what was found, a Severity (High,
    Medium, Low or Info), a Title, what was found, why it matters, how to
    fix it, when it was first seen, and its Status compared with the scan
    before: New, Still open or Resolved. A resolved finding is listed once,
    by the scan that no longer found it.

    The scan also compares the places a program can start itself again
    (scheduled tasks, services, Run keys, startup folders, WMI event
    subscriptions, local users and Administrators) with the known-good
    baseline recorded after the build, and reports each change.

    The same findings are in the VM's log and in LazyVM Findings.html on the
    VM's desktop. A finding approved with Approve-LazyVMSecurityFinding is
    left out; -Approved lists the approvals instead. Reads only what the
    last scan and the approvals kept; it does not start or scan the VM.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Approved
    List the approved findings, with when and why each was approved, instead.

    .EXAMPLE
    Get-LazyVMSecurityFinding -Name DevBox

    .EXAMPLE
    Get-LazyVMSecurityFinding | Where-Object Status -ne 'Resolved'

    Only the findings that are still open.

    .EXAMPLE
    Get-LazyVMSecurityFinding -Name DevBox -Approved

    The approved findings.

    .OUTPUTS
    LazyVM.SecurityFinding, or with -Approved LazyVM.SecurityApproval
    #>
    [CmdletBinding(DefaultParameterSetName = 'Finding')]
    [OutputType('LazyVM.SecurityFinding', ParameterSetName = 'Finding')]
    [OutputType('LazyVM.SecurityApproval', ParameterSetName = 'Approved')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Approved')]
        [switch]$Approved
    )

    process {
        Invoke-CommandRun -Title 'Security findings' -Name $Name -FailureMessage 'Listing the security findings failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            if ($Approved) { Get-SecurityApprovalList -VM $VM }
            else { Get-SecurityFindingList -VM $VM }
        }
    }
}
