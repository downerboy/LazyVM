# GuestScript.ps1 - Running work in the guest and moving files in and out.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Short work runs over the session as a job, so it can be given a real
# timeout instead of blocking forever. Long work, and work that needs the
# signed-in user's desktop, runs as a one-shot scheduled task in the guest
# (Start-GuestTask in Guest.Helpers.ps1) that the host checks on.

function Invoke-GuestScript {
    <# Runs a script block in the guest with a timeout. Throws on failure, so an error is never taken for success. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutMinutes = 15,
        [string]$Activity = 'guest command'
    )

    $session = Restore-GuestSession -VM $VM
    if (-not $session) { throw "No open guest session for: $Activity" }

    $job = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob
    try {
        if (-not (Wait-Job -Job $job -Timeout ($TimeoutMinutes * 60))) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "$Activity did not finish within $TimeoutMinutes minutes"
        }

        $result = Receive-Job -Job $job -ErrorAction Stop
        if ($job.State -eq 'Failed') {
            $reason = if ($job.ChildJobs -and $job.ChildJobs[0].JobStateInfo.Reason) { $job.ChildJobs[0].JobStateInfo.Reason.Message } else { 'unknown error' }
            throw "$Activity failed in guest: $reason"
        }
        return $result
    }
    finally {
        # LazyVM's own job, so it is removed even under -WhatIf (#18).
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

function Invoke-GuestTask {
    <#
      Runs $Work in the guest as a one-shot scheduled task, as SYSTEM or, with
      -AsGuestUser, as the signed-in guest account, and checks on it every 30
      seconds until it writes its result. The check reconnects whenever the
      session drops. When the task stops without a result, as it does if the
      guest restarts, it is started again up to $RestartAttempts times.
      Returns what the work returned, or 'OK'; throws when it failed.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][scriptblock]$Work,
        [object[]]$ArgumentList = @(),
        [switch]$AsGuestUser,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [Parameter(Mandatory)][string]$Activity,
        [int]$RestartAttempts = 0
    )

    $setupDir = $VM.Settings.GuestSetupDir
    $userName = if ($AsGuestUser) { $VM.Runtime.GuestAdminUser } else { '' }
    $startArguments = @($TaskName, $setupDir, $Work.ToString(), $ArgumentList, $userName, ($TimeoutMinutes * 60))
    $start = {
        param($taskName, $setupDir, $work, $argumentList, $userName, $timeoutSeconds)
        Start-GuestTask -TaskName $taskName -SetupDir $setupDir -Work $work -ArgumentList $argumentList -UserName $userName -TimeoutSeconds $timeoutSeconds
    }

    $progress = @{
        BootTime = Invoke-GuestScript -VM $VM -Activity "starting $Activity" -TimeoutMinutes 5 -ArgumentList $startArguments -ScriptBlock $start
        Restarts = 0
        Failures = 0
    }

    $done = Wait-Until -Activity $Activity -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -Interval ([timespan]::FromSeconds(30)) -State $progress -Condition {
        param($p)
        try {
            $status = Invoke-GuestScript -VM $VM -Activity "checking on $Activity" -TimeoutMinutes 2 -ArgumentList @($TaskName, $setupDir) -ScriptBlock {
                param($taskName, $setupDir) Get-GuestTaskStatus -TaskName $taskName -SetupDir $setupDir
            }
            $p.Failures = 0
        }
        catch {
            # A dropped session means the guest is restarting; the next try
            # reconnects. Anything else that keeps failing is a real problem.
            if (Test-GuestSessionOpen -VM $VM) {
                $p.Failures++
                if ($p.Failures -ge 10) { throw "Could not check on $Activity in the guest: $($_.Exception.Message)" }
            }
            else {
                Remove-GuestSession -VM $VM -KeepCredential
            }
            return $null
        }

        if ($status.Done) { return $status.Done }

        if ($status.BootTime -ne $p.BootTime) {
            Write-LogEntry "  The VM restarted at $($status.BootTime) during $Activity" 'WARN'
            $p.BootTime = $status.BootTime
        }
        if ($status.TaskState -ne 'Running') {
            if ($p.Restarts -ge $RestartAttempts) { throw "$Activity stopped before finishing, $($p.Restarts + 1) time(s)" }
            $p.Restarts++
            Write-LogEntry "  $Activity stopped before finishing - starting it again (attempt $($p.Restarts + 1))" 'WARN'
            $p.BootTime = Invoke-GuestScript -VM $VM -Activity "restarting $Activity" -TimeoutMinutes 5 -ArgumentList $startArguments -ScriptBlock $start
        }
        return $null
    }

    $null = Invoke-GuestScript -VM $VM -Activity "tidying up after $Activity" -TimeoutMinutes 2 -ArgumentList @($TaskName) -ScriptBlock {
        param($taskName) Remove-GuestTask -TaskName $taskName
    }
    if ($done -like 'FAILED:*') { throw "$Activity failed in the guest: $($done.Substring(7).Trim())" }
    return $done
}

function Invoke-GuestInstaller {
    <#
      Runs a long installer in the guest without depending on the session
      staying open (see Invoke-GuestTask). If the guest restarts before the
      installer has finished, it is started again: Visual Studio and SQL
      Server setup both carry on from where they were. Returns its exit code.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMinutes = 90,
        [string]$Activity = $Name
    )

    $work = {
        param($filePath, $argumentList, $workingDirectory)
        $process = if ($argumentList) {
            Start-Process -FilePath $filePath -ArgumentList $argumentList -Wait -PassThru -WorkingDirectory $workingDirectory
        }
        else {
            Start-Process -FilePath $filePath -Wait -PassThru -WorkingDirectory $workingDirectory
        }
        return $process.ExitCode
    }
    $result = Invoke-GuestTask -VM $VM -TaskName "$script:TaskPrefix$Name" -Work $work -ArgumentList @($FilePath, ($ArgumentList -join ' '), $VM.Settings.GuestSetupDir) `
        -TimeoutMinutes $TimeoutMinutes -Activity $Activity -RestartAttempts 3
    return [int]$result
}

function Invoke-GuestScriptAsInteractiveUser {
    <#
      Runs $ScriptBlock in the signed-in guest user's desktop session, which
      a PowerShell Direct session is not. Visual Studio settings, for one, are
      per-user and need a real desktop. Autologon makes sure someone is
      signed in. The script block's values come in through $ArgumentList.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$TaskName,
        [int]$TimeoutMinutes = 20,
        [string]$Activity = 'interactive guest command'
    )

    $null = Invoke-GuestTask -VM $VM -TaskName $TaskName -Work $ScriptBlock -ArgumentList $ArgumentList -AsGuestUser `
        -TimeoutMinutes $TimeoutMinutes -Activity $Activity
}

function Copy-FromGuest {
    <# Pulls one file out of the guest. Copy-VMFile cannot do this direction. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$GuestPath,
        [Parameter(Mandatory)][string]$HostPath
    )

    $session = Restore-GuestSession -VM $VM
    if (-not $session) { throw 'No open guest session to copy from.' }
    New-Folder -Path (Split-Path -Path $HostPath -Parent)
    Copy-Item -Path $GuestPath -Destination $HostPath -FromSession $session -Force -ErrorAction Stop
}

function Copy-ToGuest {
    <# Pushes one file into the guest, creating its folder there. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$GuestPath
    )

    $null = Invoke-GuestScript -VM $VM -Activity 'preparing the destination' -TimeoutMinutes 5 -ArgumentList @((Split-Path -Path $GuestPath -Parent)) -ScriptBlock {
        param($folder) New-GuestFolder -Path $folder
    }
    Copy-Item -Path $HostPath -Destination $GuestPath -ToSession $VM.Runtime.Session -Force -ErrorAction Stop
}

function Test-InstallSucceeded {
    <# Whether an installer exit code means success: 0, or 3010/1641 (restart needed or started). Logs nothing. #>
    param($ExitCode)

    return ($null -ne $ExitCode -and [int]$ExitCode -in 0, 3010, 1641)
}

function Test-InstallExitCode {
    <# Logs an installer's exit code and returns whether it succeeded (see Test-InstallSucceeded). #>
    param(
        [Parameter(Mandatory)][string]$Product,
        $ExitCode
    )

    if ($null -eq $ExitCode) {
        Write-LogEntry "$Product - installer returned no exit code" 'WARN'
        return $false
    }
    switch ([int]$ExitCode) {
        0 { Write-LogEntry "$Product - installed (exit 0)" 'OK'; return $true }
        3010 { Write-LogEntry "$Product - installed, restart required (exit 3010)" 'OK'; return $true }
        1641 { Write-LogEntry "$Product - installed, restart started (exit 1641)" 'OK'; return $true }
        default {
            Write-LogEntry "$Product - installer exit code $ExitCode" 'ERROR'
            return $false
        }
    }
}
