# VMDisk.ps1 - Attaching extra virtual disks to a VM.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

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
