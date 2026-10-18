# GuestOSDisk.ps1 - Keeps C: able to use the whole OS disk.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

function Expand-GuestSystemDrive {
    <#
      Makes C: fill the OS disk, on every build and every maintenance run.

      On first boot Windows Setup shrinks C: and puts a recovery partition
      straight after it. When the OS disk is later made bigger, the new space
      lands after that partition, and Windows cannot extend C: across it. So
      the recovery partition is removed here and the recovery tools are kept
      on C: instead (reagentc moves them), then C: is extended into any free
      space. A VM has no use for recovery tools on a separate partition: it is
      rolled back with checkpoints or rebuilt.

      Growing the OS disk is then all a user has to do; the next maintenance
      run extends C: by itself. Nothing here stops a build or a maintenance
      run: anything that fails is logged and C: is left as it was.
    #>
    try {
        $report = Invoke-GuestScript -Activity 'C: drive expansion' -TimeoutMinutes 10 -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
            $notes = @()

            Update-HostStorageCache
            $os = Get-Partition -DriveLetter C
            $after = @(Get-Partition -DiskNumber $os.DiskNumber | Where-Object { $_.Offset -gt $os.Offset })
            $others = @($after | Where-Object { $_.GptType -ne $recoveryType })
            if ($others.Count -gt 0) {
                return @("WARN|C: cannot be extended: partition $($others[0].PartitionNumber) after it is not a recovery partition, so it was left alone")
            }

            # Once reagentc has disabled recovery, it is turned back on whatever
            # happens next, so the guest never ends up without recovery tools.
            $recoveryMoved = $false
            try {
                if ($after.Count -gt 0) {
                    $output = & reagentc.exe /disable 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $notes += "WARN|recovery partition kept: reagentc /disable failed (exit $LASTEXITCODE): $output"
                    }
                    else {
                        $recoveryMoved = $true
                        if (-not (Test-Path -LiteralPath "$env:SystemRoot\System32\Recovery\Winre.wim")) {
                            $notes += 'WARN|recovery partition kept: the recovery tools did not move onto C:'
                        }
                        else {
                            foreach ($partition in $after) {
                                Remove-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
                            }
                            $notes += 'OK|removed the recovery partition after C:; the recovery tools now live on C:'
                        }
                    }
                }

                # With the recovery partition kept, there is no free space
                # directly after C: and this changes nothing.
                Update-HostStorageCache
                $current = (Get-Partition -DriveLetter C).Size
                $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
                # Resize-Partition refuses to grow by less than a few MB.
                if ($max - $current -gt 16MB) {
                    Resize-Partition -DriveLetter C -Size $max
                    $notes += "OK|C: extended from $([math]::Round($current / 1GB, 1)) GB to $([math]::Round($max / 1GB, 1)) GB"
                }
            }
            finally {
                if ($recoveryMoved) {
                    $output = & reagentc.exe /enable 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $notes += "WARN|the recovery tools are on C: but reagentc /enable failed (exit $LASTEXITCODE): $output"
                    }
                }
            }
            return $notes
        }

        $lines = @($report | Where-Object { $_ })
        if ($lines.Count -gt 0) { Write-LogEntry 'OS disk (C:):' 'INFO' }
        foreach ($line in $lines) {
            $level, $text = "$line" -split '\|', 2
            Write-LogEntry "  $text" $level
        }
    }
    catch {
        Write-LogError 'Expanding C: failed; carrying on' $_
    }
}
