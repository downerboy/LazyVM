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
    Restart-GuestAndWait -VM $VM
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
      The scheduled task's daily work: extends C: into any new space, records
      the guest's tooling and environment, then does nothing more until the
      evaluation is close to expiry, when it captures state and rearms.
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

    # A user who made the OS disk bigger gets the space on C: tonight.
    Expand-GuestSystemDrive -VM $VM

    # Tooling every day. A failure here must not stop the license work below.
    try { $null = Update-ToolingRecord -VM $VM }
    catch { Write-LogError 'Tooling check failed (non-fatal)' $_ }

    # The guest's environment, recorded in VM.json whenever it changed (#131).
    try { $null = Update-GuestEnvironmentRecord -VM $VM }
    catch { Write-LogError 'Environment check failed (non-fatal)' $_ }

    $license = Get-GuestLicenseStatus -VM $VM
    Write-LogEntry "License: $($license.Status); $($license.DaysLeft) day(s) left; $($license.RearmsLeft) rearm(s) remaining" 'INFO'
    $threshold = $VM.Settings.RebuildThresholdDays
    $decision = Get-MaintenanceDecision -DaysLeft $license.DaysLeft -RearmsLeft $license.RearmsLeft -ThresholdDays $threshold

    if ($decision -eq [MaintenanceDecision]::None) {
        if ($license.DaysLeft -lt 0) { Write-LogEntry 'No evaluation countdown reported - nothing to do' 'OK' }
        else { Write-LogEntry "More than $threshold days remain - no action needed" 'OK' }
        if ($wasOff) { Stop-GuestGracefully -VM $VM }
        return [MaintenanceStep]::None
    }

    Write-LogEntry "Evaluation expires in $($license.DaysLeft) day(s) - acting now" 'WARN'

    # Always capture first, so even a rearm that goes wrong leaves a restore point.
    $null = Save-GuestState -VM $VM

    if ($decision -eq [MaintenanceDecision]::Rearm) {
        Write-LogEntry "Attempting rearm ($($license.RearmsLeft) remaining) - this avoids a rebuild" 'INFO'
        if (@(Invoke-GuestRearm -VM $VM)[-1] -eq $true) {
            $after = Get-GuestLicenseStatus -VM $VM
            Write-LogEntry "Rearmed: $($after.DaysLeft) day(s) now remaining, $($after.RearmsLeft) rearm(s) left" 'OK'
            if ($wasOff) { Stop-GuestGracefully -VM $VM }
            return [MaintenanceStep]::Rearmed
        }
        Write-LogEntry 'Rearm did not succeed - falling through to a full rebuild' 'WARN'
    }
    else {
        Write-LogEntry 'No rearms remaining - a full rebuild is required' 'WARN'
    }
    return [MaintenanceStep]::Rebuild
}
