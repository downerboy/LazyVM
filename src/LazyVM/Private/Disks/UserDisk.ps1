# UserDisk.ps1 - The User disk: created on the host, prepared in the guest (#137).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Documents, Desktop and Downloads are redirected to the User disk, and .ssh
# and source\repos are linked to it, so nothing personal is on the OS disk a
# rebuild replaces. A rebuild never touches the disk. Its NTFS volume is
# plain, not a Dev Drive: Defender's performance mode suits source and
# builds, not Downloads.

function Initialize-UserDataVhd {
    param([Parameter(Mandatory)][VMContext]$VM)

    Initialize-DataVhd -Path $VM.Settings.UserDiskPath -SizeGB $VM.Settings.UserDiskSizeGB -Label 'User disk'
}

function Add-UserDataDisk {
    param([Parameter(Mandatory)][VMContext]$VM)

    Add-VMDataDisk -VM $VM -Path $VM.Settings.UserDiskPath -Label 'User disk' -LocationSetting 'UserDiskScsiLocation'
}

function Install-UserDisk {
    <#
      Gives a VM that is already built its User disk and puts its personal
      folders on it: what the daily maintenance does, and what a rebuild does
      before it captures the old guest, so nothing personal is left on the
      disk it replaces.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Initialize-UserDataVhd -VM $VM
    Add-UserDataDisk -VM $VM
    $null = Open-GuestSession -VM $VM -Purpose 'put its personal folders on the User disk'
    Initialize-GuestUserDisk -VM $VM
}

function Initialize-GuestUserDisk {
    <#
      Prepares the User disk in the guest and puts the folders in
      UserDiskFolders on it, for the account LazyVM signs in with: what C:
      holds is copied there first. The disk is found by the identity VM.json
      records for it (see VMDisk.ps1), and its GPT disk GUID is recorded once
      it has one. A rebuilt guest's account gets the folders, since its SID
      is new. Throws when a folder is not on the disk afterwards.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Write-LogEntry 'Preparing the User disk inside the guest...' 'INFO'
    $settings = $VM.Settings
    $identity = Get-DataDiskIdentity -VM $VM -GuidSetting 'UserDiskGuid' -LocationSetting 'UserDiskScsiLocation' -Path $settings.UserDiskPath
    $result = Invoke-GuestScript -VM $VM -Activity 'User disk preparation' -TimeoutMinutes 60 -ArgumentList @(
        $settings.UserDiskLetter, $identity.Guid, $identity.Location, $identity.FileLocation, $script:UserDiskFolders
    ) -ScriptBlock {
        param($desiredLetter, $guid, $location, $fileLocation, $folders)
        $ErrorActionPreference = 'Stop'
        $notes = @()

        # A disk added to the running guest shows up once storage is rescanned.
        Update-HostStorageCache
        $found = Find-GuestDataDisk -Label 'User disk' -Guid $guid -Location $location -FileLocation $fileLocation
        $disk = $found.Disk
        $notes += New-GuestNote -Level INFO -Text "found the User disk (disk $($disk.Number)) by $($found.FoundBy)"
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false; $notes += New-GuestNote -Level INFO -Text 'brought the disk online' }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false; $notes += New-GuestNote -Level INFO -Text 'cleared the read-only flag' }
        $disk = Get-Disk -Number $disk.Number

        $formatted = $false
        $part = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.Type -ne 'Reserved' -and $_.Size -gt 100MB }) | Select-Object -First 1
        if (-not $part) {
            if ($disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null }
            $letter = if (Get-GuestVolumeByLetter -Letter $desiredLetter) { Get-GuestFreeLetter } else { $desiredLetter }
            if (-not $letter) { throw 'no free drive letter available for the User disk' }
            $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter
            Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'User' -Confirm:$false -Force | Out-Null
            $formatted = $true
        }
        $letter = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter)".Trim()
        if ($letter -ne $desiredLetter -and -not (Get-GuestVolumeByLetter -Letter $desiredLetter)) {
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $desiredLetter
            $letter = $desiredLetter
        }
        elseif (-not $letter) {
            $letter = Get-GuestFreeLetter
            if (-not $letter) { throw 'the User disk could not be assigned a drive letter' }
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $letter
        }
        if ($letter -ne $desiredLetter) { $notes += New-GuestNote -Level WARN -Text "using ${letter}: instead of ${desiredLetter}:" }

        $root = "${letter}:\"
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($folder in $folders) {
            $target = Join-Path $root $folder['Name']
            if ($folder['ShellFolder']) {
                Set-GuestShellFolder -Name $folder['ShellFolder'] -Aliases $folder['Aliases'] -Path $target
            }
            else {
                $note = Set-GuestFolderLink -Link (Join-Path $env:USERPROFILE $folder['Link']) -Target $target
                if ($note) { $notes += $note }
            }
            if (Grant-GuestFolderAccess -Path $target -Sid $sid) { $notes += New-GuestNote -Level INFO -Text "gave $env:USERNAME $target" }
        }

        $problems = @(Get-GuestUserFolderProblem -Folders $folders -Root $root -ProfileDir $env:USERPROFILE)
        if ($problems.Count -gt 0) { throw "the personal folders are not all on the User disk: $($problems -join '; ')" }

        $volume = Get-Volume -DriveLetter $letter
        return [pscustomobject]@{
            Letter    = $letter
            Formatted = $formatted
            Guid      = "$((Get-Disk -Number $disk.Number).Guid)"
            SizeGB    = [math]::Round($volume.Size / 1GB, 1)
            FreeGB    = [math]::Round($volume.SizeRemaining / 1GB, 1)
            Notes     = $notes
        }
    }

    Write-GuestNote -Notes $result.Notes
    Save-DataDiskGuid -VM $VM -GuidSetting 'UserDiskGuid' -Guid $result.Guid -Label 'User disk'

    $state = if ($result.Formatted) { 'formatted as' } else { 'ready at' }
    Write-LogEntry "User disk $state $($result.Letter): ($($result.FreeGB) GB free of $($result.SizeGB) GB); personal folders are on it" 'OK'
}
