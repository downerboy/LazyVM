# BitLocker.ps1 - BitLocker on C: and on every persistent disk, unlockable after a rebuild (#175).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# C: is protected by the VM's virtual TPM. The SQL data disk, the Dev Drive
# and the User disk are each protected by a recovery password and unlock
# themselves (auto-unlock) once C: is unlocked. Auto-unlock belongs to the
# C: that turned it on, so a rebuilt guest unlocks each disk with its
# recovery password first, then turns auto-unlock on for its own C:.
#
# Each recovery password is made here and stored, encrypted, in the VM's
# credential store, keyed by the disk's GPT disk GUID, before the guest
# encrypts anything with it: the store always holds a password that works.
# Passwords for earlier OS disks are kept, so a retired OS disk can still be
# unlocked. No recovery password is ever written to VM.json, a log or an
# error message.
#
# Windows RE cannot sit on a BitLocker-encrypted C:; Expand-GuestSystemDrive
# keeps it on its own partition after C: (see GuestOSDisk.ps1).

function Get-PersistentDataDisk {
    <# The data disks that outlive a rebuild, with the VM.json settings that record their identity. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $disks = @()
    if ($settings.InstallSqlServer) {
        $disks += [pscustomobject]@{ Label = 'SQL data disk'; GuidSetting = 'SQLDiskGuid'; LocationSetting = 'SQLDiskScsiLocation'; Path = $settings.SQLDiskPath }
    }
    if ($settings.UseDevDrive) {
        $disks += [pscustomobject]@{ Label = 'Dev Drive disk'; GuidSetting = 'DevDriveGuid'; LocationSetting = 'DevDriveScsiLocation'; Path = $settings.DevDrivePath }
    }
    $disks += [pscustomobject]@{ Label = 'User disk'; GuidSetting = 'UserDiskGuid'; LocationSetting = 'UserDiskScsiLocation'; Path = $settings.UserDiskPath }
    return $disks
}

function New-BitLockerRecoveryPassword {
    <#
      A random recovery password in the form BitLocker requires: 8 groups of
      6 digits, each divisible by 11 and no more than 720885 (11 x 65535).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a value; changes nothing.')]
    [OutputType([string])]
    param()

    $groups = foreach ($i in 1..8) { '{0:D6}' -f (11 * [Security.Cryptography.RandomNumberGenerator]::GetInt32(65536)) }
    return $groups -join '-'
}

function Read-RecoveryPasswordTable {
    <# The VM's stored recovery passwords: disk GUID -> @{ Disk; RecoveryPassword; Recorded }; empty when none are stored. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][VMContext]$VM)

    return Get-StoredSecretTable -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.BitLockerCredFile
}

function Get-OrNewRecoveryPassword {
    <#
      The recovery password stored for the disk with GPT disk GUID $Guid, or,
      when none is, a new one, stored first so it is never used unstored.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Guid,
        [Parameter(Mandatory)][string]$Disk
    )

    $key = $Guid.ToUpperInvariant()
    $table = Read-RecoveryPasswordTable -VM $VM
    if ($table.ContainsKey($key) -and $table[$key]['RecoveryPassword']) { return [string]$table[$key]['RecoveryPassword'] }

    $password = New-BitLockerRecoveryPassword
    $table[$key] = @{ Disk = $Disk; RecoveryPassword = $password; Recorded = (Get-Date).ToString('o') }
    Save-StoredSecretTable -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.BitLockerCredFile -UserName 'bitlocker' -Secrets $table
    return $password
}

function Protect-GuestSystemDrive {
    <# Turns BitLocker on for C: with the TPM and a stored recovery password, or checks it has them. Throws when it cannot. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'password', Justification = 'The BitLocker cmdlets in the guest take a recovery password only as text.')]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$UsedSpaceOnly
    )

    $guid = Invoke-GuestScript -VM $VM -Activity 'OS disk identity' -TimeoutMinutes 5 -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        "$((Get-Disk -Number (Get-Partition -DriveLetter C).DiskNumber).Guid)"
    }
    if (-not $guid) { throw 'the OS disk has no GPT disk GUID to store its recovery password under' }

    $password = Get-OrNewRecoveryPassword -VM $VM -Guid $guid -Disk 'OS disk'

    # BitLocker will not use the TPM while bootable media, such as the
    # Windows ISO the build attached, is in a DVD drive (#188). The drives
    # stay: the SQL Server install mounts its ISO in one.
    foreach ($drive in @(Get-VMDvdDrive -VMName $VM.Name -ErrorAction Stop | Where-Object { $_.Path })) {
        Set-VMDvdDrive -VMName $VM.Name -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -Path $null -ErrorAction Stop
        Write-LogEntry "  ejected $($drive.Path) from the DVD drive, since BitLocker will not use the TPM while it is there" 'INFO'
    }

    $notes = Invoke-GuestScript -VM $VM -Activity 'BitLocker on C:' -TimeoutMinutes 10 -ArgumentList @($password, [bool]$UsedSpaceOnly) -ScriptBlock {
        param($password, $usedSpaceOnly)
        $ErrorActionPreference = 'Stop'
        Protect-GuestVolume -MountPoint 'C:' -RecoveryPassword $password -System -UsedSpaceOnly:$usedSpaceOnly
    }
    Write-GuestNote -Notes $notes
}

function Protect-GuestDataDisk {
    <#
      Turns BitLocker on for one persistent disk ($Disk, from
      Get-PersistentDataDisk) with a stored recovery password and
      auto-unlock, or checks it has them. A disk the guest has not prepared
      yet waits for the next run. Throws when it cannot be done; the guest
      then leaves the disk as it was.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'password', Justification = 'The BitLocker cmdlets in the guest take a recovery password only as text.')]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)]$Disk,
        [switch]$UsedSpaceOnly
    )

    $identity = Get-DataDiskIdentity -VM $VM -GuidSetting $Disk.GuidSetting -LocationSetting $Disk.LocationSetting -Path $Disk.Path
    if (-not $identity.Guid -or -not (Test-Path -LiteralPath $Disk.Path)) {
        Write-LogEntry "  $($Disk.Label): not prepared in the guest yet, so BitLocker waits for the next run" 'INFO'
        return
    }

    $password = Get-OrNewRecoveryPassword -VM $VM -Guid $identity.Guid -Disk $Disk.Label
    $notes = Invoke-GuestScript -VM $VM -Activity "BitLocker on the $($Disk.Label)" -TimeoutMinutes 10 -ArgumentList @(
        $Disk.Label, $identity.Guid, $identity.Location, $identity.FileLocation, $password, [bool]$UsedSpaceOnly
    ) -ScriptBlock {
        param($label, $guid, $location, $fileLocation, $password, $usedSpaceOnly)
        $ErrorActionPreference = 'Stop'
        $disk = (Find-GuestDataDisk -Label $label -Guid $guid -Location $location -FileLocation $fileLocation).Disk
        $mountPoint = Get-GuestVolumeMountPoint -Disk $disk
        if (-not $mountPoint) { throw "the $label holds no volume" }
        Protect-GuestVolume -MountPoint $mountPoint -RecoveryPassword $password -UsedSpaceOnly:$usedSpaceOnly
    }
    Write-GuestNote -Notes $notes
}

function Protect-GuestPersistentDisk {
    <#
      BitLocker on C:, then on each persistent disk, on every build and every
      maintenance run. -NewSystemDrive says Windows was just installed on C:,
      so only its used space needs encrypting; likewise a data disk the guest
      formatted in this run. Never throws: a disk that fails is logged and
      left as it was, and the next run tries again. The data disks wait while
      C: is not encrypted, since they could not unlock themselves.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$NewSystemDrive
    )

    Write-LogEntry 'BitLocker:' 'INFO'
    try { Protect-GuestSystemDrive -VM $VM -UsedSpaceOnly:$NewSystemDrive }
    catch {
        Write-LogError '  BitLocker could not be turned on for C:, so the data disks were left as they are' $_
        return
    }

    foreach ($disk in Get-PersistentDataDisk -VM $VM) {
        try { Protect-GuestDataDisk -VM $VM -Disk $disk -UsedSpaceOnly:($VM.Runtime.FormattedDisks -contains $disk.GuidSetting) }
        catch { Write-LogError "  BitLocker could not be turned on for the $($disk.Label); it was left as it was" $_ }
    }
}

function Unlock-GuestDataDisk {
    <#
      Unlocks each persistent disk BitLocker has locked, with its stored
      recovery password: what a rebuilt guest must do before it can use
      them. Runs before the disks are prepared on every build. Throws when a
      disk stays locked, so the build stops before anything is restored onto
      it and a rebuild keeps the old OS disk.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $table = Read-RecoveryPasswordTable -VM $VM
    $targets = @(foreach ($disk in Get-PersistentDataDisk -VM $VM) {
            $identity = Get-DataDiskIdentity -VM $VM -GuidSetting $disk.GuidSetting -LocationSetting $disk.LocationSetting -Path $disk.Path
            # A disk never prepared has never been encrypted either.
            if (-not $identity.Guid -or -not (Test-Path -LiteralPath $disk.Path)) { continue }
            $stored = $table[$identity.Guid.ToUpperInvariant()]
            @{
                Label            = $disk.Label
                Guid             = $identity.Guid
                Location         = $identity.Location
                FileLocation     = $identity.FileLocation
                RecoveryPassword = if ($stored) { [string]$stored['RecoveryPassword'] } else { '' }
            }
        })
    if ($targets.Count -eq 0) { return }

    $unlocked = Invoke-GuestScript -VM $VM -Activity 'unlocking the persistent disks' -TimeoutMinutes 10 -ArgumentList @(, $targets) -ScriptBlock {
        param($targets)
        $ErrorActionPreference = 'Stop'
        Update-HostStorageCache
        foreach ($target in $targets) {
            $disk = (Find-GuestDataDisk -Label $target.Label -Guid $target.Guid -Location $target.Location -FileLocation $target.FileLocation).Disk
            if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
            $mountPoint = Get-GuestVolumeMountPoint -Disk $disk
            if (-not $mountPoint) { continue }
            if (Unlock-GuestVolume -MountPoint $mountPoint -Label $target.Label -RecoveryPassword $target.RecoveryPassword) { $target.Label }
        }
    }
    foreach ($label in @($unlocked)) { Write-LogEntry "$label unlocked with its stored recovery password" 'OK' }
}
