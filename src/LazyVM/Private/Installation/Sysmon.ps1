# Sysmon.ps1 - The Sysmon built into Windows 11, kept at LazyVM's configuration (#236).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Since February 2026 Sysmon is an optional feature of Windows 11, serviced
# by Windows Update. It records what happens in the VM (processes started,
# network connections, files and registry keys that malware likes) to the
# Microsoft-Windows-Sysmon/Operational event log, which stays in the VM.
# https://learn.microsoft.com/windows/security/operating-system-security/sysmon/how-to-enable-sysmon

function Set-GuestSysmon {
    <#
      Brings Sysmon in the guest to the state LazyVM wants, at every build
      and every night: the feature on, Sysmon installed with the
      configuration in Data\Sysmon, and a 256 MB event log. Only what
      differs is changed. The hash of the configuration last applied is kept
      in the guest's LazyVM registry key, so a LazyVM release with a new
      configuration applies it the next night (sysmon -c, no restart).

      Forgiving: a Windows without the built-in feature (an ISO from before
      February 2026), a standalone Sysmon someone installed, or any failure
      is logged, and the build or maintenance run carries on. The next night
      tries again.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSysmon) {
        Write-LogEntry 'Sysmon turned off in the settings (GuestSysmon) - skipping' 'INFO'
        return
    }

    $configPath = Join-Path -Path $script:DataDir -ChildPath 'Sysmon\sysmonconfig.xml'
    $configText = Get-Content -LiteralPath $configPath -Raw
    $configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    # Big enough that a day of a developer's work does not roll over (Sean's decision on #236).
    $eventLogSizeBytes = 256MB

    try {
        $notes = Invoke-GuestScript -VM $VM -Activity 'Sysmon' -TimeoutMinutes 15 `
            -ArgumentList @($configText, $configHash, $eventLogSizeBytes, $script:GuestMarkerKey) -ScriptBlock {
            param($configText, $configHash, $eventLogSizeBytes, $markerKey)
            $ErrorActionPreference = 'Stop'
            $notes = @()

            # An unknown feature name is an error, not an empty result.
            try { $feature = Get-WindowsOptionalFeature -Online -FeatureName Sysmon }
            catch { $feature = $null }
            if (-not $feature) {
                return New-GuestNote -Level WARN -Text 'Sysmon: this Windows has no built-in Sysmon (it came with the February 2026 update); the next run tries again, after Windows Update has brought it'
            }

            $services = @(Get-Service -Name 'Sysmon*' -ErrorAction SilentlyContinue)
            if ("$($feature.State)" -ne 'Enabled') {
                # The built-in Sysmon cannot run beside the standalone one from Sysinternals.
                if ($services.Count -gt 0) {
                    return New-GuestNote -Level WARN -Text "Sysmon: a standalone Sysmon ($($services[0].Name)) is installed, so LazyVM leaves it as it is; uninstall it (sysmon -u) for LazyVM to set up the built-in one"
                }
                $null = Enable-WindowsOptionalFeature -Online -FeatureName Sysmon -NoRestart
                $notes += New-GuestNote -Level OK -Text 'Sysmon: the built-in feature turned on'
            }

            $sysmon = Get-Command -Name 'sysmon.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $sysmon) {
                return $notes + (New-GuestNote -Level INFO -Text 'Sysmon: not ready until Windows restarts; the next run sets it up')
            }

            $applied = (Get-ItemProperty -Path $markerKey -Name SysmonConfigHash -ErrorAction SilentlyContinue).SysmonConfigHash
            $installed = $services.Count -gt 0
            if (-not $installed -or $applied -ne $configHash) {
                $switch = if ($installed) { '-c' } else { '-i' }
                $configFile = Join-Path -Path $env:TEMP -ChildPath 'LazyVM-sysmonconfig.xml'
                [System.IO.File]::WriteAllText($configFile, $configText)
                try {
                    # Windows PowerShell turns a native program's error output into
                    # errors, which 'Stop' would throw, so it is read as text here.
                    $output = & { $ErrorActionPreference = 'Continue'; & $sysmon.Source $switch $configFile 2>&1 } | Out-String
                }
                finally {
                    Remove-Item -LiteralPath $configFile -Force -ErrorAction SilentlyContinue
                }
                if ($LASTEXITCODE -ne 0) {
                    return $notes + (New-GuestNote -Level WARN -Text "Sysmon: sysmon $switch failed (exit $LASTEXITCODE): $($output.Trim())")
                }
                if (-not (Test-Path -Path $markerKey)) { New-Item -Path $markerKey -Force | Out-Null }
                New-ItemProperty -Path $markerKey -Name SysmonConfigHash -Value $configHash -PropertyType String -Force | Out-Null
                if ($installed) { $notes += New-GuestNote -Level OK -Text 'Sysmon: configuration updated to the one this LazyVM version ships' }
                else { $notes += New-GuestNote -Level OK -Text 'Sysmon installed with LazyVM''s configuration' }
            }
            else {
                $notes += New-GuestNote -Level INFO -Text 'Sysmon: running with LazyVM''s configuration'
            }

            $log = New-Object -TypeName System.Diagnostics.Eventing.Reader.EventLogConfiguration -ArgumentList 'Microsoft-Windows-Sysmon/Operational'
            if ($log.MaximumSizeInBytes -ne $eventLogSizeBytes) {
                $log.MaximumSizeInBytes = $eventLogSizeBytes
                $log.SaveChanges()
                $notes += New-GuestNote -Level OK -Text "Sysmon: event log size set to $($eventLogSizeBytes / 1MB) MB"
            }
            return $notes
        }

        Write-GuestNote -Notes $notes
    }
    catch {
        Write-LogError 'Sysmon set-up failed (non-fatal)' $_
    }
}
