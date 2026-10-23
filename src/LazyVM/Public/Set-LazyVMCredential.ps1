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
        Assert-Administrator
        try {
            $null = Initialize-CommandRun -Title 'Credential' -Name $Name

            $existing = Get-StoredCredential -Path $CFG.GuestCredFile
            if ($existing -and -not $Force) {
                $question = "A credential for '$($existing.UserName)' is already stored for $($CFG.VMName). Replace it? This does not change the password inside the VM."
                if (-not $PSCmdlet.ShouldContinue($question, 'Replace the stored credential')) {
                    Write-LogEntry 'Kept the existing credential' 'INFO'
                    return
                }
            }

            if (-not $Credential) {
                $message = "The administrator account INSIDE $($CFG.VMName). Leave the password empty to have one generated (for a VM LazyVM will build)."
                $Credential = Get-Credential -UserName $CFG.GuestAdminUser -Message $message
                if (-not $Credential) {
                    Write-LogEntry 'No credential entered - nothing was changed' 'INFO'
                    return
                }
            }

            if ($PSCmdlet.ShouldProcess($CFG.VMName, "Store the credential for '$($Credential.UserName)'")) {
                $null = Set-StoredGuestCredential -Credential $Credential
            }
        }
        catch {
            if ($script:LogReady) { Write-LogError 'Storing the credential failed' $_ }
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            Complete-CommandRun
        }
    }
}
