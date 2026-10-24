function Set-LazyVMCredential {
    <#
    .SYNOPSIS
    Stores the administrator account LazyVM uses inside a VM.

    .DESCRIPTION
    LazyVM signs in to the VM over PowerShell Direct with this account, so
    builds, maintenance and rebuilds run without asking. It is stored
    encrypted in the LazyVM folder.

    For a VM LazyVM has not built yet, this is optional: Build-LazyVM creates
    the account with a generated password. Use it to choose the account name,
    or a password of your own.

    For a VM you set up by hand, store the account you sign in with and its
    real password.

    Leave the password empty to have one generated. Storing a new password
    does not change the password inside an existing VM.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Credential
    The account and password. Asked for when not given, with the current
    account name filled in.

    .PARAMETER Force
    Replace a stored credential without asking.

    .EXAMPLE
    Set-LazyVMCredential -Name DevBox

    Asks for the account and password.

    .EXAMPLE
    Set-LazyVMCredential -Name DevBox -Credential (Get-Credential -UserName sean)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [pscredential]$Credential,

        [switch]$Force
    )

    process {
        Invoke-CommandRun -Title 'Credential' -Name $Name -FailureMessage 'Storing the credential failed' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            $existing = Get-GuestCredential -VM $VM
            if ($existing -and -not $Force) {
                $question = "A credential for '$($existing.UserName)' is already stored for $($VM.Name). Replace it? This does not change the password inside the VM."
                if (-not $PSCmdlet.ShouldContinue($question, 'Replace the stored credential')) {
                    Write-LogEntry 'Kept the existing credential' 'INFO'
                    return
                }
            }

            $account = $Credential
            if (-not $account) {
                $message = "The administrator account INSIDE $($VM.Name). Leave the password empty to have one generated (for a VM LazyVM will build)."
                $account = Get-Credential -UserName $VM.Runtime.GuestAdminUser -Message $message
                if (-not $account) {
                    Write-LogEntry 'No credential entered - nothing was changed' 'INFO'
                    return
                }
            }

            if ($PSCmdlet.ShouldProcess($VM.Name, "Store the credential for '$($account.UserName)'")) {
                $null = Set-StoredGuestCredential -VM $VM -Credential $account
            }
        }
    }
}
