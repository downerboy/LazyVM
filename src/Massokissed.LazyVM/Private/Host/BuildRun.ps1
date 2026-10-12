# BuildRun.ps1 - Running the build phases in order (Build-LazyVM).
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

function Invoke-VMBuild {
    <#
      Runs the build phases for the VM in $CFG, from $FromPhase or the
      resume point left before a host restart, whichever is later. Returns
      'Complete', or 'RestartPending' when the host is restarting to finish
      enabling Hyper-V; the resume task then carries on by itself.
    #>
    param(
        [ValidateRange(0, 8)][int]$FromPhase = 0,
        [switch]$NoUnattend
    )

    $startPhase = [math]::Max($FromPhase, (Get-ResumePhase))
    if ($startPhase -gt 0) { Write-LogEntry "Starting at Phase $startPhase" 'INFO' }

    # The Windows ISO is the one thing LazyVM cannot download, so check for
    # it before anything changes on the host, while whoever started the run
    # is still there to fetch it. Left to Phase 4, a Hyper-V restart would
    # hand it to the resume task, which runs as SYSTEM and can only log it.
    if ($startPhase -le 2) { $null = Resolve-InstallationIso }

    $needsFeatureInstall = $false
    if ($startPhase -le 0) {
        $needsFeatureInstall = @(Repair-HyperVService)[-1] -eq $true
        $null = Test-HostReadiness
    }

    if ($startPhase -le 2) {
        # A function's result is all of its output: only the last item is the answer.
        if (@(Enable-HyperVFeature)[-1] -eq $true) { return 'RestartPending' }
    }
    elseif ($needsFeatureInstall) {
        Write-LogEntry 'Hyper-V services are unhealthy but Phase 2 was skipped by -FromPhase' 'WARN'
    }

    if ($startPhase -le 3) { $null = Initialize-HostFolder }
    if ($startPhase -le 4) { $null = Confirm-InstallMedia }
    else { $null = Resolve-InstallationIso }   # later phases still need a valid ISO path
    if ($startPhase -le 5) {
        $null = Initialize-SqlDataVhd
        $null = Initialize-DevDriveVhd
    }

    $useUnattend = $false
    if ($startPhase -le 6) {
        # The answer-file disc must exist before Phase 6, which attaches it,
        # and is only worth building for a VM that has not been created yet.
        if ($NoUnattend) {
            Write-LogEntry '-NoUnattend: Windows Setup and OOBE will have to be completed by hand' 'WARN'
        }
        elseif (Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue) {
            Write-LogEntry 'VM already exists - not rebuilding the answer-file disc' 'INFO'
        }
        else {
            $guestCredential = Get-GuestCredential -CreateIfMissing
            $null = New-UnattendSeedDisk -GuestCredential $guestCredential
            $useUnattend = $true
        }

        $null = New-GuestVM -UseUnattend:$useUnattend
    }

    if ($startPhase -le 7) {
        $seedAttached = @(
            Get-VMDvdDrive -VMName $CFG.VMName -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $CFG.SeedDiskPath }
        ).Count -gt 0

        $null = Install-GuestSoftware -UsedUnattend:($useUnattend -or $seedAttached)
    }

    if ($startPhase -le 8) { $null = Complete-GuestConfiguration }

    # Only now is the resume point cleared, so a crash mid-resume leaves it
    # in place for the next attempt.
    $null = Unregister-ResumeTask
    return 'Complete'
}
