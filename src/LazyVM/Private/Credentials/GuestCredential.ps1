# GuestCredential.ps1 - The account LazyVM signs in to the guest with.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# PowerShell Direct always needs an explicit credential; there is no
# pass-through. The credential store is the single source of truth for the
# account, so its name never has to be set in a settings file by hand.

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

function Get-GuestCredential {
    <# The VM's stored guest credential, or $null when none is stored. Throws when it cannot be read. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Get-StoredCredential -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.GuestCredFile
}

function Assert-GuestCredential {
    <# The VM's stored guest credential; throws, saying how to store one, when there is none. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $credential = Get-GuestCredential -VM $VM
    if (-not $credential) {
        throw "No guest credential is stored for '$($VM.Name)'. Store one with: Set-LazyVMCredential -Name $($VM.Name)"
    }
    return $credential
}

function Sync-GuestUserFromStore {
    <#
      Adopts the stored account's name. A credential that cannot be read is
      reported, not fatal: commands such as Remove-LazyVM never need it, and
      those that do say so when they try.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        $stored = Get-GuestCredential -VM $VM
        if ($stored -and $stored.UserName) { $VM.Runtime.GuestAdminUser = $stored.UserName }
    }
    catch {
        Write-LogEntry $_.Exception.Message 'WARN'
    }
}

function Initialize-GuestCredential {
    <#
      The VM's guest credential, generated and stored first for a VM that
      has none: right for a VM LazyVM is about to build, whose unattended
      Setup creates the account with it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $result = Get-OrNewStoredCredential -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.GuestCredFile -UserName $VM.Runtime.GuestAdminUser
    if ($result.Generated) {
        Write-LogEntry "Generated a guest administrator credential for '$($VM.Runtime.GuestAdminUser)'" 'OK'
        Write-LogEntry "  See it with: Get-LazyVMCredential -Name $($VM.Name) -AsPlainText" 'INFO'
    }
    return $result.Credential
}

function Set-StoredGuestCredential {
    <#
      Stores the guest account for the VM. An empty password means "generate
      one": right for a VM LazyVM has not built yet. Returns whether a
      password was generated.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    $userName = Resolve-GuestUserName -Name $Credential.UserName
    $generated = (-not $Credential.Password -or $Credential.Password.Length -eq 0)
    $password = if ($generated) { New-RandomPassword } else { $Credential.Password }

    Save-StoredCredential -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.GuestCredFile -UserName $userName -Password $password
    $VM.Runtime.GuestAdminUser = $userName
    Write-LogEntry "Guest credential stored for '$userName' at $($VM.Settings.GuestCredFile)" 'OK'
    if ($generated) {
        Write-LogEntry "  A password was generated. See it with: Get-LazyVMCredential -Name $($VM.Name) -AsPlainText" 'INFO'
    }
    return $generated
}
