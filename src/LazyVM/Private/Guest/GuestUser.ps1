# GuestUser.ps1 - Who is signed in to the guest.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# The owners of the running Explorer processes: the accounts signed in.
$script:ReadGuestSignedInUser = {
    $owners = foreach ($explorer in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'")) {
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        if ($owner.ReturnValue -eq 0) { $owner.User }
    }
    return @($owners | Sort-Object -Unique)
}

# Whether Windows signs an account in by itself when it starts.
$script:ReadGuestAutoSignIn = {
    (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
}

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

    $users = Invoke-GuestScript -VM $VM -Activity 'checking who is signed in' -TimeoutMinutes 2 -RetryOnDisconnect -ScriptBlock $script:ReadGuestSignedInUser
    # Strings back from the guest carry remoting's properties; plain names are what callers compare.
    return @($users | ForEach-Object { "$_" })
}

function Test-GuestAccountSignedIn {
    <#
      Whether the guest account is signed in, asked in one quick one-off
      call (Invoke-GuestCheck), for a bounded wait. Throws when the guest
      cannot be asked.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    $users = Invoke-GuestCheck -VM $VM -Credential $Credential -ScriptBlock $script:ReadGuestSignedInUser
    return (@($users | ForEach-Object { "$_" }) -contains $VM.Runtime.GuestAdminUser)
}

function Test-GuestAutoSignIn {
    <#
      Whether automatic sign-in is on in the guest (Winlogon AutoAdminLogon
      is 1), asked in one quick one-off call. When it is off, nobody signs
      in by themselves, so a wait for sign-in is not worth making (#276).
      Throws when the guest cannot be asked.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    return ("$(Invoke-GuestCheck -VM $VM -Credential $Credential -ScriptBlock $script:ReadGuestAutoSignIn)" -eq '1')
}

function Wait-GuestSignedIn {
    <#
      Waits up to $TimeoutMinutes for automatic sign-in to sign the guest
      account in, as it does a little while after each start (#276), and
      says once what it waits for. Each check is a one-off call, so the wait
      keeps to its time, and a guest that cannot be asked yet counts as not
      signed in yet. When automatic sign-in is off in the guest, it does not
      wait. Returns whether the account is signed in; never throws.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][int]$TimeoutMinutes
    )

    $credential = Assert-GuestCredential -VM $VM
    $account = $VM.Runtime.GuestAdminUser
    $progress = @{ Said = $false; LastError = '' }
    $outcome = Wait-Until -Activity "Automatic sign-in of '$account'" -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -Interval ([timespan]::FromSeconds(15)) -State $progress -NoThrow -Condition {
        param($p)
        try {
            if (Test-GuestAccountSignedIn -VM $VM -Credential $credential) { return 'SignedIn' }
            if (-not (Test-GuestAutoSignIn -VM $VM -Credential $credential)) { return 'AutoSignInOff' }
            $p.LastError = ''
        }
        catch { $p.LastError = $_.Exception.Message }
        if (-not $p.Said) {
            $p.Said = $true
            Write-LogEntry "  waiting up to $TimeoutMinutes minutes for automatic sign-in of '$account'" 'INFO'
        }
        return $null
    }

    if ($outcome -eq 'AutoSignInOff') {
        Write-LogEntry "  automatic sign-in is off in the guest, so '$account' signing in is not waited for" 'INFO'
    }
    elseif (-not $outcome -and $progress.LastError) {
        Write-LogEntry "  could not ask the guest who is signed in: $($progress.LastError)" 'INFO'
    }
    return ($outcome -eq 'SignedIn')
}
