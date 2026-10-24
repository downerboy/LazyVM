function Get-LazyVMCredential {
    <#
    .SYNOPSIS
    Gets the administrator account LazyVM uses inside a VM.

    .DESCRIPTION
    Returns the stored account as a PSCredential, ready to pass to commands
    such as Enter-PSSession -VMName. With -AsPlainText, returns the user name
    and password as text instead, for signing in to the VM yourself: the
    password LazyVM generated is only ever shown this way.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER AsPlainText
    Return the user name and the password as plain text.

    .EXAMPLE
    Enter-PSSession -VMName DevBox -Credential (Get-LazyVMCredential -Name DevBox)

    .EXAMPLE
    Get-LazyVMCredential -Name DevBox -AsPlainText

    Shows the password to sign in to the VM with.

    .OUTPUTS
    System.Management.Automation.PSCredential, or LazyVM.PlainCredential with -AsPlainText.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    [OutputType('LazyVM.PlainCredential')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [switch]$AsPlainText
    )

    process {
        Assert-Administrator
        $configuration = Read-VMSetting -Root (Resolve-LazyVMRoot).Path -VMName $Name
        $credential = Get-StoredCredential -KeyPath $configuration.Settings.CredKeyFile -Path $configuration.Settings.GuestCredFile

        if (-not $credential) {
            throw "No credential is stored for '$($configuration.VMName)' yet. Build-LazyVM creates one, or store one with: Set-LazyVMCredential -Name $($configuration.VMName)"
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
