# WindowsUpdate.ps1 - Installing Windows updates in the guest, at build and nightly (#234).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Quality and security updates only: feature updates (a new Windows version)
# come with a rebuild, and drivers are left out because the Hyper-V guest
# drivers come with Windows. The guest is restarted for them only when nobody
# is signed in or LazyVM started the VM itself; otherwise the restart is left
# pending and Windows asks the signed-in user when to restart.

function Set-GuestWindowsUpdatePolicy {
    <#
      Windows' own automatic updates: download and install on their schedule
      (AUOptions 4), but never restart while someone is signed in
      (NoAutoRebootWithLoggedOnUsers), so Windows does not restart a VM
      under someone at work in it either. Microsoft warns this can put a
      restart off indefinitely. Automatic sign-in keeps the guest account
      signed in, so a VM that is always running restarts for its updates
      only when its user restarts it; a VM maintenance starts is restarted
      by maintenance (Update-GuestWindows).
      https://learn.microsoft.com/windows/deployment/update/waas-restart
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $null = Invoke-GuestScript -VM $VM -Activity 'Windows Update policy' -TimeoutMinutes 2 -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -LiteralPath $key -Name 'AUOptions' -Value 4 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -LiteralPath $key -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 -PropertyType DWord -Force | Out-Null
    }
}

function Install-GuestWindowsUpdate {
    <#
      Searches for, downloads and installs the guest's quality and security
      updates through the Windows Update Agent API, and logs each one.
      Returns whether Windows needs a restart, for these updates or any
      earlier ones still waiting for it.

      The Windows Update Agent refuses to download or install for a remote
      session, so this runs as a guest task as SYSTEM; that also keeps a
      dropped PowerShell Direct session from losing it. The search leaves out
      drivers (Type='Software'); the loop leaves out feature updates (the
      Upgrades category) and optional ones such as preview updates
      (BrowseOnly). Only updates that downloaded are installed; each that
      did not is logged. Nothing here restarts the guest.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $report = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}windows-update" -Activity 'Windows updates' -TimeoutMinutes 120 -RestartAttempts 1 -Work {
        $ErrorActionPreference = 'Stop'
        $upgradesCategory = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'
        # OperationResultCode: 2 succeeded, 3 succeeded with errors, 4 failed, 5 aborted.
        $resultNames = @{ 2 = 'installed'; 3 = 'installed with errors'; 4 = 'failed'; 5 = 'aborted' }

        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'LazyVM'
        $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates

        $notes = @()
        $wanted = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $found) {
            $isFeatureUpdate = @($update.Categories | Where-Object { $_.CategoryID -eq $upgradesCategory }).Count -gt 0
            if ($isFeatureUpdate) {
                $notes += [pscustomobject]@{ Level = 'INFO'; Text = "skipped feature update: $($update.Title)" }
                continue
            }
            if ($update.BrowseOnly) { continue }
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $null = $wanted.Add($update)
        }

        # Only what downloaded is installed; the rest is tried again next time.
        $downloaded = New-Object -ComObject Microsoft.Update.UpdateColl
        if ($wanted.Count -eq 0) {
            $notes += [pscustomobject]@{ Level = 'OK'; Text = 'no quality or security updates to install' }
        }
        else {
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $wanted
            $null = $downloader.Download()
            foreach ($update in $wanted) {
                if ($update.IsDownloaded) { $null = $downloaded.Add($update) }
                else { $notes += [pscustomobject]@{ Level = 'WARN'; Text = "not downloaded: $($update.Title)" } }
            }
        }

        if ($downloaded.Count -gt 0) {
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $downloaded
            $installed = $installer.Install()
            for ($i = 0; $i -lt $downloaded.Count; $i++) {
                $result = $installed.GetUpdateResult($i)
                $code = [int]$result.ResultCode
                $name = if ($resultNames.ContainsKey($code)) { $resultNames[$code] } else { "result $code" }
                $title = $downloaded.Item($i).Title
                if ($code -eq 2) { $notes += [pscustomobject]@{ Level = 'OK'; Text = "${name}: $title" } }
                else { $notes += [pscustomobject]@{ Level = 'WARN'; Text = ('{0}: {1} [0x{2:X8}]' -f $name, $title, [int]$result.HResult) } }
            }
        }

        $restartNeeded = [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
        # The task's result is one line of text, so the report goes back as JSON.
        return (ConvertTo-Json -InputObject @{ Notes = @($notes); RestartNeeded = $restartNeeded } -Compress -Depth 3)
    }

    $parsed = ConvertFrom-Json -InputObject $report
    Write-GuestNote -Notes @($parsed.Notes)
    return [bool]$parsed.RestartNeeded
}

function Update-GuestWindows {
    <#
      Keeps Windows in the guest patched: sets Windows Update's own policy
      (so a VM built before this gets it too), installs the updates, and
      restarts the guest when they need it and nobody can be disturbed by
      it: LazyVM started the VM itself (-StartedByLazyVM; automatic sign-in
      then signs the guest account in, but nobody is at work in it), or
      nobody is signed in. Otherwise the restart is left pending, and
      Windows asks the signed-in user when to restart.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$StartedByLazyVM
    )

    Write-LogEntry 'Installing Windows updates...' 'INFO'
    $null = Set-GuestWindowsUpdatePolicy -VM $VM
    $restartNeeded = Install-GuestWindowsUpdate -VM $VM
    if (-not $restartNeeded) { return }

    if (-not $StartedByLazyVM) {
        $signedIn = @(Get-GuestSignedInUser -VM $VM)
        if ($signedIn.Count -gt 0) {
            Write-LogEntry "Windows updates: restart pending - $($signedIn -join ', ') signed in to the guest, so Windows asks when to restart" 'INFO'
            return
        }
    }
    Write-LogEntry 'Windows updates: restarting the guest to finish them' 'INFO'
    $null = Restart-GuestGracefully -VM $VM
}
