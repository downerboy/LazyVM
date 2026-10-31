# UserDiskBackup.ps1 - One copy of the User disk, made when its contents change (#139).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The guest reports the files on the disk, and the copy is made only when
# their count, total size or newest write time differs from the last copy's:
# the host's VHDX timestamp changes whenever the disk is attached, so it
# cannot tell. The copy is taken at the disk level while the VM runs, from a
# checkpoint, so it is the BitLocker-encrypted disk and nothing on it is ever
# readable on the host. Restoring means swapping the copy for the VHDX.

function Get-UserDiskBackupPath {
    <#
      Where the User disk's copy goes: BackupDir when it is set, or the VM's
      Backups folder. $null, with a warning, when BackupDir is set but not
      there, such as an external disk that is not connected.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $fileName = "$($VM.Name)-User.vhdx"
    $dir = $VM.Settings.BackupDir
    if (-not $dir) { return Join-Path -Path $VM.Settings.VMRoot -ChildPath "Backups\$fileName" }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-LogEntry "BackupDir $dir is not there (is the disk connected?) - the User disk is not copied this time" 'WARN'
        return $null
    }
    return Join-Path -Path $dir -ChildPath $fileName
}

function Get-GuestUserDiskSnapshot {
    <#
      What the guest sees on the User disk: how many files, their total size
      and the newest write time, and whether BitLocker has encrypted all of it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $identity = Get-DataDiskIdentity -VM $VM -GuidSetting 'UserDiskGuid' -LocationSetting 'UserDiskScsiLocation' -Path $VM.Settings.UserDiskPath
    return Invoke-GuestScript -VM $VM -Activity 'User disk change check' -TimeoutMinutes 30 -ArgumentList @(
        $identity.Guid, $identity.Location, $identity.FileLocation
    ) -ScriptBlock {
        param($guid, $location, $fileLocation)
        $ErrorActionPreference = 'Stop'

        $found = Find-GuestDataDisk -Label 'User disk' -Guid $guid -Location $location -FileLocation $fileLocation
        $part = @(Get-Partition -DiskNumber $found.Disk.Number | Where-Object { [char]::IsLetter($_.DriveLetter) }) | Select-Object -First 1
        if (-not $part) { throw 'the User disk has no drive letter' }
        $letter = "$($part.DriveLetter)"

        # Measure-Object in Windows PowerShell cannot take the newest of dates.
        $count = 0
        [long]$bytes = 0
        $newest = [datetime]::MinValue
        foreach ($file in Get-ChildItem -LiteralPath "${letter}:\" -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $count++
            $bytes += $file.Length
            if ($file.LastWriteTimeUtc -gt $newest) { $newest = $file.LastWriteTimeUtc }
        }
        $bitLocker = Get-BitLockerVolume -MountPoint "${letter}:" -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Files       = $count
            Bytes       = $bytes
            NewestWrite = if ($count -gt 0) { $newest.ToString('o') } else { '' }
            Encrypted   = [bool]($bitLocker -and "$($bitLocker.VolumeStatus)" -eq 'FullyEncrypted')
        }
    }
}

function ConvertTo-UserDiskFingerprint {
    <# The User disk's fingerprint from what the guest reported, as the text its copy's record keeps. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Snapshot)

    return ([ordered]@{
            Files       = [int]$Snapshot.Files
            Bytes       = [long]$Snapshot.Bytes
            NewestWrite = [string]$Snapshot.NewestWrite
        } | ConvertTo-Json -Compress)
}

function Copy-UserDiskVhd {
    <#
      Copies the User disk to $Destination while the VM runs: a checkpoint
      makes the disk as it is now read-only, Convert-VHD copies it, through
      any older checkpoints it differences from, into one disk that stands
      on its own, and the checkpoint is merged again. The last copy is
      replaced only by a complete one. Throws when the copy fails.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Destination
    )

    $userDisk = $VM.Settings.UserDiskPath
    $name = "$script:UserDiskBackupCheckpointPrefix $(Get-Stamp)"
    New-ToolingCheckpoint -VM $VM -Name $name -SkipPrune
    # Convert-VHD reads the format from the extension, so the partial copy keeps .vhdx.
    $partial = [IO.Path]::ChangeExtension($Destination, '.new.vhdx')
    try {
        $drive = Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction Stop |
            Where-Object { $_.Path -and (Get-DiskChain -Path $_.Path) -contains $userDisk } | Select-Object -First 1
        if (-not $drive) { throw "The User disk $userDisk is not attached to '$($VM.Name)'." }
        $frozen = (Get-VHD -Path $drive.Path -ErrorAction Stop).ParentPath
        if (-not $frozen) { throw "The checkpoint '$name' did not make the User disk read-only." }

        New-Folder -Path (Split-Path -Path $Destination -Parent)
        Convert-VHD -Path $frozen -DestinationPath $partial -VHDType Dynamic -ErrorAction Stop
        Move-Item -LiteralPath $partial -Destination $Destination -Force
    }
    catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        try { Remove-VMSnapshot -VMName $VM.Name -Name $name -Confirm:$false -ErrorAction Stop }
        catch { Write-LogEntry "Could not remove the checkpoint '$name': $($_.Exception.Message). Delete it in Hyper-V Manager." 'WARN' }
    }
}

function Backup-UserDisk {
    <#
      The daily maintenance's copy of the User disk: one copy, made only when
      the files on it changed, and only once BitLocker has encrypted all of
      it. Warns when the files come close to filling the disk.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $userDisk = $VM.Settings.UserDiskPath
    if (-not (Test-Path -LiteralPath $userDisk)) {
        Write-LogEntry 'No User disk yet - nothing to copy' 'INFO'
        return
    }
    $destination = Get-UserDiskBackupPath -VM $VM
    if (-not $destination) { return }

    $snapshot = Get-GuestUserDiskSnapshot -VM $VM
    $sizeGB = [int]$VM.Settings.UserDiskSizeGB
    if ([double]$snapshot.Bytes -gt $script:UserDiskLargeShare * $sizeGB * 1GB) {
        Write-LogEntry "The User disk holds $(Format-Size ([double]$snapshot.Bytes)) of files, close to its $sizeGB GB; Downloads is often why, and every copy takes longer" 'WARN'
    }
    if (-not $snapshot.Encrypted) {
        Write-LogEntry 'The User disk is copied once BitLocker has encrypted all of it, so no copy ever holds readable files' 'WARN'
        return
    }

    $fingerprint = ConvertTo-UserDiskFingerprint -Snapshot $snapshot
    $recordPath = "$destination.json"
    $recorded = if (Test-Path -LiteralPath $recordPath) { (Get-Content -LiteralPath $recordPath -Raw).Trim() } else { '' }
    if ((Test-Path -LiteralPath $destination) -and $recorded -eq $fingerprint) {
        Write-LogEntry "User disk unchanged since its copy at $destination" 'OK'
        return
    }

    Write-LogEntry "Copying the User disk to $destination..." 'INFO'
    Copy-UserDiskVhd -VM $VM -Destination $destination
    Set-Content -LiteralPath $recordPath -Value $fingerprint -Encoding utf8
    Write-LogEntry "User disk copied, still encrypted, to $destination; to restore it, swap it for $userDisk while the VM is off" 'OK'
}
