# VMDisk.ps1 - The VM's extra virtual disks: creating them and attaching them.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The SQL data disk, the Dev Drive and the User disk carry data across rebuilds, so an
# existing disk is always kept and reported, never created again.
#
# The guest finds each one by the identity VM.json records for it, never by
# its size, because the guest step initialises and formats what it finds:
#   1. its GPT disk GUID, written back once the guest has prepared the disk;
#   2. the SCSI location the host attached it at, which finds a new, empty disk;
#   3. only as a last resort, the location Hyper-V shows for its VHDX file now.
# When none of them matches a disk, the run stops rather than guess.

# The VM.json settings that record which disk is which. They belong to one
# VM, so a VM copied with -From never takes them.
$script:DataDiskIdentitySettings = @(
    'SQLDiskGuid'
    'SQLDiskScsiLocation'
    'DevDriveGuid'
    'DevDriveScsiLocation'
    'UserDiskGuid'
    'UserDiskScsiLocation'
)

function Initialize-DataVhd {
    <# Creates a dynamic VHDX of $SizeGB at $Path, or reports the one already there. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$SizeGB,
        [Parameter(Mandatory)][string]$Label
    )

    if (Test-Path -LiteralPath $Path) {
        # The file's length is what the dynamic disk has allocated so far, not
        # its capacity, so both are reported.
        $onDisk = Format-Size (Get-Item -LiteralPath $Path).Length
        try {
            $vhd = Get-VHD -Path $Path
            Write-LogEntry "$Label exists - capacity $(Format-Size $vhd.Size), currently allocated $onDisk, type $($vhd.VhdType)" 'OK'
            if ($vhd.Size -lt ($SizeGB * 1GB)) {
                Write-LogEntry "  Its capacity is smaller than the configured $SizeGB GB. Expand it with Resize-VHD if needed." 'WARN'
            }
        }
        catch {
            Write-LogEntry "$Label exists ($onDisk on disk) - could not read its details: $($_.Exception.Message)" 'WARN'
        }
        Write-LogEntry "  Existing $Label contents kept" 'INFO'
        return
    }

    New-Folder -Path (Split-Path -Path $Path -Parent)
    Write-LogEntry "Creating the $SizeGB GB dynamic $Label..." 'INFO'
    New-VHD -Path $Path -SizeBytes ([long]$SizeGB * 1GB) -Dynamic | Out-Null
    Write-LogEntry "$Label created at $Path" 'OK'
}

function Get-FreeControllerLocation {
    <#
      The lowest free location on a SCSI controller (0-63), given the
      locations already in use. $null when the controller is full.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Used)

    foreach ($location in 0..63) {
        if ($location -notin $Used) { return $location }
    }
    return $null
}

function Add-VMScsiHardDisk {
    <#
      Attaches a disk on SCSI controller 0 at an explicit free location.
      Left to choose a location itself, Add-VMHardDiskDrive fails with
      "Unable to cast DvdDrive to HardDiskDrive" once a DVD drive has been
      removed and left a gap, which is exactly what the build does when it
      ejects the answer-file disc.

      Given the location of the removed DVD drive, it throws that same error,
      but only after the disk is attached: it fails while describing the
      result. So when it throws, what Hyper-V actually did decides: a disk
      attached where it was asked for is a success.
    #>
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Path
    )

    $used = @(
        @(Get-VMHardDiskDrive -VMName $VMName) + @(Get-VMDvdDrive -VMName $VMName) |
            Where-Object { "$($_.ControllerType)" -eq 'SCSI' -and $_.ControllerNumber -eq 0 } |
            ForEach-Object { [int]$_.ControllerLocation }
    )
    $location = Get-FreeControllerLocation -Used $used
    if ($null -eq $location) {
        throw "The VM's SCSI controller has no free location for $Path."
    }

    try {
        Add-VMHardDiskDrive -VMName $VMName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $location -Path $Path -ErrorAction Stop
    }
    catch {
        $attached = @(Get-VMHardDiskDrive -VMName $VMName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $location -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $Path })
        if ($attached.Count -eq 0) { throw }
        Write-Verbose "Add-VMHardDiskDrive reported '$($_.Exception.Message)', but $Path is attached at SCSI 0:$location."
    }
    return $location
}

function Get-VhdDiskGuid {
    <#
      The GPT disk GUID inside the VHDX at $Path, read on the host by
      mounting it read-only without a drive letter, then dismounting it.
      $null for a disk not initialised yet. Throws when it cannot be read.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $vhd = Mount-VHD -Path $Path -ReadOnly -NoDriveLetter -Passthru -ErrorAction Stop
    try {
        $guid = "$((Get-Disk -Number $vhd.DiskNumber -ErrorAction Stop).Guid)"
    }
    finally {
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
    }
    if (-not $guid) { return $null }
    return $guid.ToUpperInvariant()
}

function Assert-DataDiskNotOwnedElsewhere {
    <#
      Throws when another VM's VM.json records the GPT disk GUID of the disk
      at $Path, so one VM's data never reaches another (#138). A rebuild
      keeps the VM's own VM.json, so its replacement owns the disks already.
      Fails closed: a GUID that cannot be read, or a VM.json that cannot be
      read, stops the attach too.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    try { $guid = Get-VhdDiskGuid -Path $Path }
    catch { throw "Could not read the GPT disk GUID of the $Label at $Path to check that no other VM owns it, so it was not attached: $($_.Exception.Message)" }
    if (-not $guid) { return }

    $root = $VM.Settings.Root
    $guidSettings = @($script:DataDiskIdentitySettings | Where-Object { $_ -like '*Guid' })
    foreach ($other in @(Get-VMProfileName -Root $root | Where-Object { $_ -ne $VM.Name })) {
        $recorded = Read-SettingsFile -Path (Get-VMProfilePath -Root $root -Name $other)
        foreach ($setting in $guidSettings) {
            if ("$($recorded[$setting])" -eq $guid) {
                throw "The $Label at $Path belongs to the VM '$other' (its VM.json records GPT disk GUID $guid as its $setting), so it was not attached to '$($VM.Name)'. Each VM's disks stay its own: point $($VM.Name)'s setting at a disk of its own."
            }
        }
    }
}

function Add-VMDataDisk {
    <#
      Attaches the disk at $Path to the VM unless it already is, records the
      SCSI location it got in VM.json as $LocationSetting, and gives the guest
      a moment to see it.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$LocationSetting
    )

    # After a checkpoint the VM holds the disk through a differencing disk
    # (.avhdx) whose chain leads back to $Path (#191).
    if (@(Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction SilentlyContinue | Where-Object { $_.Path -and (Get-DiskChain -Path $_.Path) -contains $Path }).Count -gt 0) {
        Write-LogEntry "$Label already attached" 'OK'
        return
    }
    Assert-DataDiskNotOwnedElsewhere -VM $VM -Path $Path -Label $Label
    $location = Add-VMScsiHardDisk -VMName $VM.Name -Path $Path
    Write-LogEntry "$Label attached (SCSI 0:$location)" 'OK'
    $null = Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change @{ $LocationSetting = $location } -Reason "$Label attached"
    Start-Sleep -Seconds 5
}

function Get-DataDiskIdentity {
    <#
      What the guest needs to find a data disk: the GPT disk GUID and SCSI
      location VM.json records for it and, as the last resort, the location
      Hyper-V shows for the VHDX file at $Path now. VM.json is read afresh
      because this run may have just recorded the location, which the
      settings it loaded at the start do not have.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$GuidSetting,
        [Parameter(Mandatory)][string]$LocationSetting,
        [Parameter(Mandatory)][string]$Path
    )

    $profilePath = Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name
    $recorded = (Import-SettingsFile -Path $profilePath -Unattended:(Test-Unattended)).Values

    # LazyVM attaches data disks to SCSI controller 0 only, and the guest
    # sees a location as a LUN without its controller, so a file found on
    # another controller is no use.
    $drive = Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $Path -and "$($_.ControllerType)" -eq 'SCSI' -and $_.ControllerNumber -eq 0 } |
        Select-Object -First 1

    return [pscustomobject]@{
        Guid         = $recorded[$GuidSetting]
        Location     = $recorded[$LocationSetting]
        FileLocation = if ($drive) { [int]$drive.ControllerLocation } else { $null }
    }
}

function Save-DataDiskGuid {
    <# Records the GPT disk GUID the guest reported for a data disk in VM.json as $GuidSetting. Nothing to record for a disk without one. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$GuidSetting,
        [AllowEmptyString()][AllowNull()][string]$Guid,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not $Guid) { return }
    $null = Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change @{ $GuidSetting = $Guid.ToUpperInvariant() } -Reason "$Label prepared in the guest"
}
