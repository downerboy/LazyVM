# License.ps1 - The Windows evaluation license, rearming it, and the daily maintenance run.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Windows 11 Enterprise evaluation runs for 90 days. Rather than rebuild
# each time, maintenance first rearms, which resets the evaluation timer and
# is allowed a limited number of times: each rearm buys another full period
# for the price of a restart. Only when no rearms are left is the VM
# captured, rebuilt and restored. The license is read from the WMI
# SoftwareLicensing classes rather than slmgr.vbs, whose output is localized.

function Get-GuestLicenseStatus {
    <# Evaluation days left, license state and rearms left, read inside the guest. -1 means "not reported". #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'license status' -TimeoutMinutes 10 -ScriptBlock {
        $ErrorActionPreference = 'Stop'

        # The ApplicationID is the well-known Windows product GUID.
        $product = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        $service = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction SilentlyContinue

        $statusText = 'unknown'
        $daysLeft = -1
        $description = ''
        if ($product) {
            $statusText = switch ([int]$product.LicenseStatus) {
                0 { 'Unlicensed' }
                1 { 'Licensed' }
                2 { 'Initial grace period' }
                3 { 'Additional grace period' }
                4 { 'Non-genuine grace period' }
                5 { 'Notification' }
                6 { 'Extended grace period' }
                default { "Status $($product.LicenseStatus)" }
            }
            # GracePeriodRemaining, in minutes, carries the evaluation countdown.
            if ($null -ne $product.GracePeriodRemaining) { $daysLeft = [math]::Floor([int]$product.GracePeriodRemaining / 1440) }
            $description = "$($product.Description)"
        }
        $rearmsLeft = if ($service -and $null -ne $service.RemainingWindowsReArmCount) { [int]$service.RemainingWindowsReArmCount } else { -1 }

        $os = Get-CimInstance Win32_OperatingSystem
        return [pscustomobject]@{
            Status      = $statusText
            DaysLeft    = $daysLeft
            RearmsLeft  = $rearmsLeft
            Description = $description
            OsCaption   = $os.Caption
            OsBuild     = $os.BuildNumber
        }
    }
}

function Invoke-GuestRearm {
    <# Resets the evaluation timer and restarts the guest to apply it. Returns whether the rearm was accepted. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $result = Invoke-GuestScript -VM $VM -Activity 'Windows rearm' -TimeoutMinutes 10 -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $service = Get-CimInstance -ClassName SoftwareLicensingService
        $before = [int]$service.RemainingWindowsReArmCount
        if ($before -le 0) { return [pscustomobject]@{ Success = $false; Reason = 'no rearms remaining'; Before = $before } }

        $invoke = Invoke-CimMethod -InputObject $service -MethodName 'ReArmWindows'
        if ($invoke.ReturnValue -ne 0) {
            return [pscustomobject]@{ Success = $false; Reason = "ReArmWindows returned $($invoke.ReturnValue)"; Before = $before }
        }
        return [pscustomobject]@{ Success = $true; Reason = ''; Before = $before }
    }

    if (-not $result.Success) {
        Write-LogEntry "Rearm failed: $($result.Reason)" 'WARN'
        return $false
    }
    Write-LogEntry "Rearm accepted (had $($result.Before) remaining) - restarting the guest to apply it" 'OK'
    $null = Restart-GuestGracefully -VM $VM
    return $true
}

function Get-MaintenanceDecision {
    <#
      The rule that decides whether a VM is rearmed or rebuilt, kept apart
      from the VM plumbing so it can be tested on its own. A negative
      DaysLeft means no countdown, which is what licensed Windows looks like.
    #>
    [OutputType([MaintenanceDecision])]
    param(
        [Parameter(Mandatory)][int]$DaysLeft,
        [Parameter(Mandatory)][int]$RearmsLeft,
        [Parameter(Mandatory)][int]$ThresholdDays
    )

    if ($DaysLeft -lt 0 -or $DaysLeft -gt $ThresholdDays) { return [MaintenanceDecision]::None }
    if ($RearmsLeft -gt 0) { return [MaintenanceDecision]::Rearm }
    return [MaintenanceDecision]::Rebuild
}

function Get-MaintenancePreview {
    <#
      Invoke-LazyVMMaintenance -WhatIf (#18): what a run would do, as one
      sentence. Reads the VM's state and, while it is running, its
      evaluation; changes nothing, and does not start a VM that is off.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if (-not $machine) { return "Build the VM: it does not exist yet" }
    $daily = 'Run the daily checks (C: size, User disk, BitLocker, tooling and settings records, database backups, Windows updates)'
    if ("$($machine.State)" -ne 'Running') {
        return "Start the VM, which is $($machine.State), then $($daily.Substring(0, 1).ToLower())$($daily.Substring(1)) and act on its evaluation, which was not read while the VM is not running"
    }

    $null = Open-GuestSession -VM $VM -Purpose 'read the license'
    $license = Get-GuestLicenseStatus -VM $VM
    $threshold = $VM.Settings.RebuildThresholdDays
    switch (Get-MaintenanceDecision -DaysLeft $license.DaysLeft -RearmsLeft $license.RearmsLeft -ThresholdDays $threshold) {
        ([MaintenanceDecision]::None) {
            if ($license.DaysLeft -lt 0) { return "$daily; no evaluation countdown, so nothing more" }
            return "$daily, and capture the state if it changed; $($license.DaysLeft) day(s) of evaluation left, more than $threshold, so no rearm or rebuild"
        }
        ([MaintenanceDecision]::Rearm) { return "$daily, then capture the state and rearm Windows: $($license.DaysLeft) day(s) left, within $threshold, and $($license.RearmsLeft) rearm(s) left" }
        ([MaintenanceDecision]::Rebuild) { return "$daily, then capture the state and rebuild the VM: $($license.DaysLeft) day(s) left and no rearms left" }
    }
}

function Get-LicenseReport {
    <# Get-LazyVMLicense: the guest's evaluation license, with the last capture. Starts the VM if it is off. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $null = Open-GuestSession -VM $VM -Purpose 'read the license'
    $license = Get-GuestLicenseStatus -VM $VM
    $capture = Get-CaptureManifest -VM $VM
    $threshold = $VM.Settings.RebuildThresholdDays

    $nextAction = switch (Get-MaintenanceDecision -DaysLeft $license.DaysLeft -RearmsLeft $license.RearmsLeft -ThresholdDays $threshold) {
        ([MaintenanceDecision]::None) { if ($license.DaysLeft -lt 0) { 'None: no evaluation countdown' } else { "None until $threshold days are left" } }
        ([MaintenanceDecision]::Rearm) { 'Rearm at the next maintenance run' }
        ([MaintenanceDecision]::Rebuild) { 'Rebuild at the next maintenance run' }
    }

    return [pscustomobject]@{
        PSTypeName        = 'LazyVM.License'
        Name              = $VM.Name
        OperatingSystem   = "$($license.OsCaption) (build $($license.OsBuild))"
        License           = $license.Description
        Status            = $license.Status
        DaysLeft          = $(if ($license.DaysLeft -ge 0) { $license.DaysLeft } else { $null })
        RearmsLeft        = $(if ($license.RearmsLeft -ge 0) { $license.RearmsLeft } else { $null })
        NextAction        = $nextAction
        LastCapture       = $(if ($capture) { $capture.CapturedAt } else { $null })
        CapturedDatabases = $(if ($capture) { $capture.Databases.Count } else { 0 })
    }
}

function Invoke-Maintenance {
    <#
      The scheduled task's daily run: opens the guest, starting the VM if it
      is off, runs the day's work (Invoke-DailyMaintenance) and, however that
      ends, shuts a VM it started down again, even when a step threw, such as
      a restart for updates that left the guest unreachable. A VM about to be
      rebuilt is left to the rebuild.
      Returns what the caller does next.
    #>
    [OutputType([MaintenanceStep])]
    param([Parameter(Mandatory)][VMContext]$VM)

    Write-LogEntry 'Maintenance Run' 'PHASE'

    if (-not (Get-VM -Name $VM.Name -ErrorAction SilentlyContinue)) {
        Write-LogEntry "VM '$($VM.Name)' does not exist - running a normal build instead" 'WARN'
        return [MaintenanceStep]::Build
    }
    try { $wasOff = Open-GuestSession -VM $VM -Purpose 'check its license' }
    catch {
        Write-LogError 'Could not reach the guest to check its license' $_
        return [MaintenanceStep]::Error
    }

    $step = $null
    try {
        $step = Invoke-DailyMaintenance -VM $VM -StartedByLazyVM:$wasOff
        return $step
    }
    finally {
        if ($wasOff -and $step -ne [MaintenanceStep]::Rebuild) {
            # Logged rather than thrown, so it never hides why the run failed.
            try { $null = Stop-GuestGracefully -VM $VM }
            catch { Write-LogError 'Could not shut the VM down again after maintenance' $_ }
        }
    }
}

function Invoke-DailyMaintenance {
    <#
      The day's work in an open guest: extends C: into any new space, puts
      the personal folders on the User disk, turns BitLocker on for C: and
      the persistent disks, copies the User disk when it changed, records
      the guest's tooling, environment, firewall rules, scheduled tasks, SQL
      logins and Agent jobs, and application settings, checks and backs up
      the databases, asks the Store to update its apps, installs Windows
      updates, then does nothing more until the evaluation is close to
      expiry, when it captures state and rearms. -StartedByLazyVM: the run
      started the VM, so nobody is at work in it.
      Returns what the caller does next.
    #>
    [OutputType([MaintenanceStep])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$StartedByLazyVM
    )

    # A user who made the OS disk bigger gets the space on C: tonight.
    $null = Expand-GuestSystemDrive -VM $VM

    # An older VM gets its User disk, and what C: holds since yesterday is copied to it (#137).
    try { $null = Install-UserDisk -VM $VM }
    catch { Write-LogError 'User disk set-up failed (non-fatal)' $_ }

    # BitLocker on C: and every persistent disk; an older VM's disks are encrypted whole, in the background (#175).
    try { $null = Protect-GuestPersistentDisk -VM $VM }
    catch { Write-LogError 'BitLocker check failed (non-fatal)' $_ }

    # One copy of the User disk, still encrypted, made only when its files changed (#139).
    try { $null = Backup-UserDisk -VM $VM }
    catch { Write-LogError 'User disk copy failed (non-fatal)' $_ }

    # Tooling every day. A failure here must not stop the license work below.
    try { $null = Update-ToolingRecord -VM $VM }
    catch { Write-LogError 'Tooling check failed (non-fatal)' $_ }

    # The guest's environment, firewall rules, scheduled tasks, SQL logins and Agent jobs, and application settings, recorded in VM.json whenever they changed (#131).
    try { $null = Update-GuestEnvironmentRecord -VM $VM }
    catch { Write-LogError 'Environment check failed (non-fatal)' $_ }
    try { $null = Update-GuestFirewallRecord -VM $VM }
    catch { Write-LogError 'Firewall check failed (non-fatal)' $_ }
    try { $null = Update-GuestScheduledTaskRecord -VM $VM }
    catch { Write-LogError 'Scheduled task check failed (non-fatal)' $_ }
    try { $null = Update-GuestSqlRecord -VM $VM }
    catch { Write-LogError 'SQL logins, settings and Agent check failed (non-fatal)' $_ }
    try { $null = Update-GuestAppSettingRecord -VM $VM }
    catch { Write-LogError 'Application settings check failed (non-fatal)' $_ }

    # Every user database checked with DBCC CHECKDB and, when it passes, backed up: one good backup of each (#133).
    try { $null = Backup-GuestUserDatabase -VM $VM }
    catch { Write-LogError 'Database check and backup failed (non-fatal)' $_ }

    # The Store updates its apps only while the VM is on, so it is asked to check every night (#233).
    try { $null = Start-GuestStoreAppUpdate -VM $VM }
    catch { Write-LogError 'Store app update check failed (non-fatal)' $_ }

    # Windows updates, after tonight's records and backups so a bad update still has them, and before the
    # license check. The guest is restarted for them only when nobody can be disturbed by it (#234).
    try { $null = Update-GuestWindows -VM $VM -StartedByLazyVM:$StartedByLazyVM }
    catch { Write-LogError 'Windows updates failed (non-fatal)' $_ }

    $license = Get-GuestLicenseStatus -VM $VM
    Write-LogEntry "License: $($license.Status); $($license.DaysLeft) day(s) left; $($license.RearmsLeft) rearm(s) remaining" 'INFO'
    $threshold = $VM.Settings.RebuildThresholdDays
    $decision = Get-MaintenanceDecision -DaysLeft $license.DaysLeft -RearmsLeft $license.RearmsLeft -ThresholdDays $threshold

    if ($decision -eq [MaintenanceDecision]::None) {
        if ($license.DaysLeft -lt 0) { Write-LogEntry 'No evaluation countdown reported - nothing to do' 'OK' }
        else { Write-LogEntry "More than $threshold days remain - no action needed" 'OK' }
        # A full capture whenever the guest changed in a way only a capture keeps (#20).
        try { if (Test-GuestStateChanged -VM $VM) { $null = Save-GuestState -VM $VM } }
        catch { Write-LogError 'State change check or capture failed (non-fatal)' $_ }
        return [MaintenanceStep]::None
    }

    Write-LogEntry "Evaluation expires in $($license.DaysLeft) day(s) - acting now" 'WARN'

    # Always capture first, so even a rearm that goes wrong leaves a restore point.
    $null = Save-GuestState -VM $VM

    if ($decision -eq [MaintenanceDecision]::Rearm) {
        Write-LogEntry "Attempting rearm ($($license.RearmsLeft) remaining) - this avoids a rebuild" 'INFO'
        if (Invoke-GuestRearm -VM $VM) {
            $after = Get-GuestLicenseStatus -VM $VM
            Write-LogEntry "Rearmed: $($after.DaysLeft) day(s) now remaining, $($after.RearmsLeft) rearm(s) left" 'OK'
            return [MaintenanceStep]::Rearmed
        }
        Write-LogEntry 'Rearm did not succeed - falling through to a full rebuild' 'WARN'
    }
    else {
        Write-LogEntry 'No rearms remaining - a full rebuild is required' 'WARN'
    }
    return [MaintenanceStep]::Rebuild
}
