# GuestSession.ps1 - The PowerShell Direct session to the guest: opening, waiting, closing.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Every guest call goes through one persistent session per command, kept in
# $VM.Runtime.Session with the credential that reopens it when the guest
# drops it (a restart, a crashed host process).

# When Windows in the guest last started: a new value means it restarted.
$script:ReadGuestBootTime = { (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime }

function Import-GuestHelper {
    <# Loads Data\Guest.Helpers.ps1 into the session as an in-memory module, for the guest script blocks to call. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $script:GuestHelperText) {
        $script:GuestHelperText = [IO.File]::ReadAllText((Join-Path -Path $script:DataDir -ChildPath 'Guest.Helpers.ps1'))
    }
    Invoke-Command -Session $VM.Runtime.Session -ArgumentList $script:GuestHelperText -ScriptBlock {
        param($text)
        # Two statements on purpose. PowerShell 7 turns a block that is one
        # pipeline into a command, working out its arguments on the host, and
        # a script block made there reaches the guest as plain text (#106).
        $helpers = [scriptblock]::Create($text)
        New-Module -Name 'LazyVM.Guest' -ScriptBlock $helpers | Import-Module -Global -Force
    } | Out-Null
}

function Test-GuestSessionOpen {
    param([Parameter(Mandatory)][VMContext]$VM)

    return ($VM.Runtime.Session -and $VM.Runtime.Session.State -eq 'Opened')
}

function Connect-Guest {
    <# Opens the session, retrying for up to $TimeoutMinutes, and loads the guest helpers into it. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 5
    )

    $VM.Runtime.Credential = $Credential
    if (Test-GuestSessionOpen -VM $VM) { return $VM.Runtime.Session }

    $attempt = @{ LastError = $null }
    $session = Wait-Until -Activity 'Opening the guest session' -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -State $attempt -NoThrow -Condition {
        param($s)
        try { New-PSSession -VMName $VM.Name -Credential $Credential -ErrorAction Stop }
        catch {
            # A wrong password does not come right by waiting.
            if (Test-GuestLogonFailure -ErrorRecord $_) {
                throw "The guest refused the account '$($Credential.UserName)': $($_.Exception.Message) Store the right password with Set-LazyVMCredential -Name $($VM.Name)."
            }
            $s.LastError = $_
            $null
        }
    }
    if (-not $session) {
        if ($attempt.LastError) { Write-LogError 'PowerShell Direct connection failed' $attempt.LastError }
        throw "Could not open a PowerShell Direct session to '$($VM.Name)' as '$($Credential.UserName)'. Check the guest account and password, and that the guest is past OOBE."
    }

    $VM.Runtime.Session = $session
    Import-GuestHelper -VM $VM
    return $session
}

function Test-GuestLogonFailure {
    <# True when PowerShell Direct failed because the guest rejected the user name or password. #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    return $ErrorRecord.Exception.Message -match 'credential is invalid|user name or password is incorrect|logon failure'
}

function Remove-GuestSession {
    <# Closes the session. With -KeepCredential the next guest call can still reopen it. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$KeepCredential
    )

    if ($VM.Runtime.Session) {
        # LazyVM's own session, so it is closed even under -WhatIf (#18).
        Remove-PSSession -Session $VM.Runtime.Session -ErrorAction SilentlyContinue -WhatIf:$false
        $VM.Runtime.Session = $null
    }
    if (-not $KeepCredential) { $VM.Runtime.Credential = $null }
}

function Restore-GuestSession {
    <#
      Reopens the session after the guest dropped it, for example when
      Windows restarted the VM. Returns the open session, or $null when there
      is no credential to reconnect with.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [int]$TimeoutMinutes = 15
    )

    if (Test-GuestSessionOpen -VM $VM) { return $VM.Runtime.Session }
    if (-not $VM.Runtime.Credential) { return $null }

    Remove-GuestSession -VM $VM -KeepCredential
    Write-LogEntry 'Lost the connection to the guest; reconnecting...' 'WARN'
    $session = Connect-Guest -VM $VM -Credential $VM.Runtime.Credential -TimeoutMinutes $TimeoutMinutes
    Write-LogEntry 'Reconnected to the guest' 'OK'
    return $session
}

function Wait-GuestReady {
    <#
      Waits for Windows Setup, OOBE and first logon to finish. With
      -RequireProvisioned (the answer file was used), a reachable guest is not
      enough: the answer file's first-logon marker must be there too, because
      the account exists, and answers PowerShell Direct, while OOBE is still
      on screen. Each new reason the guest is not reachable yet is logged, and
      if the wait runs out, the reason it was not ready at the last try is
      given: an error from an earlier try can be long out of date (#227).
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [switch]$RequireProvisioned
    )

    Write-LogEntry "Waiting up to $TimeoutMinutes minutes for the guest to finish installing and reach the desktop..." 'INFO'
    $started = Get-Date
    $progress = @{ Said = @{}; LastError = ''; NotReadyBecause = '' }

    # Logs a status line the first time it applies, not on every try.
    $sayOnce = {
        param($p, [string]$Key, [string]$Text)
        if (-not $p.Said.ContainsKey($Key)) { $p.Said[$Key] = $true; Write-LogEntry "  $Text" 'INFO' }
    }

    $ready = Wait-Until -Activity 'Waiting for the guest' -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -Interval ([timespan]::FromSeconds(20)) -State $progress -NoThrow -Condition {
        param($p)
        $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
        if (-not $machine) { throw "VM '$($VM.Name)' disappeared while waiting." }
        if ($machine.State -ne 'Running') {
            $p.NotReadyBecause = "the VM was '$($machine.State)'"
            & $sayOnce $p 'start' "VM state is '$($machine.State)' - starting it"
            Start-VM -Name $VM.Name -ErrorAction SilentlyContinue | Out-Null
            return $null
        }

        # Heartbeat first: cheap, and it says the OS is actually up.
        $heartbeat = Get-VMIntegrationService -VMName $VM.Name -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if (-not $heartbeat -or $heartbeat.PrimaryStatusDescription -ne 'OK') {
            $p.NotReadyBecause = 'the guest never reported a heartbeat, so Windows did not start'
            & $sayOnce $p 'heartbeat' 'guest is still installing (no heartbeat yet)'
            return $null
        }

        try {
            $session = New-PSSession -VMName $VM.Name -Credential $Credential -ErrorAction Stop
            try {
                # Set by the answer file's first-logon command; absent without it.
                $markerKey = $script:GuestMarkerKey
                $provisioned = Invoke-Command -Session $session -ScriptBlock {
                    $value = Get-ItemProperty -Path $using:markerKey -Name 'Provisioned' -ErrorAction SilentlyContinue
                    return [bool]($value -and $value.Provisioned -eq 1)
                }
            }
            finally { Remove-PSSession -Session $session -ErrorAction SilentlyContinue -WhatIf:$false }
        }
        catch {
            $p.NotReadyBecause = "the guest could not be reached: $($_.Exception.Message)"
            if ($_.Exception.Message -ne $p.LastError) {
                $p.LastError = $_.Exception.Message
                Write-LogEntry "  guest not reachable yet: $($p.LastError)" 'INFO'
            }
            return $null
        }

        if ($RequireProvisioned -and -not $provisioned) {
            $p.NotReadyBecause = 'the guest was reachable, but the first-logon marker never appeared, so Windows Setup or the first logon did not finish'
            & $sayOnce $p 'oobe' 'guest is reachable but Windows is still finishing setup (OOBE)'
            return $null
        }
        return [pscustomobject]@{ Provisioned = $provisioned }
    }

    if (-not $ready) {
        $reason = if ($progress.NotReadyBecause) { ": $($progress.NotReadyBecause)" } else { '' }
        throw "The guest was not ready within $TimeoutMinutes minutes$reason. Open the VM console to see where Setup stopped."
    }

    $elapsed = [int]((Get-Date) - $started).TotalMinutes
    if ($ready.Provisioned) {
        Write-LogEntry "Guest is provisioned and reachable (after $elapsed min)" 'OK'
    }
    else {
        Write-LogEntry "Guest is reachable over PowerShell Direct (after $elapsed min); no provisioning marker - continuing" 'OK'
    }
}

function Open-GuestSession {
    <#
      The usual way into the guest: the VM must exist and have a stored
      credential; it is started if it is off and waited for; then the session
      opens. Returns $true when it had to start the VM, so the caller can shut
      it down again afterwards.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Purpose
    )

    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if (-not $machine) { throw "VM '$($VM.Name)' does not exist yet. Build it with: Build-LazyVM -Name $($VM.Name)" }

    $credential = Assert-GuestCredential -VM $VM

    $started = $false
    if ($machine.State -ne 'Running') {
        Write-LogEntry "VM is '$($machine.State)' - starting it to $Purpose" 'INFO'
        Start-VM -Name $VM.Name | Out-Null
        Wait-GuestReady -VM $VM -Credential $credential -TimeoutMinutes $VM.Settings.GuestWaitMinutes
        $started = $true
    }
    Connect-Guest -VM $VM -Credential $credential | Out-Null
    return $started
}

function Restart-GuestGracefully {
    <#
      Restarts Windows from inside the guest, as its Start menu does, and
      reopens the session once it is back. Updates waiting for a restart
      finish installing while Windows shuts down and starts, which a reset
      (Restart-VM) would cut short. Windows is given a few seconds' notice;
      it then closes what is open, so this is only for a guest nobody is at
      work in. Windows may spend a while installing updates before it goes
      down, still answering PowerShell Direct, so the restart counts as done
      only once the guest reports a new boot time. Throws when it does not
      within GuestWaitMinutes.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $credential = Assert-GuestCredential -VM $VM
    $bootTime = Invoke-GuestScript -VM $VM -Activity 'reading the boot time' -TimeoutMinutes 2 -ScriptBlock $script:ReadGuestBootTime
    $exitCode = Invoke-GuestScript -VM $VM -Activity 'restarting Windows' -TimeoutMinutes 2 -ScriptBlock {
        & shutdown.exe /r /t 10 /c 'LazyVM is restarting Windows.' | Out-Null
        return $LASTEXITCODE
    }
    if ([int]$exitCode -ne 0) { throw "Windows in the guest refused to restart (shutdown.exe exit $exitCode)" }

    Write-LogEntry 'Restarting Windows in the guest...' 'INFO'
    Remove-GuestSession -VM $VM -KeepCredential
    $null = Wait-Until -Activity 'The guest restart' -Timeout ([timespan]::FromMinutes($VM.Settings.GuestWaitMinutes)) -Interval ([timespan]::FromSeconds(20)) -Condition {
        # Each try is a one-off PowerShell Direct call: the guest goes away
        # and comes back between tries, which a kept session would not survive.
        try { $now = Invoke-GuestCheck -VM $VM -Credential $credential -ScriptBlock $script:ReadGuestBootTime }
        catch { return $false }
        return ($null -ne $now -and "$now" -ne "$bootTime")
    }
    Connect-Guest -VM $VM -Credential $credential | Out-Null
}

function Wait-GuestSettled {
    <#
      Waits, after a restart in the build, until the guest has settled:
      Windows may restart again to finish updates, and automatic sign-in
      signs the guest account in only a while after it starts, so the guest
      answering once is not enough (#276). Settled is PowerShell Direct
      answering, the boot time the same as at the check before (so no
      further restart), and the guest account signed in, unless automatic
      sign-in is off in the guest, when nobody would sign in. Each check is
      a one-off call (Invoke-GuestCheck), so the wait keeps to
      GuestWaitMinutes; the kept session is reopened once at the end. It
      says what it waits for each time that changes. When the guest has not
      settled in time it warns, with the last error, and returns; the steps
      after it say what they could not do. It never throws, so the build
      never hangs or stops here.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $credential = Assert-GuestCredential -VM $VM
    $minutes = $VM.Settings.GuestWaitMinutes
    $account = $VM.Runtime.GuestAdminUser
    Write-LogEntry "Waiting up to $minutes minutes for the guest to settle: no further restart, and '$account' signed in..." 'INFO'
    $progress = @{ BootTime = $null; WaitingFor = ''; LastError = '' }

    # Logs what the wait is for when that changes, not on every check.
    $waitFor = {
        param($p, [string]$What)
        if ($p.WaitingFor -ne $What) { $p.WaitingFor = $What; Write-LogEntry "  waiting for $What" 'INFO' }
    }

    $settled = Wait-Until -Activity 'The guest settling' -Timeout ([timespan]::FromMinutes($minutes)) -Interval ([timespan]::FromSeconds(30)) -State $progress -NoThrow -Condition {
        param($p)
        try {
            $bootTime = "$(Invoke-GuestCheck -VM $VM -Credential $credential -ScriptBlock $script:ReadGuestBootTime)"
            $signedIn = Test-GuestAccountSignedIn -VM $VM -Credential $credential
            $autoSignIn = $signedIn -or (Test-GuestAutoSignIn -VM $VM -Credential $credential)
        }
        catch {
            $p.LastError = $_.Exception.Message
            & $waitFor $p 'PowerShell Direct to answer'
            return $false
        }
        # An error from an earlier check says nothing about the guest now (#227).
        $p.LastError = ''

        $sameBoot = $bootTime -eq $p.BootTime
        if ($p.BootTime -and -not $sameBoot) { Write-LogEntry "  The guest restarted again (boot time $bootTime)" 'INFO' }
        $p.BootTime = $bootTime
        if (-not $sameBoot) {
            & $waitFor $p 'the boot time to stay the same (no further restart)'
            return $false
        }
        if (-not $autoSignIn) {
            Write-LogEntry "  automatic sign-in is off in the guest, so '$account' signing in is not waited for" 'INFO'
            return $true
        }
        if (-not $signedIn) {
            & $waitFor $p "automatic sign-in of '$account'"
            return $false
        }
        return $true
    }

    if ($settled) {
        Write-LogEntry 'The guest has settled' 'OK'
    }
    else {
        $lastError = if ($progress.LastError) { "; last error: $($progress.LastError)" } else { '' }
        Write-LogEntry "The guest did not settle within $minutes minutes (still waiting for $($progress.WaitingFor)$lastError) - carrying on; the steps that need it say so" 'WARN'
    }

    # The guest may have restarted under the kept session; the steps after this use it.
    try {
        Remove-GuestSession -VM $VM -KeepCredential
        $null = Connect-Guest -VM $VM -Credential $credential
    }
    catch {
        Write-LogEntry "Could not reopen the guest session after waiting for the guest to settle: $($_.Exception.Message) - the next guest step tries again" 'WARN'
    }
}

function Stop-GuestGracefully {
    <# Shuts the guest down, and turns it off if it has not stopped within $TimeoutMinutes. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [int]$TimeoutMinutes = 10
    )

    Remove-GuestSession -VM $VM
    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if (-not $machine -or $machine.State -eq 'Off') { return }

    Write-LogEntry 'Shutting the guest down...' 'INFO'
    Stop-VM -Name $VM.Name -Force:$false -ErrorAction SilentlyContinue | Out-Null

    $off = Wait-Until -Activity 'The shutdown' -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -NoThrow -Condition {
        $current = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
        (-not $current) -or $current.State -eq 'Off'
    }
    if ($off) {
        Write-LogEntry 'Guest is off' 'OK'
        return
    }
    Write-LogEntry "Guest did not shut down within $TimeoutMinutes minutes - forcing it off" 'WARN'
    Stop-VM -Name $VM.Name -TurnOff -Force | Out-Null
}
