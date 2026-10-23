# GuestOSDisk.ps1 - Keeps C: able to use the whole OS disk.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# The recovery partition LazyVM puts after C:, in MB. Microsoft recommends
# about 1 GB, so later Windows RE updates still fit.
$script:RecoveryPartitionMB = 1024

function Expand-GuestSystemDrive {
    <#
      Makes C: use the whole OS disk, on every build and every maintenance run.

      Windows keeps its recovery tools (Windows RE) on a partition straight
      after C:. When the OS disk is made bigger, the new space lands after
      that partition, and Windows cannot extend C: across it. So when there is
      new space, this moves the recovery partition to the end of the disk and
      extends C: up to it:

        1. reagentc /disable, which moves the recovery tools onto C:
        2. removes the old recovery partition and extends C:
        3. creates a new recovery partition at the end of the disk
        4. moves the recovery tools onto it and turns recovery on again

      The recovery tools cannot stay on C:: Windows refuses them on a
      BitLocker-encrypted volume. A checkpoint is taken first and removed once
      everything worked. If anything failed, the checkpoint is kept, the log
      says how to go back to it, and no further attempt is made while it
      exists, so a problem is never repeated every night. When there is no new
      space, nothing changes and nothing is logged. Nothing here stops a build
      or a maintenance run: anything that fails is logged.
    #>
    try {
        $earlier = @(Get-ExpansionCheckpoint)
        if ($earlier.Count -gt 0) {
            Write-LogEntry "OS disk (C:): an earlier attempt to extend C: failed, so it is not tried again while its checkpoint '$($earlier[0])' exists." 'WARN'
            Write-LogEntry "  See the log of that run. Once the VM is as it should be, delete that checkpoint and the next run tries again." 'INFO'
            return
        }

        $plan = Invoke-GuestScript -Activity 'OS disk check' -TimeoutMinutes 5 -ScriptBlock (Get-OSDiskPlanScript)
        if ($plan.Action -eq 'None') { return }

        Write-LogEntry 'OS disk (C:):' 'INFO'
        if ($plan.Action -eq 'Blocked') {
            Write-LogEntry "  $($plan.Reason)" 'WARN'
            return
        }

        Write-LogEntry "  $($plan.Reason) - moving the recovery partition to the end of the disk and extending C:" 'INFO'
        $checkpoint = "C: expansion $(Get-Date -Format 'yyyyMMdd-HHmmss')"
        try { New-ToolingCheckpoint -Name $checkpoint -SkipPrune }
        catch {
            Write-LogError '  No checkpoint could be taken, so C: was left as it was' $_
            return
        }

        $report = Invoke-GuestScript -Activity 'C: drive expansion' -TimeoutMinutes 20 `
            -ArgumentList @($script:RecoveryPartitionMB) -ScriptBlock (Get-OSDiskExpandScript)
        $failed = $false
        foreach ($line in @($report | Where-Object { $_ })) {
            $level, $text = "$line" -split '\|', 2
            if ($level -eq 'WARN') { $failed = $true }
            Write-LogEntry "  $text" $level
        }

        if ($failed) {
            Write-LogEntry "  Kept the checkpoint '$checkpoint'. To put the VM back as it was: Restore-VMSnapshot -VMName '$($CFG.VMName)' -Name '$checkpoint'" 'WARN'
        }
        else {
            try {
                Remove-ExpansionCheckpoint -Name $checkpoint
                Write-LogEntry "  Checkpoint '$checkpoint' removed: it is no longer needed" 'OK'
            }
            catch {
                Write-LogEntry "  Could not remove the checkpoint '$checkpoint': $($_.Exception.Message)" 'WARN'
                Write-LogEntry '  Delete it in Hyper-V Manager; until then, C: is not extended again.' 'WARN'
            }
        }
    }
    catch {
        Write-LogError 'Expanding C: failed; carrying on' $_
    }
}

function Get-ExpansionCheckpoint {
    <# Names of this VM's checkpoints taken before extending C:. #>
    return @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'C: expansion *' } | ForEach-Object { $_.Name })
}

function Remove-ExpansionCheckpoint {
    param([Parameter(Mandatory)][string]$Name)
    Remove-VMSnapshot -VMName $CFG.VMName -Name $Name -Confirm:$false -ErrorAction Stop
}

function Get-OSDiskPlanScript {
    <#
      Guest script that changes nothing: says whether C: has new space to
      grow into, as [pscustomobject]@{ Action = None | Expand | Blocked; Reason }.
    #>
    return {
        $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        Update-HostStorageCache
        $os = Get-Partition -DriveLetter C
        $disk = Get-Disk -Number $os.DiskNumber
        $partitions = @(Get-Partition -DiskNumber $os.DiskNumber)
        $after = @($partitions | Where-Object { $_.Offset -gt $os.Offset })

        $others = @($after | Where-Object { $_.GptType -ne $recoveryType })
        if ($others.Count -gt 0) {
            return [pscustomobject]@{ Action = 'Blocked'; Reason = "C: cannot be extended: partition $($others[0].PartitionNumber) after it is not a recovery partition, so it was left alone" }
        }

        # Unused space after the last partition. The disk keeps about 1 MB at
        # its end for the backup partition table, so small amounts are noise.
        $end = ($partitions | ForEach-Object { $_.Offset + $_.Size } | Measure-Object -Maximum).Maximum
        $freeMB = [math]::Floor(($disk.Size - $end) / 1MB)
        if ($freeMB -ge 64) {
            return [pscustomobject]@{ Action = 'Expand'; Reason = "$freeMB MB of the OS disk is unused" }
        }
        if ($after.Count -eq 0) {
            $enabled = (& reagentc.exe /info 2>&1 | Out-String) -match 'Windows RE status:\s+Enabled'
            if ($enabled -or (Test-Path -LiteralPath "$env:SystemRoot\System32\Recovery\Winre.wim")) {
                return [pscustomobject]@{ Action = 'Expand'; Reason = 'there is no recovery partition after C:' }
            }
        }
        return [pscustomobject]@{ Action = 'None'; Reason = '' }
    }
}

function Get-OSDiskExpandScript {
    <#
      Guest script that moves the recovery partition to the end of the disk
      and extends C: up to it. Returns notes as 'LEVEL|text'; a WARN note
      means the work did not finish. Whatever happens, it ends with recovery
      turned on if it can be.
    #>
    return {
        param([int]$recoveryMB)

        $recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        $wim = "$env:SystemRoot\System32\Recovery\Winre.wim"
        $notes = [System.Collections.Generic.List[string]]::new()

        # Native tools report failure through their exit code and write to
        # stderr. Capturing stderr must not turn it into a terminating error.
        function Invoke-Tool([string]$FilePath, [string[]]$ArgumentList) {
            $ErrorActionPreference = 'Continue'
            $output = (& $FilePath @ArgumentList 2>&1 | Out-String).Trim()
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
        }
        function Invoke-DiskPart([string[]]$Commands) {
            $file = Join-Path -Path $env:TEMP -ChildPath "lazyvm-diskpart-$([guid]::NewGuid().ToString('N')).txt"
            Set-Content -LiteralPath $file -Value $Commands -Encoding ascii
            try { return Invoke-Tool -FilePath diskpart.exe -ArgumentList @('/s', $file) }
            finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
        function Test-RecoveryEnabled {
            return (Invoke-Tool -FilePath reagentc.exe -ArgumentList @('/info')).Output -match 'Windows RE status:\s+Enabled'
        }

        function Move-RecoveryPartition([int]$SizeMB) {
            $ErrorActionPreference = 'Stop'
            Update-HostStorageCache
            $os = Get-Partition -DriveLetter C
            $diskNumber = $os.DiskNumber

            # 1. Recovery tools onto C:, so the old partition can go.
            if (Test-RecoveryEnabled) {
                $result = Invoke-Tool -FilePath reagentc.exe -ArgumentList @('/disable')
                if ($result.Code -ne 0) {
                    $notes.Add("WARN|nothing changed: reagentc /disable failed (exit $($result.Code)): $($result.Output)")
                    return
                }
            }
            if (-not (Test-Path -LiteralPath $wim)) {
                $notes.Add('WARN|nothing changed: the recovery tools (Winre.wim) are not on C:, so there is nothing to put on a new recovery partition')
                return
            }

            # 2. Old recovery partition out, C: up to where the new one starts.
            foreach ($partition in @(Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Offset -gt $os.Offset -and $_.GptType -eq $recoveryType })) {
                Remove-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
            }
            Update-HostStorageCache
            $before = (Get-Partition -DriveLetter C).Size
            $target = (Get-PartitionSupportedSize -DriveLetter C).SizeMax - ($SizeMB * 1MB)
            if ([math]::Abs($target - $before) -gt 16MB) {
                Resize-Partition -DriveLetter C -Size $target
                $notes.Add("OK|C: resized from $([math]::Round($before / 1GB, 1)) GB to $([math]::Round($target / 1GB, 1)) GB")
            }

            # 3. New recovery partition at the end of the disk.
            $recovery = New-Partition -DiskNumber $diskNumber -UseMaximumSize
            $null = Format-Volume -Partition $recovery -FileSystem NTFS -NewFileSystemLabel 'Recovery' -Confirm:$false
            $letter = [char[]](82..90) | Where-Object { -not (Test-Path -LiteralPath "${_}:\") } | Select-Object -First 1
            if (-not $letter) {
                $notes.Add('WARN|no free drive letter between R: and Z: to set up the recovery partition')
                return
            }
            $result = Invoke-DiskPart -Commands @(
                "select disk $diskNumber", "select partition $($recovery.PartitionNumber)",
                "set id=$($recoveryType.Trim('{}')) override", 'gpt attributes=0x8000000000000001', "assign letter=$letter")
            if ($result.Code -ne 0) {
                $notes.Add("WARN|could not mark the new partition as a recovery partition (diskpart exit $($result.Code)): $($result.Output)")
                return
            }

            # 4. Recovery tools onto it, recovery on again, letter removed.
            try {
                $folder = "${letter}:\Recovery\WindowsRE"
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Copy-Item -LiteralPath $wim -Destination $folder -Force
                $result = Invoke-Tool -FilePath reagentc.exe -ArgumentList @('/setreimage', '/path', $folder, '/target', "$env:SystemRoot")
                if ($result.Code -ne 0) {
                    $notes.Add("WARN|reagentc /setreimage failed (exit $($result.Code)): $($result.Output)")
                    return
                }
                $result = Invoke-Tool -FilePath reagentc.exe -ArgumentList @('/enable')
                if ($result.Code -ne 0) {
                    $notes.Add("WARN|reagentc /enable failed (exit $($result.Code)): $($result.Output)")
                    return
                }
            }
            finally {
                $null = Invoke-DiskPart -Commands @("select disk $diskNumber", "select partition $($recovery.PartitionNumber)", "remove letter=$letter")
            }
            $notes.Add("OK|recovery partition moved to the end of the disk ($SizeMB MB) and recovery turned on")
        }

        try { Move-RecoveryPartition -SizeMB $recoveryMB }
        catch {
            $notes.Add("WARN|stopped part way: $($_.Exception.Message)")
        }
        finally {
            # Never leave the guest without recovery when it can be helped.
            # On a BitLocker-encrypted C: this fails, and the WARN above says why.
            if (-not (Test-RecoveryEnabled)) {
                $null = Invoke-Tool -FilePath reagentc.exe -ArgumentList @('/enable')
                if (-not (Test-RecoveryEnabled)) {
                    $notes.Add('WARN|recovery (Windows RE) is turned off in the guest')
                }
            }
        }
        return $notes
    }
}
