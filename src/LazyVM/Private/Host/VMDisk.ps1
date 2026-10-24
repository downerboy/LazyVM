# VMDisk.ps1 - The VM's extra virtual disks: creating them and attaching them.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The SQL data disk and the Dev Drive carry data across rebuilds, so an
# existing disk is always kept and reported, never created again.

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

    Add-VMHardDiskDrive -VMName $VMName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $location -Path $Path
    return $location
}

function Add-VMDataDisk {
    <# Attaches the disk at $Path to the VM unless it already is, and gives the guest a moment to see it. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (@(Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Path }).Count -gt 0) {
        Write-LogEntry "$Label already attached" 'OK'
        return
    }
    $location = Add-VMScsiHardDisk -VMName $VM.Name -Path $Path
    Write-LogEntry "$Label attached (SCSI 0:$location)" 'OK'
    Start-Sleep -Seconds 5
}
