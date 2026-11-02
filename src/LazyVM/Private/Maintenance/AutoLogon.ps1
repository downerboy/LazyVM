# AutoLogon.ps1 - Keeping the guest's automatic sign-in on for the VM's life (#278).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Visual Studio settings retry, the winget upgrades for per-user
# packages and the settle wait all need the guest account signed in, which
# automatic sign-in does whenever the VM starts. A new build's answer file
# removes the logon count at the first sign-in; a VM built before that
# stops signing in by itself after 99 starts, so maintenance turns it back
# on. Only a VM built with -NoUnattend goes without it. The work in the
# guest is in Data\Guest.Helpers.ps1.

function Get-AutoLogonFix {
    <#
      What renewing automatic sign-in fixes, as phrases for the log: it is
      off, a logon count would turn it off, or the password sits in the
      registry in clear text. Nothing when it needs no renewal. The rule,
      kept apart so it can be tested on its own.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][pscustomobject]$State)

    $fixes = [System.Collections.Generic.List[string]]::new()
    if ($State.AutoAdminLogon -ne '1') { $fixes.Add('turned it back on') }
    if ($State.HasLogonCount) { $fixes.Add('removed a leftover logon count') }
    if ($State.HasPlainTextPassword) { $fixes.Add('moved a clear-text password into the LSA secret') }
    return $fixes.ToArray()
}

function Repair-GuestAutoLogon {
    <#
      Renews automatic sign-in, with no limit, for the stored guest account
      when it needs it, the password stored as the LSA secret. A VM built
      with -NoUnattend, whose user chose to sign in by hand, is left alone.
      Runs in the PowerShell Direct session as the guest administrator,
      which may write the LSA secret, with the credential as remoting
      carries it: the password encrypted with the session key. A guest task
      would write its arguments to the guest's disk.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $state = Invoke-GuestScript -VM $VM -Activity 'automatic sign-in check' -TimeoutMinutes 5 -ArgumentList @($script:GuestMarkerKey) -ScriptBlock {
        param($markerKey)
        $ErrorActionPreference = 'Stop'
        Get-GuestAutoLogonState -MarkerKey $markerKey
    }
    if (-not $state.Unattended) {
        Write-Verbose 'Automatic sign-in: the VM was built without the answer file (-NoUnattend), so it is left as it is'
        return
    }
    $fixes = @(Get-AutoLogonFix -State $state)
    if ($fixes.Count -eq 0) { return }

    $credential = Assert-GuestCredential -VM $VM
    $null = Invoke-GuestScript -VM $VM -Activity 'automatic sign-in' -TimeoutMinutes 5 -ArgumentList @($credential) -ScriptBlock {
        param([pscredential]$credential)
        $ErrorActionPreference = 'Stop'
        Enable-GuestAutoLogon -Credential $credential
    }
    Write-LogEntry "Automatic sign-in for '$($credential.UserName)', now with no limit: $($fixes -join '; ')" 'OK'
}
