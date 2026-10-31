# Rebuild.ps1 - Rebuilding a VM: retire the old one, build, restore, check, then delete the old disk.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
#   capture -> shut down -> retire the old OS disk by RENAME -> build phases
#   3-8 -> restore -> check -> only then delete the retired disk.
#
# The old OS disk is never deleted until every build phase has completed
# without problems and the new guest has passed the check, so a failed
# rebuild can be undone. The SQL data disk, the Dev Drive and the
# User disk are never touched.

function Invoke-Rebuild {
    <# Returns whether the rebuild completed and passed its check. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$SkipCapture,
        [switch]$NoUnattend
    )

    Write-LogEntry 'REBUILD - Capture, Rebuild, Restore' 'PHASE'
    $started = Get-Date

    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not available.'
    }

    $exists = [bool](Get-VM -Name $VM.Name -ErrorAction SilentlyContinue)

    # The personal folders go to the User disk before the OS disk is
    # retired; if they cannot, nothing is retired (#137).
    if ($exists) { $null = Install-UserDisk -VM $VM }

    $manifest = $null
    if ($SkipCapture) {
        Write-LogEntry 'Skipping capture (-SkipCapture): using the existing capture' 'WARN'
        $manifest = Get-CaptureManifest -VM $VM
        if (-not $manifest) { throw "There is no usable capture, and -SkipCapture was given. Capture first with: Save-LazyVMState -Name $($VM.Name)" }
    }
    elseif ($exists) {
        $manifest = Save-GuestState -VM $VM
    }
    else {
        Write-LogEntry 'No existing VM - this is a first build rather than a rebuild' 'INFO'
    }

    $retired = if ($exists) { Invoke-RetireCurrentVM -VM $VM } else { $null }

    $rebuildOk = $false
    $buildOutcome = $null
    try {
        $buildOutcome = Invoke-BuildPhase -VM $VM -FromPhase 3 -NoUnattend:$NoUnattend
        if ($manifest -and -not (Restore-GuestState -VM $VM)) {
            Write-LogEntry 'Some of the capture could not be restored; the log above says what' 'WARN'
        }
        $rebuildOk = $true
    }
    catch {
        Write-LogError 'Rebuild failed' $_
    }

    $verification = $null
    if ($rebuildOk) {
        $expected = if ($manifest) { @($manifest.Databases) } else { @() }
        try { $verification = Test-RebuiltVM -VM $VM -ExpectedDatabases $expected }
        catch {
            Write-LogError 'Verification failed' $_
            $verification = [pscustomobject]@{ Passed = $false; Failures = @("verification threw: $($_.Exception.Message)") }
        }
    }

    $elapsed = [int]((Get-Date) - $started).TotalMinutes
    $builtCleanly = $buildOutcome -eq [BuildOutcome]::Complete
    if ($rebuildOk -and $builtCleanly -and $verification.Passed) {
        Write-LogEntry "Rebuild verified in $elapsed minutes" 'OK'
        if ($retired) { $null = Remove-RetiredVM -VM $VM -Retired $retired }
        return $true
    }

    Write-LogEntry "Rebuild did NOT complete cleanly (after $elapsed minutes)" 'ERROR'
    if ($buildOutcome -eq [BuildOutcome]::CompleteWithProblems) { Write-LogEntry '  Some build steps failed; the log above says which' 'ERROR' }
    if ($verification) { foreach ($failure in @($verification.Failures)) { Write-LogEntry "  $failure" 'ERROR' } }
    if ($retired) {
        Write-LogEntry '' 'INFO'
        Write-LogEntry 'The previous VM has been KEPT. To roll back:' 'WARN'
        Write-LogEntry "  Stop-VM -Name '$($VM.Name)' -TurnOff -Force -ErrorAction SilentlyContinue" 'INFO'
        Write-LogEntry "  Remove-VM -Name '$($VM.Name)' -Force" 'INFO'
        Write-LogEntry "  Remove-Item '$($retired.NewOsPath)' -Force" 'INFO'
        Write-LogEntry "  Rename-Item '$($retired.RetiredOsPath)' '$([IO.Path]::GetFileName($retired.NewOsPath))'" 'INFO'
        Write-LogEntry "  Build-LazyVM -Name '$($VM.Name)' -FromPhase 6" 'INFO'
        Write-LogEntry '  The old C: is BitLocker-encrypted for the old VM''s TPM, so it asks for its recovery password once:' 'INFO'
        Write-LogEntry "  the 'OS disk' one recorded before this rebuild, from: Get-LazyVMCredential -Name '$($VM.Name)' -RecoveryPassword" 'INFO'
        Write-LogEntry '' 'INFO'
        Write-LogEntry "Retired OS disk: $($retired.RetiredOsPath)" 'WARN'
    }
    return $false
}

function Remove-VMCheckpointTree {
    <#
      Deletes every checkpoint of the VM. Only the root checkpoints are
      named, each with its children: naming a child too would delete it
      twice, and Hyper-V fails the second delete (#194).
    #>
    param([Parameter(Mandatory)][string]$VMName)

    $roots = @(Get-VMSnapshot -VMName $VMName -ErrorAction Stop | Where-Object { -not $_.ParentSnapshotName })
    if ($roots.Count -gt 0) { Remove-VMSnapshot -VMName $VMName -Name @($roots.Name) -IncludeAllChildSnapshots -Confirm:$false -ErrorAction Stop }
}

function Invoke-RetireCurrentVM {
    <# Shuts the guest down and moves its OS disk and configuration folder aside under a dated name. Deletes nothing it cannot rebuild. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    Write-LogEntry 'Retiring the current VM...' 'INFO'
    Stop-GuestGracefully -VM $VM

    $null = Get-VM -Name $VM.Name -ErrorAction Stop   # fail fast if it vanished
    $drives = @(Get-VMHardDiskDrive -VMName $VM.Name)
    $osDrive = @($drives | Where-Object { $_.ControllerLocation -eq 0 -and $_.ControllerNumber -eq 0 }) + @($drives | Where-Object { $_.Path -notin @($settings.SQLDiskPath, $settings.DevDrivePath, $settings.UserDiskPath) }) |
        Select-Object -First 1
    if (-not $osDrive) { throw 'Could not identify the OS disk on the existing VM.' }

    $osPath = $osDrive.Path
    $stamp = Get-Stamp
    $retiredPath = Join-Path (Split-Path $osPath -Parent) ('{0}.retired-{1}.vhdx' -f [IO.Path]::GetFileNameWithoutExtension($osPath), $stamp)

    # Any checkpoint holds the disk open as a differencing chain, which would
    # make the rename meaningless.
    if (@(Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-LogEntry 'Removing the checkpoints before retiring the disk...' 'WARN'
        Remove-VMCheckpointTree -VMName $VM.Name
        $null = Wait-Until -Activity 'Merging the checkpoints' -Timeout ([timespan]::FromMinutes(30)) -NoThrow -Condition {
            @(Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue).Count -eq 0
        }
    }

    Remove-VM -Name $VM.Name -Force
    Write-LogEntry "VM definition '$($VM.Name)' removed (disks kept)" 'OK'

    Move-Item -LiteralPath $osPath -Destination $retiredPath -Force
    Write-LogEntry "OS disk retired to $([IO.Path]::GetFileName($retiredPath)) ($(Format-Size (Get-Item $retiredPath).Length))" 'OK'

    # The VM's own configuration folder would otherwise collide with the new build.
    $retiredConfig = $null
    if (Test-Path -LiteralPath $settings.VMConfigDir) {
        try {
            $retiredConfig = "$($settings.VMConfigDir).retired-$stamp"
            Move-Item -LiteralPath $settings.VMConfigDir -Destination $retiredConfig -Force
            Write-LogEntry 'VM configuration folder moved aside' 'OK'
        }
        catch {
            Write-LogEntry "Could not move the VM configuration folder: $($_.Exception.Message)" 'WARN'
            $retiredConfig = $null
        }
    }

    # The answer-file disc is built afresh every time.
    Remove-Item -LiteralPath $settings.SeedDiskPath -Force -ErrorAction SilentlyContinue

    Write-LogEntry "SQL data disk left untouched: $($settings.SQLDiskPath)" 'INFO'
    if ($settings.UseDevDrive -and (Test-Path -LiteralPath $settings.DevDrivePath)) {
        Write-LogEntry "Dev Drive left untouched: $($settings.DevDrivePath)" 'INFO'
    }
    Write-LogEntry "User disk left untouched: $($settings.UserDiskPath)" 'INFO'

    return [pscustomobject]@{
        RetiredOsPath = $retiredPath
        NewOsPath     = $osPath
        RetiredConfig = $retiredConfig
    }
}

function Remove-RetiredVM {
    <# Deletes the retired OS disk and configuration folder, unless DeleteRetiredDiskOnSuccess is off. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)]$Retired
    )

    if (-not $VM.Settings.DeleteRetiredDiskOnSuccess) {
        Write-LogEntry "Keeping the retired disk as configured: $($Retired.RetiredOsPath)" 'INFO'
        Write-LogEntry '  Delete it by hand once you are happy with the new VM.' 'INFO'
        return
    }

    $freed = 0
    if (Test-Path -LiteralPath $Retired.RetiredOsPath) {
        $freed = (Get-Item -LiteralPath $Retired.RetiredOsPath).Length
        Remove-Item -LiteralPath $Retired.RetiredOsPath -Force
    }
    if ($Retired.RetiredConfig -and (Test-Path -LiteralPath $Retired.RetiredConfig)) {
        Remove-Item -LiteralPath $Retired.RetiredConfig -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-LogEntry "Retired VM deleted - $(Format-Size $freed) reclaimed" 'OK'
}
