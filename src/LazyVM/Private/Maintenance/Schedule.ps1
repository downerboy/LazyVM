# Schedule.ps1 - The daily maintenance scheduled task (Register-LazyVMMaintenance).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  DAILY MAINTENANCE SCHEDULED TASK  (Register-LazyVMMaintenance)
# ─────────────────────────────────────────────────────────────────────────────
function Register-RebuildSchedule {
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    Write-LogEntry "Daily Maintenance Schedule - $($VM.Name)" 'PHASE'

    # Refuse to schedule an unattended run that cannot possibly authenticate.
    $null = Assert-GuestCredential -VM $VM

    # The time of day comes from the VM's MaintenanceTime, so each VM on the
    # host is maintained at its own time.
    [datetime]$time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($settings.MaintenanceTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$time)) {
        throw "Cannot register the schedule: MaintenanceTime '$($settings.MaintenanceTime)' is not a 24-hour time such as 02:00."
    }

    # Runs DAILY rather than every 90 days, and does nothing until
    # the evaluation is within RebuildThresholdDays of expiring. A task that
    # fired exactly every 90 days would drift past the expiry date, and would
    # miss it entirely if the host happened to be off that day.
    $nextRun = (Get-Date).Date.AddDays(1).Add($time.TimeOfDay)

    # The VM is named in the task; the root folder comes from the registry.
    # Registering again replaces the task, which is how an existing one is
    # updated.
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval 1 -At $nextRun
    $action = New-LazyVMTaskAction -Command "Invoke-LazyVMMaintenance -Name '$($VM.Name)'"
    $taskSettings = New-ScheduledTaskSettingsSet `
        -WakeToRun `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
        -RestartCount 2 `
        -RestartInterval (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $settings.ScheduleTaskName -Trigger $trigger -Action $action `
        -Settings $taskSettings -Principal $principal -Force | Out-Null

    Write-LogEntry "Scheduled task '$($settings.ScheduleTaskName)' registered for VM '$($VM.Name)' - daily at $($settings.MaintenanceTime), first run $($nextRun.ToString('yyyy-MM-dd HH:mm'))" 'OK'
    Write-LogEntry '  Runs daily as SYSTEM and does nothing until the evaluation is within' 'INFO'
    Write-LogEntry "  $($settings.RebuildThresholdDays) days of expiry. It then captures state and rearms Windows;" 'INFO'
    Write-LogEntry '  only when rearms are exhausted does it capture, rebuild and restore.' 'INFO'
}
