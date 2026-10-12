# CredentialSetup.ps1 - Storing the guest account (Set-LazyVMCredential).
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

function Resolve-GuestUserName {
    <#
      Normalises an account name. PowerShell Direct and the guest-side
      scheduled-task principal both want a bare local account name, so a
      DOMAIN\user or .\user form is reduced to its last segment.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $trimmed = $Name.Trim()
    if ($trimmed -match '[\\/]') {
        $trimmed = ($trimmed -split '[\\/]')[-1]
    }
    if ($trimmed -match '@') {
        throw "'$Name' looks like a Microsoft account or UPN. PowerShell Direct needs a LOCAL account in the guest."
    }
    if (-not $trimmed) { throw 'The guest user name is empty.' }
    return $trimmed
}

function Sync-GuestUserFromStore {
    <#
      The credential store is the single source of truth for which account
      LazyVM talks to, so the account name never has to be set in a settings
      file by hand.
    #>
    $stored = Get-StoredCredential -Path $CFG.GuestCredFile
    if ($stored -and $stored.UserName) {
        $CFG.GuestAdminUser = $stored.UserName
    }
}

function Set-StoredGuestCredential {
    <#
      Stores the guest account for the VM in $CFG. An empty password means
      "generate one": right for a VM LazyVM has not built yet, whose
      unattended Setup creates the account with it. Returns whether a
      password was generated.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A generated password has to become a SecureString once, on its way into the encrypted store.')]
    param([Parameter(Mandatory)][pscredential]$Credential)

    $userName = Resolve-GuestUserName -Name $Credential.UserName
    $password = $Credential.Password
    $generated = $false
    if (-not $password -or $password.Length -eq 0) {
        $password = ConvertTo-SecureString -String (New-RandomPassword) -AsPlainText -Force
        $generated = $true
    }

    Save-StoredCredential -Path $CFG.GuestCredFile -UserName $userName -Password $password
    $CFG.GuestAdminUser = $userName
    Write-LogEntry "Guest credential stored for '$userName' at $($CFG.GuestCredFile)" 'OK'
    if ($generated) {
        Write-LogEntry "  A password was generated. See it with: Get-LazyVMCredential -Name $($CFG.VMName) -AsPlainText" 'INFO'
    }
    return $generated
}
