# GuestScript.ps1 - Running work in the guest and moving files in and out.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Short work runs over the session as a job, so it can be given a real
# timeout instead of blocking forever. Long work, and work that needs the
# signed-in user's desktop, runs as a one-shot scheduled task in the guest
# (Start-GuestTask in Guest.Helpers.ps1) that the host checks on.

function Invoke-GuestScript {
    <#
      Runs a script block in the guest with a timeout. Throws on failure, so
      an error is never taken for success. With -RetryOnDisconnect, a script
      whose session the guest dropped under it (a restart, the guest's
      session host ending), so the session is no longer open after the
      failure, is run once more over a new session (#276). Only
      calls whose work is safe to run twice pass it: ones that only read, or
      set the same values again. A dropped session says nothing about how
      far the script got, so anything else is never repeated.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutMinutes = 15,
        [string]$Activity = 'guest command',
        [switch]$RetryOnDisconnect
    )

    $run = @{ VM = $VM; ScriptBlock = $ScriptBlock; ArgumentList = $ArgumentList; TimeoutMinutes = $TimeoutMinutes; Activity = $Activity }
    try { return Invoke-GuestScriptJob @run }
    catch {
        if (-not $RetryOnDisconnect -or (Test-GuestSessionOpen -VM $VM)) { throw }
        Write-LogEntry "  The guest dropped the session during $Activity ($($_.Exception.Message)) - reconnecting and running it once more" 'WARN'
        return Invoke-GuestScriptJob @run
    }
}

function Invoke-GuestScriptJob {
    <# Runs a script block once over the session (reopened when the guest dropped it), as a job with a timeout. Throws on failure. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [Parameter(Mandatory)][string]$Activity
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
            # The guest's own error, so its type and message are kept.
            if ($job.ChildJobs -and $job.ChildJobs[0].JobStateInfo.Reason) { throw $job.ChildJobs[0].JobStateInfo.Reason }
            throw "$Activity failed in guest: unknown error"
        }
        return $result
    }
    finally {
        # LazyVM's own job, so it is removed even under -WhatIf (#18).
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

function Invoke-GuestCheck {
    <#
      Runs a short, self-contained script block in the guest as a one-off
      PowerShell Direct call, not over the kept session: a guest that is
      restarting fails it at once, where the session would wait up to 15
      minutes to reconnect. For the checks of a bounded wait, which must not
      run past their deadline (#276). The guest helpers are not loaded. Throws
      when the guest cannot be asked.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    return Invoke-Command -VMName $VM.Name -Credential $Credential -ScriptBlock $ScriptBlock -ErrorAction Stop
}

function ConvertTo-GuestTaskArgument {
    <#
      The arguments for a guest task, with each string made a plain string.
      A string that came back from the guest carries the properties remoting
      adds (PSComputerName and the rest), and Start-GuestTask writes the
      arguments as JSON in the guest's Windows PowerShell 5.1, which writes
      such a string as an object: the task then got @{value=...} instead of
      the string. Anything else is passed on as it is, arrays included.
    #>
    param([object[]]$ArgumentList = @())

    $plain = [System.Collections.Generic.List[object]]::new()
    foreach ($argument in $ArgumentList) {
        if ($argument -is [string]) { $plain.Add([string]$argument) } else { $plain.Add($argument) }
    }
    return , $plain.ToArray()
}

function Invoke-GuestTask {
    <#
      Runs $Work in the guest as a one-shot scheduled task, as SYSTEM or, with
      -AsGuestUser, as the signed-in guest account (with -Elevated, under its
      full administrator token), and checks on it every 30
      seconds until it writes its result. The check reconnects whenever the
      session drops. When the task stops without a result, as it does if the
      guest restarts, it is started again up to $RestartAttempts times.
      Returns what the work returned, or 'OK'; throws when it failed.

      The work runs in the task's own folder in the guest
      (Initialize-GuestTaskFolder in Guest.Helpers.ps1), and finds it in
      $TaskFolder: the files in $InputFile (name = host path) are copied
      there first, where only administrators can change them. It may write
      in $TaskOutput. A task under the guest account's limited token can
      change what is in $TaskOutput, its result included, so what it reports
      is only that account's word.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][scriptblock]$Work,
        [object[]]$ArgumentList = @(),
        [System.Collections.IDictionary]$InputFile = @{},
        [switch]$AsGuestUser,
        [switch]$Elevated,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [Parameter(Mandatory)][string]$Activity,
        [int]$RestartAttempts = 0
    )

    $userName = if ($AsGuestUser) { $VM.Runtime.GuestAdminUser } else { '' }
    if ($InputFile.Count -gt 0) {
        $folder = Invoke-GuestScript -VM $VM -Activity "preparing the files of $Activity" -TimeoutMinutes 5 -ArgumentList @($TaskName, $userName, [bool]$Elevated) -ScriptBlock {
            param($taskName, $userName, $elevated) Initialize-GuestTaskFolder -TaskName $taskName -UserName $userName -Elevated:$elevated
        }
        foreach ($name in $InputFile.Keys) { Copy-ToGuest -VM $VM -HostPath $InputFile[$name] -GuestPath (Join-Path $folder $name) }
    }

    # One for this run of the task, restarts included: a result written for
    # an earlier run is not taken for this one.
    $nonce = [guid]::NewGuid().ToString('N')
    $startArguments = @($TaskName, $nonce, $Work.ToString(), (ConvertTo-GuestTaskArgument -ArgumentList $ArgumentList), $userName, [bool]$Elevated, ($TimeoutMinutes * 60))
    $start = {
        param($taskName, $nonce, $work, $argumentList, $userName, $elevated, $timeoutSeconds)
        Start-GuestTask -TaskName $taskName -Nonce $nonce -Work $work -ArgumentList $argumentList -UserName $userName -Elevated:$elevated -TimeoutSeconds $timeoutSeconds
    }

    $progress = @{
        BootTime = Invoke-GuestScript -VM $VM -Activity "starting $Activity" -TimeoutMinutes 5 -ArgumentList $startArguments -ScriptBlock $start
        Restarts = 0
        Failures = 0
    }

    # Removed however the wait ends, so a task that timed out does not stay
    # registered in the guest (#227).
    try {
        $done = Wait-Until -Activity $Activity -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -Interval ([timespan]::FromSeconds(30)) -State $progress -Condition {
            param($p)
            try {
                $status = Invoke-GuestScript -VM $VM -Activity "checking on $Activity" -TimeoutMinutes 2 -ArgumentList @($TaskName, $nonce) -ScriptBlock {
                    param($taskName, $nonce) Get-GuestTaskStatus -TaskName $taskName -Nonce $nonce
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
    }
    finally {
        try {
            $null = Invoke-GuestScript -VM $VM -Activity "tidying up after $Activity" -TimeoutMinutes 2 -ArgumentList @($TaskName) -ScriptBlock {
                param($taskName) Remove-GuestTask -TaskName $taskName
            }
        }
        catch {
            Write-LogEntry "  Could not remove the guest task $TaskName after ${Activity}: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($done -like 'FAILED:*') { throw "$Activity failed in the guest: $($done.Substring(7).Trim())" }
    return $done
}

# The default of the setting GuestSetupDir, which LazyVM no longer uses (#302).
$script:LegacyGuestSetupDir = 'C:\LazyVMSetup'

function Get-GuestStagingFolder {
    <#
      Where LazyVM stages what it copies in and out of the guest:
      %ProgramFiles%\LazyVM\Staging, which only administrators and SYSTEM can
      change or read. Not only a read: a run's first call makes the folder
      ready in the guest (Initialize-GuestStagingFolder in Guest.Helpers.ps1)
      and keeps its path in Runtime; later calls return that. The only way
      to the path. A staging folder that was not right is moved aside and
      made again, and the log says so. The settings' GuestSetupDir is no
      longer used, which the log says once when it names another folder.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][VMContext]$VM)

    if ($VM.Runtime.GuestStagingFolder) { return $VM.Runtime.GuestStagingFolder }

    if ($VM.Settings.ContainsKey('GuestSetupDir') -and "$($VM.Settings['GuestSetupDir'])" -ne $script:LegacyGuestSetupDir) {
        Write-LogEntry "  GuestSetupDir ($($VM.Settings['GuestSetupDir'])) is no longer used: LazyVM stages files in %ProgramFiles%\LazyVM\Staging in the guest, so it can be taken out of the settings" 'INFO'
    }
    $staging = Invoke-GuestScript -VM $VM -Activity 'preparing the staging folder' -TimeoutMinutes 5 -ScriptBlock { Initialize-GuestStagingFolder }
    if ($staging.Replaced) {
        Write-LogEntry "  The guest's staging folder $($staging.Path) was not private ($($staging.Reason)), so it was moved aside to $($staging.MovedTo) and made again" 'INFO'
    }
    $VM.Runtime.GuestStagingFolder = "$($staging.Path)"
    return $VM.Runtime.GuestStagingFolder
}

function Invoke-GuestInstaller {
    <#
      Runs a long installer in the guest without depending on the session
      staying open (see Invoke-GuestTask), as the task LazyVM-$Name. Files
      it is given go in the staging folder (Get-GuestStagingFolder). If the
      guest restarts before the installer has finished, it is started again:
      Visual Studio and SQL Server setup both carry on from where they were.
      Returns its exit code.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMinutes = 90,
        [string]$Activity = $Name
    )

    # Started in the task's own folder, where the task runs.
    $work = {
        param($filePath, $argumentList)
        $process = if ($argumentList) {
            Start-Process -FilePath $filePath -ArgumentList $argumentList -Wait -PassThru
        }
        else {
            Start-Process -FilePath $filePath -Wait -PassThru
        }
        return $process.ExitCode
    }
    $result = Invoke-GuestTask -VM $VM -TaskName "$script:TaskPrefix$Name" -Work $work -ArgumentList @($FilePath, ($ArgumentList -join ' ')) `
        -TimeoutMinutes $TimeoutMinutes -Activity $Activity -RestartAttempts 3
    return [int]$result
}

function Invoke-GuestScriptAsInteractiveUser {
    <#
      Runs $ScriptBlock in the signed-in guest user's desktop session, which
      a PowerShell Direct session is not. Visual Studio settings, for one, are
      per-user and need a real desktop. Autologon makes sure someone is
      signed in. The script block's values come in through $ArgumentList,
      and the files in $InputFile in $TaskFolder (see Invoke-GuestTask).
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [System.Collections.IDictionary]$InputFile = @{},
        [Parameter(Mandatory)][string]$TaskName,
        [int]$TimeoutMinutes = 20,
        [string]$Activity = 'interactive guest command'
    )

    $null = Invoke-GuestTask -VM $VM -TaskName $TaskName -Work $ScriptBlock -ArgumentList $ArgumentList -InputFile $InputFile -AsGuestUser `
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

function Receive-GuestTaskOutputFile {
    <#
      Reads the file $Name that guest task $TaskName wrote in its Output
      folder, of at most $MaximumBytes, and writes it to $Destination. The
      guest checks and reads it on one handle, never through a link
      (Read-GuestTaskOutputFile in Guest.Helpers.ps1), and gives it back as
      base64. Throws when it cannot.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][long]$MaximumBytes,
        [Parameter(Mandatory)][string]$Destination
    )

    $read = @(Invoke-GuestScript -VM $VM -Activity "reading $Name" -TimeoutMinutes 5 -ArgumentList @($TaskName, $Name, $MaximumBytes) -ScriptBlock {
            param($taskName, $name, $maximumBytes)
            [Convert]::ToBase64String((Read-GuestTaskOutputFile -TaskName $taskName -Name $name -MaximumBytes $maximumBytes))
        })
    if ($read.Count -ne 1 -or $read[0] -isnot [string]) { throw "the guest did not give $Name back as one piece of text" }
    New-Folder -Path (Split-Path -Path $Destination -Parent)
    Assert-NoReparsePoint -Path $Destination
    [IO.File]::WriteAllBytes($Destination, [Convert]::FromBase64String($read[0]))
}

function Copy-ToGuest {
    <#
      Pushes one file into a folder the guest already has: the staging folder
      (Get-GuestStagingFolder) or a task's own (Invoke-GuestTask -InputFile).
      It makes no folder, so nothing lands in a place other users can change.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$GuestPath
    )

    $session = Restore-GuestSession -VM $VM
    if (-not $session) { throw 'No open guest session to copy to.' }
    Copy-Item -Path $HostPath -Destination $GuestPath -ToSession $session -Force -ErrorAction Stop
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
