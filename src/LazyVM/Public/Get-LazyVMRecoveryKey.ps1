function Get-LazyVMRecoveryKey {
    <#
    .SYNOPSIS
    Lists the BitLocker recovery keys LazyVM stores for a VM, and whether each one is exported, without the passwords.

    .DESCRIPTION
    One object per disk LazyVM encrypted: C: and every earlier OS disk, the
    SQL data disk, the Dev Drive and the User disk. Each has its disk, its
    GPT disk GUID, the key ID BitLocker's recovery screen shows for it (empty
    until the guest has reported it), when it was recorded, and Exported:
    whether the last Export-LazyVMRecoveryKey file held it. A key counts as
    not exported in the same cases as LazyVM's reminders, such as a new
    disk's, or one whose key ID is known only since the last export.

    The recovery passwords are never in the output. To see one, use
    Get-LazyVMCredential -RecoveryPassword; to keep a copy offline, use
    Export-LazyVMRecoveryKey. Returns nothing while no key is stored yet.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .EXAMPLE
    Get-LazyVMRecoveryKey -Name DevBox

    .EXAMPLE
    Get-LazyVMRecoveryKey -Name DevBox | Where-Object Exported -eq $false

    The keys of DevBox not exported yet.

    .OUTPUTS
    LazyVM.RecoveryKey
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.RecoveryKey')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        Assert-Administrator
        $configuration = Read-VMSetting -Root (Resolve-LazyVMRoot).Path -VMName $Name -ReadOnly
        Get-RecoveryKeyStatus -VM ([VMContext]::new($configuration.Settings))
    }
}
