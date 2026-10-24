# RemoveVM.ps1 - Deleting a VM and everything LazyVM created for it (Remove-LazyVM).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  REMOVING A VM
#
#  Remove-LazyVM deletes the VM and everything created to support it:
#
#    scheduled tasks   its maintenance task and any resume-after-reboot task
#    registry          its resume key
#    Hyper-V           the VM itself, with its checkpoints
#    disks             OS disk (and any retired ones), SQL data disk, Dev Drive,
#                      answer-file disc, and every disk Hyper-V reports attached to it
#    folders           checkpoints, captured state, the VM's configuration
#                      folder and its profile (Config\VMs\<Name>)
#    files             credentials, Visual Studio settings backup, logs
#
#  What every VM uses is never touched: the root folder, the ISO, installers,
#  the scripts and settings, and the credential folder itself. Anything another
#  VM also uses is kept too: a path another VM's settings name, a folder
#  holding one, a disk attached to another VM, a task name or registry key
#  another VM shares. The confirmation lists exactly what will go and what is
#  kept, and why.
#
#  The planning is kept apart from the deleting (Get-VMRemovalPlan takes
#  settings in and returns paths out), so the rules can be tested without
#  Hyper-V or a single real file.
# ─────────────────────────────────────────────────────────────────────────────

function Test-PathWithin {
    <# True when $Path is $Folder itself or lies anywhere inside it. Ignores case and trailing backslashes. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Folder
    )

    $path = $Path.TrimEnd('\')
    $folder = $Folder.TrimEnd('\')
    if ($path.Equals($folder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $path.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-ParentFolder {
    <# The folder holding $Path: text-based, so the rule is the same wherever it runs. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $trimmed = $Path.TrimEnd('\')
    $cut = $trimmed.LastIndexOf('\')
    if ($cut -gt 0) { return $trimmed.Substring(0, $cut) }
    return ''
}

function Get-VMOwnedPath {
    <# The files and folders a VM's settings say belong to it, before any check for sharing. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $files = @(
        $Settings.SQLDiskPath
        $Settings.DevDrivePath
        $Settings.SeedDiskPath
        $Settings.OSDiskPath
        $Settings.VSSettingsBackup
        $Settings.GuestCredFile
        $Settings.CertCredFile
        $Settings.CredKeyFile
        $Settings.LogFile
    )
    $folders = @(
        $Settings.CheckpointDir
        $Settings.StateDir
        $Settings.VMConfigDir
        $Settings.ProfileDir
    )

    return [pscustomobject]@{
        Files   = @($files | Where-Object { $_ })
        Folders = @($folders | Where-Object { $_ })
    }
}

function Get-VMRemovalPlan {
    <#
      What removing the VM in $Settings deletes, and what it keeps and why.
      Changes nothing and reads nothing from disk: the caller supplies the
      other VMs' settings and the disks Hyper-V reports, and checks which
      planned items actually exist.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'OtherVMDisks is used inside the reasonToKeep script block, which the analyzer cannot follow.')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [hashtable[]]$OtherSettings = @(),
        [string[]]$AttachedDisks = @(),
        [string[]]$OtherVMDisks = @(),
        [string[]]$ExtraFiles = @(),
        [string[]]$ExtraFolders = @(),
        [Parameter(Mandatory)][string]$ScriptDir
    )

    $configDir = Get-ParentFolder -Path (Get-ParentFolder -Path $Settings.ProfileDir)

    # Used by every VM on the host, so never deleted, nor any folder holding them.
    $protected = @(
        $Settings.Root
        $ScriptDir
        $configDir
        $Settings.VHDXRoot
        $Settings.ISOSearchRoot
        $Settings.ISOPath
        (Get-ParentFolder -Path $Settings.SQLIsoPath)
        $Settings.CredStoreDir
    ) | Where-Object { $_ }

    # Every path another VM's settings name, with the VM it belongs to.
    $otherPaths = @()
    foreach ($other in $OtherSettings) {
        $owned = Get-VMOwnedPath -Settings $other
        foreach ($path in @($owned.Files) + @($owned.Folders)) {
            $otherPaths += [pscustomobject]@{ Path = $path; VM = $other.VMName }
        }
    }

    $kept = [System.Collections.Generic.List[object]]::new()

    $reasonToKeep = {
        param([string]$Candidate)

        foreach ($path in $protected) {
            if (Test-PathWithin -Path $path -Folder $Candidate) {
                return "holds $path, which every VM uses"
            }
        }
        foreach ($other in $otherPaths) {
            if (Test-PathWithin -Path $other.Path -Folder $Candidate) {
                return "VM '$($other.VM)' also uses $($other.Path)"
            }
        }
        foreach ($disk in $OtherVMDisks) {
            if (Test-PathWithin -Path $disk -Folder $Candidate) {
                return "$disk is attached to another VM"
            }
        }
        return $null
    }

    $owned = Get-VMOwnedPath -Settings $Settings
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $files = @()
    foreach ($candidate in @($owned.Files) + @($AttachedDisks) + @($ExtraFiles)) {
        if (-not $candidate -or -not $seen.Add($candidate.TrimEnd('\'))) { continue }
        $reason = & $reasonToKeep $candidate
        if ($reason) { $kept.Add([pscustomobject]@{ Path = $candidate; Reason = $reason }); continue }
        $files += $candidate
    }

    $folders = @()
    foreach ($candidate in @($owned.Folders) + @($ExtraFolders)) {
        if (-not $candidate -or -not $seen.Add($candidate.TrimEnd('\'))) { continue }
        $reason = & $reasonToKeep $candidate
        if ($reason) { $kept.Add([pscustomobject]@{ Path = $candidate; Reason = $reason }); continue }
        $folders += $candidate
    }

    $tasks = @()
    foreach ($taskName in @($Settings.ScheduleTaskName, $Settings.ResumeTaskName)) {
        if (-not $taskName) { continue }
        $sharedWith = @($OtherSettings | Where-Object { $_.ScheduleTaskName -eq $taskName -or $_.ResumeTaskName -eq $taskName })
        if ($sharedWith.Count -gt 0) {
            $kept.Add([pscustomobject]@{ Path = "task $taskName"; Reason = "VM '$($sharedWith[0].VMName)' uses the same task" })
            continue
        }
        $tasks += $taskName
    }

    $registryKey = $null
    if ($Settings.ResumeRegKey) {
        $sharedWith = @($OtherSettings | Where-Object { $_.ResumeRegKey -and (Test-PathWithin -Path $_.ResumeRegKey -Folder $Settings.ResumeRegKey) })
        if ($sharedWith.Count -gt 0) {
            $kept.Add([pscustomobject]@{ Path = $Settings.ResumeRegKey; Reason = "VM '$($sharedWith[0].VMName)' uses $($sharedWith[0].ResumeRegKey)" })
        }
        else {
            $registryKey = $Settings.ResumeRegKey
        }
    }

    return [pscustomobject]@{
        Tasks       = $tasks
        RegistryKey = $registryKey
        Files       = $files
        Folders     = $folders
        Kept        = @($kept)
    }
}

function Get-DiskChain {
    <# A virtual disk and every parent it differences from: a checkpoint's .avhdx back to its .vhdx. #>
    param([Parameter(Mandatory)][string]$Path)

    $chain = @()
    $current = $Path
    while ($current) {
        $chain += $current
        $vhd = Get-VHD -Path $current -ErrorAction SilentlyContinue
        $current = if ($vhd) { $vhd.ParentPath } else { $null }
    }
    return $chain
}

function Get-PathSize {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Item -LiteralPath $Path -Force).Length }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [double]$sum }
    return 0
}

function Remove-PathWithRetry {
    <# Deletes a file or folder, retrying briefly while Hyper-V lets go of a disk it has just released. #>
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $null
        }
        catch {
            if ($attempt -eq 6) { return $_.Exception.Message }
            Start-Sleep -Seconds 5
        }
    }
}

function Get-VMRemovalContext {
    <#
      Works out everything removing the VM would delete, lists it in the
      log, and returns it for Invoke-VMRemoval. Changes nothing. Returns
      $null when nothing of the VM exists.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$ScriptDir
    )

    $settings = $VM.Settings
    Write-LogEntry "REMOVE VM - $($VM.Name)" 'PHASE'

    # Every other VM's settings, read the way a run for that VM would read
    # them, so nothing they use is deleted.
    $otherSettings = @()
    foreach ($name in @(Get-VMProfileName -ConfigDir $settings.ConfigDir)) {
        if ($name -eq $VM.Name) { continue }
        try {
            $otherSettings += (Read-VMSetting -Root $settings.Root -VMName $name).Settings
        }
        catch {
            throw "Cannot tell what VM '$name' uses, so nothing has been removed. Fix its settings first:`n  $($_.Exception.Message)"
        }
    }

    # What Hyper-V knows: this VM's disks with their checkpoint chains, and
    # every disk any other VM has attached. A VM whose profile was created
    # but never built may be removed before Hyper-V is even turned on.
    $hyperVPresent = [bool](Get-Command -Name Get-VM -ErrorAction SilentlyContinue)
    $machine = if ($hyperVPresent) { Get-VM -Name $VM.Name -ErrorAction SilentlyContinue } else { $null }
    $attachedDisks = @()
    $checkpointCount = 0
    if ($machine) {
        foreach ($drive in @(Get-VMHardDiskDrive -VMName $VM.Name)) {
            if ($drive.Path) { $attachedDisks += Get-DiskChain -Path $drive.Path }
        }
        $checkpointCount = @(Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue).Count
    }
    $otherVMDisks = @()
    $otherVMs = if ($hyperVPresent) { @(Get-VM | Where-Object { $_.Name -ne $VM.Name }) } else { @() }
    foreach ($otherVM in $otherVMs) {
        foreach ($drive in @(Get-VMHardDiskDrive -VMName $otherVM.Name)) {
            if ($drive.Path) { $otherVMDisks += Get-DiskChain -Path $drive.Path }
        }
    }

    # Left behind by rebuilds and log rotation, named after the VM.
    $logStem = [IO.Path]::GetFileNameWithoutExtension($settings.LogFile)
    $rotatedLogs = @(Get-ChildItem -LiteralPath (Split-Path -Path $settings.LogFile -Parent) -Filter "$logStem.*.log" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $osDiskStem = [IO.Path]::GetFileNameWithoutExtension($settings.OSDiskPath)
    $extraFiles = @(Get-ChildItem -LiteralPath (Split-Path -Path $settings.OSDiskPath -Parent) -Filter "$osDiskStem.retired-*.vhdx" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $extraFiles += $rotatedLogs
    $extraFolders = @(Get-ChildItem -LiteralPath (Split-Path -Path $settings.VMConfigDir -Parent) -Filter "$(Split-Path -Path $settings.VMConfigDir -Leaf).retired-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    $plan = Get-VMRemovalPlan -Settings $settings -OtherSettings $otherSettings -AttachedDisks $attachedDisks `
        -OtherVMDisks $otherVMDisks -ExtraFiles $extraFiles -ExtraFolders $extraFolders -ScriptDir $ScriptDir

    # Only what is actually there is listed and deleted.
    $tasks = @($plan.Tasks | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue })
    $registryKey = if ($plan.RegistryKey -and (Test-Path -LiteralPath $plan.RegistryKey)) { $plan.RegistryKey } else { $null }
    $files = @($plan.Files | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $folders = @($plan.Folders | Where-Object { Test-Path -LiteralPath $_ -PathType Container })

    if (-not $machine -and $tasks.Count -eq 0 -and -not $registryKey -and $files.Count + $folders.Count -eq 0) {
        Write-LogEntry "Nothing of '$($VM.Name)' was found to remove." 'INFO'
        return $null
    }

    Write-LogEntry "Removing '$($VM.Name)' deletes all of this, and it cannot be undone:" 'WARN'
    if ($machine) {
        Write-LogEntry "  Hyper-V VM   $($VM.Name) ($($machine.State), $checkpointCount checkpoint(s))" 'INFO'
    }
    foreach ($task in $tasks) { Write-LogEntry "  Task         $task" 'INFO' }
    if ($registryKey) { Write-LogEntry "  Registry     $registryKey" 'INFO' }
    $total = 0
    foreach ($path in $files + $folders) {
        $size = Get-PathSize -Path $path
        $total += $size
        Write-LogEntry ("  {0,-12} {1}  ({2})" -f $(if ($files -contains $path) { 'File' } else { 'Folder' }), $path, (Format-Size $size)) 'INFO'
    }
    Write-LogEntry "  Total        $(Format-Size $total)" 'INFO'

    foreach ($item in $plan.Kept) {
        Write-LogEntry "  Kept         $($item.Path) - $($item.Reason)" 'INFO'
    }

    if ($settings.DevDrivePath -and ($files | Where-Object { $_ -eq $settings.DevDrivePath })) {
        Write-LogEntry '' 'INFO'
        Write-LogEntry "The Dev Drive is deleted too: $($settings.DevDrivePath) ($(Format-Size (Get-PathSize -Path $settings.DevDrivePath)))." 'WARN'
        Write-LogEntry '  It holds this VM''s source code. Push or copy anything not yet in source control first.' 'WARN'
    }

    return [pscustomobject]@{
        Machine     = $machine
        Tasks       = $tasks
        RegistryKey = $registryKey
        Files       = $files
        Folders     = $folders
        RotatedLogs = $rotatedLogs
        Total       = $total
    }
}

function Invoke-VMRemoval {
    <#
      Deletes what Get-VMRemovalContext listed. Returns Removed, or
      Incomplete when something could not be deleted (the log says what).
    #>
    [OutputType([RemovalOutcome])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)]$Context
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($task in @($Context.Tasks)) {
        try {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
            Write-LogEntry "Task removed: $task" 'OK'
        }
        catch { $failures.Add("task $task - $($_.Exception.Message)") }
    }

    if ($Context.RegistryKey) {
        try {
            Remove-Item -LiteralPath $Context.RegistryKey -Recurse -Force -ErrorAction Stop
            Write-LogEntry "Registry key removed: $($Context.RegistryKey)" 'OK'
        }
        catch { $failures.Add("$($Context.RegistryKey) - $($_.Exception.Message)") }
    }

    if ($Context.Machine) {
        try {
            if ($Context.Machine.State -ne 'Off') { Stop-VM -Name $VM.Name -TurnOff -Force -ErrorAction Stop }
            Remove-VM -Name $VM.Name -Force -ErrorAction Stop
            Write-LogEntry "Hyper-V VM removed: $($VM.Name)" 'OK'
        }
        catch {
            # The disks are still attached, so deleting them would fail or,
            # worse, half-succeed. Stop with everything else left in place.
            Write-LogError "Could not remove the Hyper-V VM '$($VM.Name)'" $_
            Write-LogEntry 'Its disks and folders have been left in place. Fix the problem and run Remove-LazyVM again.' 'WARN'
            return [RemovalOutcome]::Incomplete
        }
    }

    # The log is written to until the very end, so it and its rotated copies go last.
    $files = @($Context.Files)
    $logFiles = @($files | Where-Object { $_ -eq $VM.Settings.LogFile -or @($Context.RotatedLogs) -contains $_ })
    foreach ($path in @($files | Where-Object { $logFiles -notcontains $_ }) + @($Context.Folders)) {
        # Removing the VM can take its checkpoint files with it.
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $problem = Remove-PathWithRetry -Path $path
        if ($problem) { $failures.Add("$path - $problem") } else { Write-LogEntry "Deleted: $path" 'OK' }
    }

    if ($failures.Count -gt 0) {
        Write-LogList -Heading "'$($VM.Name)' was removed, but $($failures.Count) item(s) could not be deleted:" -Items $failures -Level WARN
        Write-LogEntry 'Delete them by hand, or run Remove-LazyVM again once whatever holds them has let go.' 'INFO'
        return [RemovalOutcome]::Incomplete
    }

    Write-LogEntry "'$($VM.Name)' and everything created for it have been removed ($(Format-Size $Context.Total) freed)." 'OK'

    # Nothing more goes to the log, or it would be written again.
    Stop-Log
    foreach ($path in $logFiles) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }

    # A folder named after the VM that only held its files, such as
    # Backup\<Name>, goes too once it is empty.
    foreach ($parent in @($files | ForEach-Object { Split-Path -Path $_ -Parent } | Sort-Object -Unique)) {
        if ((Split-Path -Path $parent -Leaf) -ne $VM.Name) { continue }
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        if (@(Get-ChildItem -LiteralPath $parent -Force).Count -gt 0) { continue }
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }

    Write-Information "Log deleted: $($VM.Settings.LogFile)" -InformationAction Continue
    return [RemovalOutcome]::Removed
}
