# AutoLogon.ps1 - Keeping the guest's automatic sign-in on for the VM's life (#278).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Visual Studio settings retry, the winget upgrades for per-user
# packages and the settle wait all need the guest account signed in, which
# automatic sign-in does whenever the VM starts. A new build's answer file
# removes the logon count at the first sign-in; a VM built before that
# stops signing in by itself after 99 starts, so maintenance turns it back
# on. The work in the guest is in Data\Guest.Helpers.ps1.

function Test-AutoLogonRenewalNeeded {
    <#
      True when automatic sign-in has to be set again: Windows turned it
      off, a logon count would turn it off, or the password sits in the
      registry in clear text. The rule, kept apart so it can be tested on
      its own.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$State)

    return $State.AutoAdminLogon -ne '1' -or $State.HasLogonCount -or $State.HasPlainTextPassword
}

function Repair-GuestAutoLogon {
    <#
      Turns automatic sign-in back on, with no limit, for the stored guest
      account when it needs it, the password stored as the LSA secret. A VM
      built with -NoUnattend, whose user chose to sign in by hand, is left
      alone. Runs in the PowerShell Direct session as the guest
      administrator, which may write the LSA secret; a guest task would
      write its arguments, the password among them, to the guest's disk.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The guest password has to cross into the guest as text, as the certificate passwords do, for LsaStorePrivateData.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'The guest script block takes the account and its password as text; see the line above.')]
    param([Parameter(Mandatory)][VMContext]$VM)

    $state = Invoke-GuestScript -VM $VM -Activity 'automatic sign-in check' -TimeoutMinutes 5 -ArgumentList @($script:GuestMarkerKey) -ScriptBlock {
        param($markerKey)
        $ErrorActionPreference = 'Stop'
        Get-GuestAutoLogonState -MarkerKey $markerKey
    }
    if (-not $state.Unattended) {
        Write-LogEntry 'Automatic sign-in: the VM was built without the answer file (-NoUnattend), so it is left as it is' 'INFO'
        return
    }
    if (-not (Test-AutoLogonRenewalNeeded -State $state)) { return }

    $credential = Assert-GuestCredential -VM $VM
    $null = Invoke-GuestScript -VM $VM -Activity 'automatic sign-in' -TimeoutMinutes 5 -ArgumentList @($credential.UserName, (ConvertTo-PlainText -Secure $credential.Password)) -ScriptBlock {
        param($userName, $password)
        $ErrorActionPreference = 'Stop'
        Enable-GuestAutoLogon -UserName $userName -Password $password
    }
    Write-LogEntry "Automatic sign-in: turned back on for '$($credential.UserName)', with no limit" 'OK'
}
