# GuestCustomization.ps1 - Windows clean-up and appearance inside the VM.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

function Get-GuestUserSetting {
    <#
      The per-user registry values the settings ask for, as
      @{ Key; Name; Value } relative to a user's hive. Only what is turned on.
    #>
    $values = @()
    if ($CFG.GuestDarkMode) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Value = 0 }
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Value = 0 }
    }
    if ($CFG.GuestShowFileExtensions) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0 }
    }
    if ($CFG.GuestTaskbarLeft) {
        $values += @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Value = 0 }
    }
    if ($CFG.GuestHideTaskbarSearch) {
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
    $userValues = @(Get-GuestUserSetting)
    $apps = @($CFG.GuestRemoveApps)
    if ($apps.Count -eq 0 -and $userValues.Count -eq 0 -and -not $CFG.GuestRemoveOneDrive -and -not $CFG.GuestHideWidgets) { return }

    Write-LogEntry 'Removing built-in apps and applying Windows settings in the guest...' 'INFO'
    try {
        $report = Invoke-GuestScript -Activity 'Windows clean-up' -TimeoutMinutes 20 `
            -ArgumentList @($apps, $userValues, [bool]$CFG.GuestRemoveOneDrive, [bool]$CFG.GuestHideWidgets) -ScriptBlock {
            param($apps, $userValues, $removeOneDrive, $hideWidgets)
            $notes = @()

            foreach ($app in $apps) {
                $found = $false
                foreach ($package in @(Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue)) {
                    $found = $true
                    try { Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop; $notes += "OK|removed $($package.Name)" }
                    catch { $notes += "WARN|could not remove $($package.Name): $($_.Exception.Message)" }
                }
                foreach ($provisioned in @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app)) {
                    $found = $true
                    try { $null = Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction Stop }
                    catch { $notes += "WARN|could not stop $($provisioned.DisplayName) installing for new users: $($_.Exception.Message)" }
                }
                if (-not $found) { $notes += "INFO|$app is not installed" }
            }

            if ($removeOneDrive) {
                Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                $setups = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") +
                    @(Get-ChildItem "$env:ProgramFiles\Microsoft OneDrive\*\OneDriveSetup.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\*\OneDriveSetup.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
                foreach ($setup in $setups | Where-Object { Test-Path $_ }) {
                    $arguments = if ($setup -like "$env:SystemRoot*") { '/uninstall' } else { '/uninstall /allusers' }
                    $p = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
                    $notes += "OK|OneDrive uninstalled ($setup, exit $($p.ExitCode))"
                }
                $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
                New-Item -Path $policy -Force | Out-Null
                New-ItemProperty -Path $policy -Name DisableFileSyncNGSC -Value 1 -PropertyType DWord -Force | Out-Null
                $notes += 'OK|OneDrive turned off by policy'
            }

            if ($hideWidgets) {
                $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
                New-Item -Path $policy -Force | Out-Null
                New-ItemProperty -Path $policy -Name AllowNewsAndInterests -Value 0 -PropertyType DWord -Force | Out-Null
                $notes += 'OK|Widgets turned off'
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
                    if ($LASTEXITCODE -ne 0) { $notes += "WARN|could not open the settings of $($hive.Name)"; continue }
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
            if ($userValues.Count -gt 0) { $notes += "OK|Windows settings applied for $(@($hives).Count - 1) user(s) and for new users" }

            # Signed-in users see the change once Explorer restarts.
            Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            return $notes
        }

        foreach ($line in @($report)) {
            $level, $text = "$line" -split '\|', 2
            Write-LogEntry "  $text" $level
        }
        Write-LogEntry 'Windows clean-up done' 'OK'
    }
    catch {
        Write-LogError 'Windows clean-up failed; the build carries on' $_
    }
}
