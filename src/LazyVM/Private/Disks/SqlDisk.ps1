# SqlDisk.ps1 - The SQL data disk: created on the host, prepared in the guest.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The disk keeps the databases and their backups across rebuilds; a rebuild
# never touches it.

function Initialize-SqlDataVhd {
    param([Parameter(Mandatory)][VMContext]$VM)

    Initialize-DataVhd -Path $VM.Settings.SQLDiskPath -SizeGB $VM.Settings.SQLDiskSizeGB -Label 'SQL data disk'
}

function Add-SqlDataDisk {
    param([Parameter(Mandatory)][VMContext]$VM)

    Add-VMDataDisk -VM $VM -Path $VM.Settings.SQLDiskPath -Label 'SQL data disk'
}

function Initialize-GuestSqlDisk {
    <#
      Prepares the SQL data disk in the guest and records the drive letter it
      actually got, which every later SQL step uses.

      The preferred letter is often taken in a guest built by hand: on a
      Generation 2 VM the DVD drive usually claims D: once Windows is
      installed. So an optical drive on the wanted letter is moved out of the
      way, and when the letter is held by anything else, the volume keeps the
      letter it has rather than failing the build.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Write-LogEntry 'Preparing the SQL data disk inside the guest...' 'INFO'
    $settings = $VM.Settings
    $result = Invoke-GuestScript -VM $VM -Activity 'SQL data disk preparation' -TimeoutMinutes 15 -ArgumentList @(
        $settings.GuestDataDriveLetter, $settings.SQLDiskSizeGB,
        @($settings.SqlDataFolder, $settings.SqlLogFolder, $settings.SqlTempFolder, $settings.SqlBackupFolder)
    ) -ScriptBlock {
        param($desiredLetter, $expectedSizeGB, $folders)
        $ErrorActionPreference = 'Stop'
        $notes = @()

        # Optical drives never appear in Get-Disk. Boot and system disks are
        # left out rather than assuming the OS is disk 0.
        $candidates = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })
        if ($candidates.Count -eq 0) { throw 'no data disk found in the guest' }

        $expectedBytes = [int64]$expectedSizeGB * 1GB
        $disk = $candidates | Sort-Object { [math]::Abs($_.Size - $expectedBytes) } | Select-Object -First 1
        if ($candidates.Count -gt 1) {
            $notes += New-GuestNote -Level INFO -Text "guest has $($candidates.Count) data disks; chose disk $($disk.Number) ($([math]::Round($disk.Size/1GB)) GB) as the closest match to $expectedSizeGB GB"
        }

        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false; $notes += New-GuestNote -Level INFO -Text 'brought the disk online' }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false; $notes += New-GuestNote -Level INFO -Text 'cleared the read-only flag' }
        $disk = Get-Disk -Number $disk.Number

        $formatted = $false
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
            $formatted = $true
        }

        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.Type -ne 'Reserved' -and $_.Size -gt 100MB })

        # Is the wanted letter free, ours already, or held by something else?
        $occupant = Get-GuestVolumeByLetter -Letter $desiredLetter
        $ownedByUs = ($partitions.Count -gt 0 -and $partitions[0].DriveLetter -eq $desiredLetter)
        if ($occupant -and -not $ownedByUs) {
            if ($occupant.DriveType -eq 5) {
                # 5 = CD-ROM: the DVD drive took the letter. Move it aside.
                $free = Get-GuestFreeLetter
                if ($free) {
                    $occupant.DriveLetter = "${free}:"
                    Set-CimInstance -InputObject $occupant -ErrorAction Stop
                    $notes += New-GuestNote -Level INFO -Text "moved the DVD drive off ${desiredLetter}: to ${free}:"
                    Start-Sleep -Seconds 2
                }
                else {
                    $notes += New-GuestNote -Level WARN -Text "${desiredLetter}: is held by the DVD drive and no spare letter was free"
                }
            }
            else {
                $notes += New-GuestNote -Level WARN -Text "${desiredLetter}: is already in use by a $($occupant.FileSystem) volume that is not the SQL data disk"
            }
        }

        if ($partitions.Count -eq 0) {
            $part = if (Get-GuestVolumeByLetter -Letter $desiredLetter) {
                New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            }
            else {
                New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $desiredLetter
            }
            Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'SQLDATA' -Confirm:$false -Force | Out-Null
            $formatted = $true
            $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
        }
        else {
            $part = $partitions[0]
            if ($part.DriveLetter -ne $desiredLetter -and -not (Get-GuestVolumeByLetter -Letter $desiredLetter)) {
                Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $desiredLetter
                $notes += New-GuestNote -Level INFO -Text "moved the data volume to ${desiredLetter}:"
                $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
            }
        }

        $letter = "$($part.DriveLetter)".Trim()
        if (-not $letter) {
            # Last resort: any letter rather than an unreachable volume.
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter (Get-GuestFreeLetter)
            $letter = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter)".Trim()
        }
        if (-not $letter) { throw 'the SQL data volume could not be assigned a drive letter' }
        if ($letter -ne $desiredLetter) {
            $notes += New-GuestNote -Level WARN -Text "using ${letter}: instead of ${desiredLetter}: - SQL paths follow the actual letter"
        }

        foreach ($folder in $folders) { New-GuestFolder -Path "${letter}:\$folder" }

        return [pscustomobject]@{
            Letter    = $letter
            Formatted = $formatted
            SizeGB    = [math]::Round($disk.Size / 1GB, 1)
            FreeGB    = [math]::Round((Get-PSDrive -Name $letter).Free / 1GB, 1)
            Notes     = $notes
        }
    }

    Write-GuestNote -Notes $result.Notes
    $VM.SetDataDriveLetter($result.Letter)

    $state = if ($result.Formatted) { 'formatted as' } else { 'already prepared, mounted as' }
    Write-LogEntry "SQL data disk $state $($result.Letter): ($($result.FreeGB) GB free of $($result.SizeGB) GB)" 'OK'
    $runtime = $VM.Runtime
    Write-LogEntry "  SQL directories: $($runtime.GuestSqlDataDir), $($runtime.GuestSqlLogDir), $($runtime.GuestSqlTempDir), $($runtime.GuestSqlBackupDir)" 'INFO'
}
