# Checkpoint.ps1 - The Hyper-V checkpoints paired with each recorded tooling version.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The newest ToolingCheckpointsToKeep tooling checkpoints are kept: the VM's
# restore points (Get-LazyVMRestorePoint, Restore-LazyVMTooling).

function Get-ToolingStamp {
    <#
      A date-time no existing tooling checkpoint or kept version of VM.json
      uses. Two checkpoints in the same second would otherwise share a name,
      or a checkpoint the version of VM.json of another, and a revert would
      pick the wrong one.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $existing = @(Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    while ($true) {
        $stamp = Get-Stamp
        $name = "$script:ToolingCheckpointPrefix $stamp"
        $versionKept = Test-Path -LiteralPath (Get-ProfileVersionPath -Root $VM.Settings.Root -Name $VM.Name -Stamp $stamp)
        if (-not $versionKept -and -not ($existing | Where-Object { $_ -eq $name -or $_ -like "$name *" })) { return $stamp }
        Start-Sleep -Seconds 1
    }
}

function Get-ToolingCheckpointStamp {
    <#
      The date-times of a VM's tooling checkpoints: the versions of VM.json
      its restore points need. None for a VM Hyper-V does not have yet; $null
      when Hyper-V cannot be asked, so that nothing they need is removed.
    #>
    param([Parameter(Mandatory)][string]$Name)

    try {
        $machine = Get-VM -Name $Name -ErrorAction Stop
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        return $null
    }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return , [string[]]@() }
        return $null
    }

    try {
        $checkpoints = @(Get-VMSnapshot -VM $machine -ErrorAction Stop | Where-Object { $_.Name -like "$script:ToolingCheckpointPrefix *" })
    }
    catch {
        return $null
    }
    return , [string[]]@($checkpoints | ForEach-Object { Get-CheckpointStamp -Name $_.Name })
}

function Get-ToolingCheckpoint {
    <# This VM's tooling checkpoints, oldest first. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return @(Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$script:ToolingCheckpointPrefix *" } | Sort-Object CreationTime)
}

function Get-CheckpointStamp {
    <# The date-time in a checkpoint's name: 'Tooling 20261008-193000 before revert' -> '20261008-193000'. #>
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -split ' ', 3)[1]
}

function Enable-ToolingCheckpoint {
    <#
      Tooling tracking needs checkpoints. A VM set up by hand can have them
      switched off entirely; this turns on production checkpoints (consistent,
      using the guest's Volume Shadow Copy, falling back to a standard
      checkpoint when that is unavailable). While the VM has no checkpoints,
      it also stores them in CheckpointDir, as a VM LazyVM builds does:
      Hyper-V allows that change only then. Automatic checkpoints stay off.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $machine = Get-VM -Name $VM.Name -ErrorAction Stop
    if ("$($machine.CheckpointType)" -eq 'Disabled') {
        Write-LogEntry "Checkpoints are switched off for '$($VM.Name)' - turning on production checkpoints, which tooling tracking needs" 'INFO'
        Set-VM -Name $VM.Name -CheckpointType Production -ErrorAction Stop
    }

    # A checkpoint creates a differencing disk (.avhdx) beside each of the
    # VM's disks, as the VM's own account. Folders made outside Hyper-V's
    # defaults do not let it create files, which fails with "Access is
    # denied" (0x80070005). Microsoft's fix is to grant the VM's account on
    # the folder: here on each folder holding this VM's disks, and on the
    # folder only, not on the other VMs' files inside it.
    $account = "NT VIRTUAL MACHINE\$("$($machine.Id)".ToUpperInvariant())"
    $folders = @(Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } | ForEach-Object { Split-Path -Path $_.Path -Parent } | Sort-Object -Unique)
    foreach ($folder in $folders) {
        if (@((Get-Acl -LiteralPath $folder).Access | Where-Object { "$($_.IdentityReference)" -eq $account }).Count -gt 0) { continue }
        $output = & icacls.exe $folder /grant "${account}:(F)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not grant the VM access to $folder for checkpoints: $output" }
        Write-LogEntry "Gave '$($VM.Name)' access to $folder, so checkpoints can be created there" 'INFO'
    }

    $checkpointDir = $VM.Settings.CheckpointDir
    $hasCheckpoints = @(Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasCheckpoints -and "$($machine.SnapshotFileLocation)".TrimEnd('\') -ne $checkpointDir.TrimEnd('\')) {
        New-Folder -Path $checkpointDir
        Set-VM -Name $VM.Name -SnapshotFileLocation $checkpointDir -ErrorAction Stop
        Write-LogEntry "Checkpoints for '$($VM.Name)' are stored in $checkpointDir" 'INFO'
    }
}

function New-ToolingCheckpoint {
    <#
      Takes a checkpoint, then removes the oldest tooling checkpoints beyond
      ToolingCheckpointsToKeep. Throws if the checkpoint cannot be taken, so
      the caller records nothing without one.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Name,

        # A revert's safety checkpoint must not prune: the oldest checkpoint
        # could be the very one being reverted to.
        [switch]$SkipPrune
    )

    Enable-ToolingCheckpoint -VM $VM
    Checkpoint-VM -Name $VM.Name -SnapshotName $Name -ErrorAction Stop
    Write-LogEntry "Checkpoint taken: '$Name'" 'OK'
    if ($SkipPrune) { return }

    $tooling = Get-ToolingCheckpoint -VM $VM
    $surplus = $tooling.Count - [int]$VM.Settings.ToolingCheckpointsToKeep
    foreach ($old in @($tooling | Select-Object -First ([math]::Max($surplus, 0)))) {
        try {
            Remove-VMSnapshot -VMSnapshot $old -Confirm:$false -ErrorAction Stop
            Write-LogEntry "  removed the older checkpoint '$($old.Name)'" 'INFO'
        }
        catch { Write-LogEntry "  could not remove the checkpoint '$($old.Name)': $($_.Exception.Message)" 'WARN' }
    }
}

function Get-ToolingRestorePoint {
    <# Get-LazyVMRestorePoint: the tooling versions that still have their checkpoint, oldest first. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    foreach ($checkpoint in Get-ToolingCheckpoint -VM $VM) {
        $stamp = Get-CheckpointStamp -Name $checkpoint.Name
        $hasList = $true
        try { $null = Get-ProfileTooling -VM $VM -Stamp $stamp }
        catch { $hasList = $false }
        [pscustomobject]@{
            PSTypeName     = 'LazyVM.RestorePoint'
            Name           = $VM.Name
            RestorePoint   = $stamp
            Taken          = $checkpoint.CreationTime
            Checkpoint     = $checkpoint.Name
            HasToolingList = $hasList
        }
    }
}

function Invoke-ToolingRevert {
    <#
      Restore-LazyVMTooling: returns the VM to a recorded tooling version by
      applying its checkpoint and restoring the matching tooling list. A
      checkpoint of the current state is taken first, so the revert itself
      can be undone.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Stamp
    )

    Write-LogEntry "Revert - $($VM.Name) to tooling version $Stamp" 'PHASE'

    $checkpoint = Get-ToolingCheckpoint -VM $VM | Where-Object { (Get-CheckpointStamp -Name $_.Name) -eq $Stamp } | Select-Object -First 1
    if (-not $checkpoint) { throw "There is no checkpoint '$script:ToolingCheckpointPrefix $Stamp'. See them with: Get-LazyVMRestorePoint -Name $($VM.Name)" }
    # Checked before anything changes.
    $null = Get-ProfileTooling -VM $VM -Stamp $Stamp

    # The current state, as an ordinary tooling version, so the revert can be
    # reverted: a checkpoint, and VM.json as it is now kept under its date-time.
    $now = Get-ToolingStamp -VM $VM
    New-ToolingCheckpoint -VM $VM -Name "$script:ToolingCheckpointPrefix $now before revert" -SkipPrune
    $profilePath = Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name
    $null = Save-ProfileVersion -Root $VM.Settings.Root -Name $VM.Name -Text ([IO.File]::ReadAllText($profilePath)) -Stamp $now

    $wasRunning = ((Get-VM -Name $VM.Name).State -eq 'Running')
    Remove-GuestSession -VM $VM
    Restore-VMSnapshot -VMSnapshot $checkpoint -Confirm:$false -ErrorAction Stop
    Restore-ProfileTooling -VM $VM -Stamp $Stamp
    Write-LogEntry "VM returned to '$($checkpoint.Name)' and its tooling list restored" 'OK'
    Write-LogEntry "  To undo this revert: Restore-LazyVMTooling -Name $($VM.Name) -RestorePoint $now" 'INFO'

    if ($wasRunning -and (Get-VM -Name $VM.Name).State -ne 'Running') {
        Start-VM -Name $VM.Name | Out-Null
        Write-LogEntry 'VM started' 'INFO'
    }
}
