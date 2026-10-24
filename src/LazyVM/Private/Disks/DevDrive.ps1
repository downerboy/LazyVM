# DevDrive.ps1 - The Dev Drive: created on the host, prepared and trusted in the guest.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A Dev Drive is not a distinct kind of disk: it is a ReFS volume carrying a
# per-machine "trusted" designation, which tells Filter Manager to detach
# everything except antivirus. That is where the build speed comes from.
#
#   * The designation is per MACHINE, not per volume, so it does not survive
#     into a rebuilt guest. Trusting again changes metadata only and never
#     reformats, so the data is safe; it has to happen on every rebuild.
#   * Microsoft does not support Dev Drive on removable or hot-pluggable
#     disks. A Hyper-V SCSI disk normally presents as fixed, but the guest
#     code tries the designation and falls back to a plain NTFS volume if it
#     is refused: a slower drive is far better than a failed build.

function Initialize-DevDriveVhd {
    <# Creates the Dev Drive's disk on the host, never over an existing one: it carries the working source across rebuilds. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.UseDevDrive) {
        Write-LogEntry 'Dev Drive turned off in the settings (UseDevDrive) - skipping' 'INFO'
        return
    }
    if ($VM.Settings.DevDriveSizeGB -lt 50) {
        throw "DevDriveSizeGB is $($VM.Settings.DevDriveSizeGB); Dev Drive requires at least 50 GB."
    }
    Initialize-DataVhd -Path $VM.Settings.DevDrivePath -SizeGB $VM.Settings.DevDriveSizeGB -Label 'Dev Drive disk'
}

function Add-DevDriveDisk {
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.UseDevDrive) { return }
    if (-not (Test-Path -LiteralPath $VM.Settings.DevDrivePath)) {
        Write-LogEntry "Dev Drive disk not found at $($VM.Settings.DevDrivePath) - skipping attach" 'WARN'
        return
    }
    Add-VMDataDisk -VM $VM -Path $VM.Settings.DevDrivePath -Label 'Dev Drive disk'
}

function Initialize-GuestDevDrive {
    <#
      Prepares the volume in the guest and designates it a trusted Dev Drive.
      On a re-run it finds the existing volume by its label and only applies
      the trust again, which is what a rebuilt guest needs. Records the
      letter the volume got.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    if (-not $settings.UseDevDrive) { return }

    Write-LogEntry 'Preparing the Dev Drive inside the guest...' 'INFO'

    $result = Invoke-GuestScript -VM $VM -Activity 'Dev Drive preparation' -TimeoutMinutes 30 -ArgumentList @(
        $settings.DevDriveLetter, $settings.DevDriveSizeGB, $settings.DevDriveLabel, (@($settings.DevDriveFilters) -join ', ')
    ) -ScriptBlock {
        param($desiredLetter, $expectedSizeGB, $label, $filters)
        $ErrorActionPreference = 'Stop'
        $notes = @()

        # Dev Drive support is a system-level switch and a new guest has it off.
        $enableOut = & fsutil devdrv enable 2>&1
        if ($LASTEXITCODE -ne 0) {
            $notes += New-GuestNote -Level WARN -Text "fsutil devdrv enable returned $LASTEXITCODE ($($enableOut -join ' '))"
        }

        # Already prepared? Found by label: that survives a rebuild, where the
        # volume is intact but no longer trusted.
        $existing = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $label -and $_.DriveLetter })
        $letter = $null
        $formatted = $false
        $fileSystem = ''

        if ($existing.Count -gt 0) {
            $letter = "$($existing[0].DriveLetter)"
            $fileSystem = "$($existing[0].FileSystem)"
            $notes += New-GuestNote -Level INFO -Text "found an existing '$label' volume at ${letter}:"

            if ($letter -ne $desiredLetter -and -not (Get-GuestVolumeByLetter -Letter $desiredLetter)) {
                $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
                if ($part) {
                    Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $desiredLetter
                    $letter = $desiredLetter
                    $notes += New-GuestNote -Level INFO -Text "moved it to ${desiredLetter}:"
                }
            }
        }
        else {
            # The unused disk closest to the configured size. The SQL data
            # disk is a different size, so this does not pick it.
            $expectedBytes = [int64]$expectedSizeGB * 1GB
            $candidates = @(Get-Disk | Where-Object {
                    $lettered = @(Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
                    -not $_.IsBoot -and -not $_.IsSystem -and ($_.PartitionStyle -eq 'RAW' -or $lettered.Count -eq 0)
                })
            if ($candidates.Count -eq 0) { throw 'no unused disk found in the guest for the Dev Drive' }

            $disk = $candidates | Sort-Object { [math]::Abs($_.Size - $expectedBytes) } | Select-Object -First 1
            if ([math]::Abs($disk.Size - $expectedBytes) -gt 20GB) {
                $notes += New-GuestNote -Level WARN -Text "closest unused disk is $([math]::Round($disk.Size/1GB)) GB, expected about $expectedSizeGB GB - check the disk layout"
            }

            if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
            $disk = Get-Disk -Number $disk.Number
            if ($disk.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
            }

            $letter = if (Get-GuestVolumeByLetter -Letter $desiredLetter) { Get-GuestFreeLetter } else { $desiredLetter }
            if (-not $letter) { throw 'no free drive letter available for the Dev Drive' }
            $null = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter

            # Dev Drive first. -DevDrive implies ReFS; it is refused on a disk
            # the system considers removable, so fall back rather than fail.
            try {
                Format-Volume -DriveLetter $letter -DevDrive -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
                $fileSystem = 'ReFS'
            }
            catch {
                $notes += New-GuestNote -Level ERROR -Text "Dev Drive format refused: $($_.Exception.Message)"
                $notes += New-GuestNote -Level WARN -Text 'falling back to NTFS - the volume still works and still persists, just without Dev Drive acceleration'
                Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
                $fileSystem = 'NTFS'
            }
            $formatted = $true
        }

        if (-not $letter) { throw 'the Dev Drive volume could not be assigned a drive letter' }

        $trusted = $false
        if ($fileSystem -eq 'ReFS') {
            # A non-zero exit here is usually "the volume is in use, the
            # change applies on next mount", which is harmless when the volume
            # was designated at format time. The query decides.
            $trustOut = & fsutil devdrv trust "${letter}:" 2>&1
            $trustExit = $LASTEXITCODE

            if ($filters) {
                $filterOut = & fsutil devdrv setfiltersallowed /volume "${letter}:" $filters 2>&1
                if ($LASTEXITCODE -ne 0) { $notes += New-GuestNote -Level WARN -Text "setfiltersallowed returned $LASTEXITCODE ($($filterOut -join ' '))" }
                else { $notes += New-GuestNote -Level INFO -Text "allowed filters set: $filters" }
            }

            $query = & fsutil devdrv query "${letter}:" 2>&1
            $trusted = (($query -join ' ') -match '(?i)trusted developer volume')
            if (-not $trusted) {
                if ($trustExit -ne 0) { $notes += New-GuestNote -Level WARN -Text "fsutil devdrv trust returned $trustExit ($($trustOut -join ' '))" }
                $notes += New-GuestNote -Level INFO -Text "query says: $(($query -join ' ').Trim())"
            }
        }

        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Letter     = $letter
            FileSystem = $fileSystem
            Trusted    = $trusted
            Formatted  = $formatted
            SizeGB     = if ($volume) { [math]::Round($volume.Size / 1GB, 1) } else { 0 }
            FreeGB     = if ($volume) { [math]::Round($volume.SizeRemaining / 1GB, 1) } else { 0 }
            Notes      = $notes
        }
    }

    Write-GuestNote -Notes $result.Notes
    $VM.Runtime.DevDriveLetter = $result.Letter

    if ($result.Trusted) {
        Write-LogEntry "Dev Drive ready at $($result.Letter): - trusted ReFS, $($result.FreeGB) GB free of $($result.SizeGB) GB" 'OK'
        Write-LogEntry '  Defender performance mode and ReFS block cloning are active on this volume.' 'INFO'
    }
    elseif ($result.FileSystem -eq 'ReFS') {
        Write-LogEntry "Volume at $($result.Letter): is ReFS but NOT trusted - it works, without the Dev Drive speedups" 'WARN'
        Write-LogEntry "  Try by hand:  fsutil devdrv enable   then   fsutil devdrv trust $($result.Letter):" 'INFO'
    }
    else {
        Write-LogEntry "Volume at $($result.Letter): is NTFS - Dev Drive was not available on this disk" 'WARN'
        Write-LogEntry '  It still persists across rebuilds; only the ReFS acceleration is missing.' 'INFO'
    }
}
