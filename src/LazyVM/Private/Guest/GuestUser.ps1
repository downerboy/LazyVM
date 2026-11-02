# GuestUser.ps1 - Who is signed in to the guest.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Get-GuestSignedInUser {
    <#
      The accounts signed in to the guest, each once: at its console, in a
      Remote Desktop or Enhanced Session window, or in a session left
      disconnected with programs still open. Every desktop runs Explorer, so
      the owners of the running Explorer processes are the signed-in
      accounts, whatever language Windows is in. Automatic sign-in signs the
      guest account in at the console each time the VM starts, so a running
      VM usually has someone signed in. Maintenance work that must not
      disturb someone at work in the VM asks this first.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $users = Invoke-GuestScript -VM $VM -Activity 'checking who is signed in' -TimeoutMinutes 2 -RetryOnDisconnect -ScriptBlock {
        $owners = foreach ($explorer in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'")) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.ReturnValue -eq 0) { $owner.User }
        }
        return @($owners | Sort-Object -Unique)
    }
    # Strings back from the guest carry remoting's properties; plain names are what callers compare.
    return @($users | ForEach-Object { "$_" })
}

function Wait-GuestSignedIn {
    <#
      Waits up to $TimeoutMinutes for automatic sign-in to sign the guest
      account in, as it does a little while after each start (#276), and
      says once what it waits for. Returns whether the account is signed in.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][int]$TimeoutMinutes
    )

    $account = $VM.Runtime.GuestAdminUser
    $progress = @{ Said = $false }
    $signedIn = Wait-Until -Activity "Automatic sign-in of '$account'" -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -Interval ([timespan]::FromSeconds(15)) -State $progress -NoThrow -Condition {
        param($p)
        if (@(Get-GuestSignedInUser -VM $VM) -contains $account) { return $true }
        if (-not $p.Said) {
            $p.Said = $true
            Write-LogEntry "  waiting up to $TimeoutMinutes minutes for automatic sign-in of '$account'" 'INFO'
        }
        return $false
    }
    return [bool]$signedIn
}
