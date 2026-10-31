function Get-LazyVMCredential {
    <#
    .SYNOPSIS
    Gets the administrator account LazyVM uses inside a VM, or its disks' BitLocker recovery passwords.

    .DESCRIPTION
    Returns the stored account as a PSCredential, ready to pass to commands
    such as Enter-PSSession -VMName. With -AsPlainText, returns the user name
    and password as text instead, for signing in to the VM yourself: the
    password LazyVM generated is only ever shown this way.

    With -ToClipboard, puts the password on the clipboard instead, for
    signing in through VMConnect, which blocks paste in the Windows sign-in
    box: use its Clipboard > Type clipboard text. The password is left out of
    clipboard history and never synced to other devices; clear the clipboard
    once you have signed in.

    With -RecoveryPassword, returns the BitLocker recovery password of each
    disk LazyVM encrypted: C: and every earlier OS disk, the SQL data disk,
    the Dev Drive and the User disk, each with its GPT disk GUID and when it
    was recorded. Needed only when a disk asks for it, such as a retired OS
    disk put back after a failed rebuild.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER AsPlainText
    Return the user name and the password as plain text.

    .PARAMETER RecoveryPassword
    Return the disks' BitLocker recovery passwords instead of the account.

    .PARAMETER ToClipboard
    Put the password on the clipboard, out of clipboard history, and return nothing.

    .EXAMPLE
    Enter-PSSession -VMName DevBox -Credential (Get-LazyVMCredential -Name DevBox)

    .EXAMPLE
    Get-LazyVMCredential -Name DevBox -AsPlainText

    Shows the password to sign in to the VM with.

    .EXAMPLE
    Get-LazyVMCredential -Name DevBox -ToClipboard

    Puts the password on the clipboard, to type into VMConnect's sign-in box
    with Clipboard > Type clipboard text.

    .EXAMPLE
    Get-LazyVMCredential -Name DevBox -RecoveryPassword

    Shows the BitLocker recovery password of each of the VM's disks.

    .OUTPUTS
    System.Management.Automation.PSCredential, LazyVM.PlainCredential with
    -AsPlainText, or LazyVM.RecoveryPassword with -RecoveryPassword.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Credential')]
    [OutputType([pscredential])]
    [OutputType('LazyVM.PlainCredential')]
    [OutputType('LazyVM.RecoveryPassword')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(ParameterSetName = 'Credential')]
        [switch]$AsPlainText,

        [Parameter(ParameterSetName = 'RecoveryPassword', Mandatory)]
        [switch]$RecoveryPassword,

        [Parameter(ParameterSetName = 'Clipboard', Mandatory)]
        [switch]$ToClipboard
    )

    process {
        Assert-Administrator
        $configuration = Read-VMSetting -Root (Resolve-LazyVMRoot).Path -VMName $Name

        if ($RecoveryPassword) {
            $table = Get-StoredSecretTable -KeyPath $configuration.Settings.CredKeyFile -Path $configuration.Settings.BitLockerCredFile
            if ($table.Count -eq 0) {
                throw "No BitLocker recovery password is stored for '$($configuration.VMName)' yet. Build-LazyVM and the daily maintenance turn BitLocker on and store them."
            }
            return $table.Keys | ForEach-Object {
                [pscustomobject]@{
                    PSTypeName       = 'LazyVM.RecoveryPassword'
                    Name             = $configuration.VMName
                    Disk             = $table[$_]['Disk']
                    DiskGuid         = $_
                    Recorded         = $table[$_]['Recorded']
                    RecoveryPassword = $table[$_]['RecoveryPassword']
                }
            } | Sort-Object -Property Disk, Recorded
        }

        $credential = Get-StoredCredential -KeyPath $configuration.Settings.CredKeyFile -Path $configuration.Settings.GuestCredFile

        if (-not $credential) {
            throw "No credential is stored for '$($configuration.VMName)' yet. Build-LazyVM creates one, or store one with: Set-LazyVMCredential -Name $($configuration.VMName)"
        }

        if ($ToClipboard) {
            Set-ClipboardSecret -Text $credential.GetNetworkCredential().Password
            Write-Warning "The password for $($credential.UserName) is on the clipboard, left out of clipboard history and sync. Clear it once you have signed in: Set-Clipboard -Value `$null"
            return
        }
        if (-not $AsPlainText) { return $credential }
        return [pscustomobject]@{
            PSTypeName = 'LazyVM.PlainCredential'
            Name       = $configuration.VMName
            UserName   = $credential.UserName
            Password   = $credential.GetNetworkCredential().Password
        }
    }
}
