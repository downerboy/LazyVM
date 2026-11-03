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

    The same findings are in the VM's log and in LazyVM Findings.txt on the
    VM's desktop. Reads only what the last scan kept; it does not start or
    scan the VM.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Get-LazyVMSecurityFinding -Name DevBox

    .EXAMPLE
    Get-LazyVMSecurityFinding | Where-Object Status -ne 'Resolved'

    Only the findings that are still open.

    .OUTPUTS
    LazyVM.SecurityFinding
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.SecurityFinding')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Invoke-CommandRun -Title 'Security findings' -Name $Name -FailureMessage 'Listing the security findings failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            Get-SecurityFindingList -VM $VM
        }
    }
}
