# GuestCustomization.ps1 - Windows clean-up and appearance inside the VM.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Get-GuestUserSetting {
    <#
      The per-user registry values the settings ask for, as
      @{ Key; Name; Value } relative to a user's hive. Only what is turned on.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $values = @()
    if ($Settings.GuestDarkMode) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Value = 0 }
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Value = 0 }
    }
    if ($Settings.GuestShowFileExtensions) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0 }
    }
    if ($Settings.GuestTaskbarLeft) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Value = 0 }
    }
    if ($Settings.GuestHideTaskbarSearch) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0 }
    }
    return $values
}

function Set-GuestCustomization {
    <#
      Removes the built-in apps and applies the appearance the settings ask
      for, on every build, so a rebuilt VM looks and behaves like the old one
      without anyone redoing it by hand. Per-user settings go into every
      existing profile and the default profile, so users created later get
      them too. Nothing here stops the build: anything that fails is logged.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $userValues = @(Get-GuestUserSetting -Settings $settings)
    $apps = @($settings.GuestRemoveApps)
    if ($apps.Count -eq 0 -and $userValues.Count -eq 0 -and -not $settings.GuestRemoveOneDrive -and -not $settings.GuestHideWidgets -and -not $settings.GuestDeveloperMode) { return }

    Write-LogEntry 'Removing built-in apps and applying Windows settings in the guest...' 'INFO'
    try {
        $notes = Invoke-GuestScript -VM $VM -Activity 'Windows clean-up' -TimeoutMinutes 20 `
            -ArgumentList @($apps, $userValues, [bool]$settings.GuestRemoveOneDrive, [bool]$settings.GuestHideWidgets, [bool]$settings.GuestDeveloperMode) -ScriptBlock {
            param($apps, $userValues, $removeOneDrive, $hideWidgets, $developerMode)
            $notes = @()

            foreach ($app in $apps) {
                $found = $false
                foreach ($package in @(Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue)) {
                    $found = $true
                    try { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop; $notes += New-GuestNote -Level OK -Text "removed $($package.Name)" }
                    catch { $notes += New-GuestNote -Level WARN -Text "could not remove $($package.Name): $($_.Exception.Message)" }
                }
                foreach ($provisioned in @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app)) {
                    $found = $true
                    try { $null = Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction Stop }
                    catch { $notes += New-GuestNote -Level WARN -Text "could not stop $($provisioned.DisplayName) installing for new users: $($_.Exception.Message)" }
                }
                if (-not $found) { $notes += New-GuestNote -Level INFO -Text "$app is not installed" }
            }

            if ($removeOneDrive) {
                Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                $perMachine = @(Get-ChildItem "$env:ProgramFiles\Microsoft OneDrive\*\OneDriveSetup.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
                $setups = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") + $perMachine
                foreach ($setup in $setups | Where-Object { Test-Path $_ }) {
                    $arguments = if ($setup -like "$env:SystemRoot*") { '/uninstall' } else { '/uninstall /allusers' }
                    $p = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
                    $notes += New-GuestNote -Level OK -Text "OneDrive uninstalled ($setup, exit $($p.ExitCode))"
                }
                $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
                New-Item -Path $policy -Force | Out-Null
                New-ItemProperty -Path $policy -Name DisableFileSyncNGSC -Value 1 -PropertyType DWord -Force | Out-Null
                $notes += New-GuestNote -Level OK -Text 'OneDrive turned off by policy'
            }

            if ($hideWidgets) {
                $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
                New-Item -Path $policy -Force | Out-Null
                New-ItemProperty -Path $policy -Name AllowNewsAndInterests -Value 0 -PropertyType DWord -Force | Out-Null
                $notes += New-GuestNote -Level OK -Text 'Widgets turned off'
            }

            # What Settings > System > For developers > Developer Mode sets.
            # Visual Studio needs it to build and run WinUI and other packaged
            # apps. The key already holds other values, so it is not recreated.
            if ($developerMode) {
                $unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
                if (-not (Test-Path $unlock)) { New-Item -Path $unlock -Force | Out-Null }
                New-ItemProperty -Path $unlock -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force | Out-Null
                $notes += New-GuestNote -Level OK -Text 'Developer Mode turned on'
            }

            # Every profile, and the default profile new users are copied from.
            # A profile in use has its hive loaded already; the rest are
            # loaded for the moment and unloaded again.
            $hives = @([pscustomobject]@{ Name = 'Default'; Sid = $null; Path = "$env:SystemDrive\Users\Default\NTUSER.DAT" })
            $hives += @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath } |
                    ForEach-Object { [pscustomobject]@{ Name = (Split-Path $_.LocalPath -Leaf); Sid = $_.SID; Path = Join-Path $_.LocalPath 'NTUSER.DAT' } })

            $odRun = 'Software\Microsoft\Windows\CurrentVersion\Run'
            foreach ($hive in $hives) {
                $loadedHere = $false
                if ($hive.Sid -and (Test-Path "Registry::HKEY_USERS\$($hive.Sid)")) { $root = "Registry::HKEY_USERS\$($hive.Sid)" }
                elseif (Test-Path $hive.Path) {
                    $mount = "LazyVM_$($hive.Name)"
                    $null = & reg.exe load "HKU\$mount" $hive.Path 2>&1
                    if ($LASTEXITCODE -ne 0) { $notes += New-GuestNote -Level WARN -Text "could not open the settings of $($hive.Name)"; continue }
                    $root = "Registry::HKEY_USERS\$mount"; $loadedHere = $true
                }
                else { continue }

                try {
                    foreach ($v in $userValues) {
                        $key = Join-Path $root $v.Key
                        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                        New-ItemProperty -Path $key -Name $v.Name -Value $v.Value -PropertyType DWord -Force | Out-Null
                    }
                    if ($removeOneDrive) { Remove-ItemProperty -Path (Join-Path $root $odRun) -Name OneDriveSetup, OneDrive -ErrorAction SilentlyContinue }
                }
                finally {
                    if ($loadedHere) {
                        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                        $null = & reg.exe unload "HKU\$mount" 2>&1
                    }
                }
            }
            if ($userValues.Count -gt 0) { $notes += New-GuestNote -Level OK -Text "Windows settings applied for $(@($hives).Count - 1) user(s) and for new users" }

            # Signed-in users see the change once Explorer restarts.
            Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            return $notes
        }

        Write-GuestNote -Notes $notes
        Write-LogEntry 'Windows clean-up done' 'OK'
    }
    catch {
        Write-LogError 'Windows clean-up failed; the build carries on' $_
    }
}
