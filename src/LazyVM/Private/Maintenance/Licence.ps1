# Licence.ps1 - Evaluation licence status, rearm and the daily maintenance run.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  WINDOWS EVALUATION LICENCE — STATUS, REARM, AND THE MAINTENANCE CYCLE
#
#  The Windows 11 Enterprise evaluation runs for 90 days. Rather than rebuild
#  every time, the maintenance run first tries slmgr's rearm, which resets the
#  evaluation timer and is supported a limited number of times. Each rearm buys
#  another full period for the price of a reboot. Only when the rearm count is
#  exhausted does the capture / rebuild / restore cycle run.
#
#  The WMI SoftwareLicensing classes are used rather than parsing slmgr.vbs
#  output, which is localised and not machine-readable.
# ─────────────────────────────────────────────────────────────────────────────
function Get-GuestLicenseStatus {
    <# Returns evaluation time remaining, licence state and rearms left. #>

    return Invoke-GuestScript -Activity 'licence status' -TimeoutMinutes 10 -ScriptBlock {
        $ErrorActionPreference = 'Stop'

        # ApplicationID below is the well-known Windows product GUID.
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
            # GracePeriodRemaining is in minutes and is what carries the
            # evaluation countdown on an evaluation image.
            if ($null -ne $product.GracePeriodRemaining) {
                $daysLeft = [math]::Floor([int]$product.GracePeriodRemaining / 1440)
            }
            $description = "$($product.Description)"
        }

        $rearmsLeft = -1
        if ($service -and $null -ne $service.RemainingWindowsReArmCount) {
            $rearmsLeft = [int]$service.RemainingWindowsReArmCount
        }

        return [pscustomobject]@{
            Status      = $statusText
            StatusCode  = if ($product) { [int]$product.LicenseStatus } else { -1 }
            DaysLeft    = $daysLeft
            RearmsLeft  = $rearmsLeft
            Description = $description
            IsEvaluation = ($description -match '(?i)evaluation' -or $statusText -like '*grace*')
            OsCaption   = (Get-CimInstance Win32_OperatingSystem).Caption
            OsBuild     = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        }
    }
}

function Invoke-GuestRearm {
    <# Resets the evaluation timer. Requires a reboot to take effect. #>

    $result = Invoke-GuestScript -Activity 'Windows rearm' -TimeoutMinutes 10 -ScriptBlock {
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
    Restart-GuestAndWait
    return $true
}

function Restart-GuestAndWait {
    $credential = Get-GuestCredential
    Disconnect-Guest
    Restart-VM -Name $CFG.VMName -Force -Wait:$false | Out-Null
    Start-Sleep -Seconds 20
    Wait-GuestReady -Credential $credential -TimeoutMinutes 20 | Out-Null
    Connect-Guest -Credential $credential | Out-Null
}

function Get-LicenseReport {
    <#
      Get-LazyVMLicense: the guest's evaluation licence, read from inside the
      guest, with the last capture. Starts the VM if it is off.
    #>
    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Stop-WithError "VM '$($CFG.VMName)' does not exist yet. Build it with: Build-LazyVM -Name $($CFG.VMName)" }

    $credential = Get-GuestCredential
    if (-not $credential) { Stop-WithError "No stored guest credential. Store one with: Set-LazyVMCredential -Name $($CFG.VMName)" }

    if ($vm.State -ne 'Running') {
        Write-LogEntry "VM is '$($vm.State)' - starting it to read the licence" 'INFO'
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 20 | Out-Null
    }
    Connect-Guest -Credential $credential | Out-Null

    $license = Get-GuestLicenseStatus

    $lastCapture = $null
    $capturedDatabases = 0
    $state = Get-CaptureManifest
    if ($state) {
        $lastCapture = $state.CapturedAt
        # Older captures saved an empty database list as null, or a single
        # name as a plain string, so normalise to an array before counting.
        if ($state.PSObject.Properties['Databases'] -and $null -ne $state.Databases) {
            $capturedDatabases = @($state.Databases).Count
        }
    }

    $decision = Get-MaintenanceDecision -DaysLeft $license.DaysLeft -RearmsLeft $license.RearmsLeft -ThresholdDays $CFG.RebuildThresholdDays
    $nextAction = switch ($decision) {
        'none' { if ($license.DaysLeft -lt 0) { 'None: no evaluation countdown' } else { "None until $($CFG.RebuildThresholdDays) days are left" } }
        'rearm' { 'Rearm at the next maintenance run' }
        'rebuild' { 'Rebuild at the next maintenance run' }
    }

    return [pscustomobject]@{
        PSTypeName        = 'LazyVM.License'
        Name              = $CFG.VMName
        OperatingSystem   = "$($license.OsCaption) (build $($license.OsBuild))"
        License           = $license.Description
        Status            = $license.Status
        DaysLeft          = $(if ($license.DaysLeft -ge 0) { $license.DaysLeft } else { $null })
        RearmsLeft        = $(if ($license.RearmsLeft -ge 0) { $license.RearmsLeft } else { $null })
        NextAction        = $nextAction
        LastCapture       = $lastCapture
        CapturedDatabases = $capturedDatabases
    }
}

function Get-MaintenanceDecision {
    <#
      The rule that decides whether a VM gets rebuilt, kept separate from all
      the VM plumbing so it can be reasoned about and tested on its own.

        none    — plenty of time left, or no evaluation countdown at all
        rearm   — expiry is close and a rearm is available (cheap: one reboot)
        rebuild — expiry is close and rearms are exhausted
    #>
    param(
        [Parameter(Mandatory)][int]$DaysLeft,
        [Parameter(Mandatory)][int]$RearmsLeft,
        [Parameter(Mandatory)][int]$ThresholdDays
    )

    # A negative DaysLeft means the licence reports no countdown, which is what
    # a fully licensed (non-evaluation) Windows looks like. Nothing to do.
    if ($DaysLeft -lt 0) { return 'none' }
    if ($DaysLeft -gt $ThresholdDays) { return 'none' }
    if ($RearmsLeft -gt 0) { return 'rearm' }
    return 'rebuild'
}

function Invoke-Maintenance {
    <#
      The scheduled task's entry point. Runs daily: records the guest's
      tooling (see Update-ToolingRecord), then does nothing more until the
      evaluation is close to expiry, at which point it rearms, or rebuilds if
      rearms are exhausted.
    #>
    Write-LogEntry 'Maintenance Run' 'PHASE'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-LogEntry "VM '$($CFG.VMName)' does not exist - running a normal build instead" 'WARN'
        return 'build'
    }

    $credential = Get-GuestCredential
    if (-not $credential) {
        Write-LogEntry 'No stored guest credential - cannot check the licence.' 'ERROR'
        Write-LogEntry "  Store one with: Set-LazyVMCredential -Name $($CFG.VMName)" 'INFO'
        return 'error'
    }

    $wasOff = ($vm.State -ne 'Running')
    if ($wasOff) {
        Write-LogEntry 'Starting the VM to check its licence' 'INFO'
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 30 | Out-Null
    }
    Connect-Guest -Credential $credential | Out-Null

    # A user who made the OS disk bigger gets the space on C: tonight,
    # with nothing to do inside the guest.
    Expand-GuestSystemDrive

    # Then tooling, every day: record what is installed, taking a checkpoint
    # before adopting any change. A failure here must not stop the licence
    # work below.
    try { Update-ToolingRecord | Out-Null }
    catch { Write-LogError 'Tooling check failed (non-fatal)' $_ }

    $license = Get-GuestLicenseStatus
    Write-LogEntry "Licence: $($license.Status); $($license.DaysLeft) day(s) left; $($license.RearmsLeft) rearm(s) remaining" 'INFO'

    $decision = Get-MaintenanceDecision -DaysLeft $license.DaysLeft `
        -RearmsLeft $license.RearmsLeft -ThresholdDays $CFG.RebuildThresholdDays

    if ($decision -eq 'none') {
        if ($license.DaysLeft -lt 0) { Write-LogEntry 'No evaluation countdown reported - nothing to do' 'OK' }
        else { Write-LogEntry "More than $($CFG.RebuildThresholdDays) days remain - no action needed" 'OK' }
        if ($wasOff) { Stop-GuestGracefully }
        return 'none'
    }

    Write-LogEntry "Evaluation expires in $($license.DaysLeft) day(s) - acting now" 'WARN'

    # Always capture before doing anything, so even a rearm that goes wrong
    # leaves a usable restore point.
    Save-GuestState | Out-Null

    if ($decision -eq 'rearm') {
        Write-LogEntry "Attempting rearm ($($license.RearmsLeft) remaining) - this avoids a rebuild" 'INFO'
        if (Invoke-GuestRearm) {
            $after = Get-GuestLicenseStatus
            Write-LogEntry "Rearmed: $($after.DaysLeft) day(s) now remaining, $($after.RearmsLeft) rearm(s) left" 'OK'
            if ($wasOff) { Stop-GuestGracefully }
            return 'rearmed'
        }
        Write-LogEntry 'Rearm did not succeed - falling through to a full rebuild' 'WARN'
    }
    else {
        Write-LogEntry 'No rearms remaining - a full rebuild is required' 'WARN'
    }

    return 'rebuild'
}

function Stop-GuestGracefully {
    param([int]$TimeoutMinutes = 10)

    Disconnect-Guest
    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -eq 'Off') { return }

    Write-LogEntry 'Shutting the guest down...' 'INFO'
    Stop-VM -Name $CFG.VMName -Force:$false -ErrorAction SilentlyContinue | Out-Null

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -eq 'Off') {
            Write-LogEntry 'Guest is off' 'OK'
            return
        }
        Start-Sleep -Seconds 10
    }

    Write-LogEntry "Guest did not shut down within $TimeoutMinutes minutes - forcing it off" 'WARN'
    Stop-VM -Name $CFG.VMName -TurnOff -Force | Out-Null
}
