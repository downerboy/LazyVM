# VisualStudioUpdate.ps1 - Updating Visual Studio nightly with its own installer (#293).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# winget never upgrades Visual Studio (#235); its installer's update command
# does, here, while nobody is using it. SSMS, which the same installer
# manages, is left out. An update changes the version, not the workloads and
# components, so the tooling list does not change.
# https://learn.microsoft.com/visualstudio/install/use-command-line-parameters-to-install-visual-studio

function Update-GuestVisualStudio {
    <#
      Updates each Visual Studio in the guest with the Visual Studio
      Installer's update command, quietly and without a restart; one that
      needs a restart finishes at the next one, such as Windows updates'.
      A Visual Studio with any program running from its folder (devenv,
      MSBuild) is skipped that night, so an open IDE is never closed. No
      update starts after 45 minutes. Each result is logged.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $products = @(Get-GuestInstallerProduct -VM $VM | Where-Object { [ToolingProduct]::IsVisualStudio($_.ProductId) })
    if ($products.Count -eq 0) {
        Write-LogEntry 'Visual Studio updates: no Visual Studio in the guest - nothing to update' 'INFO'
        return
    }

    $deadline = (Get-Date).AddMinutes(45)
    Write-LogEntry "Visual Studio updates: checking $($products.Count) for updates..." 'INFO'
    foreach ($product in $products) {
        $label = $product.DisplayName
        if ((Get-Date) -ge $deadline) {
            Write-LogEntry "  not started: $label - tonight's time for updates ran out; tried again tomorrow" 'INFO'
            continue
        }
        $guest = Invoke-GuestScript -VM $VM -Activity "checking whether $label is in use" -TimeoutMinutes 5 -ArgumentList @($product.InstallPath) -ScriptBlock {
            param($installPath)
            [pscustomobject]@{ Installer = Get-GuestVisualStudioInstaller; Running = @(Get-GuestProcessInFolder -Folder $installPath) }
        }
        if (@($guest.Running).Count -gt 0) {
            Write-LogEntry "  skipped: $label - in use ($(@($guest.Running) -join ', ')); tried again tomorrow" 'INFO'
            continue
        }

        $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $guest.Installer -ArgumentList @('update', '--installPath', "`"$($product.InstallPath)`"", '--quiet', '--norestart') `
            -Name 'vs-update' -TimeoutMinutes $VM.Settings.VSInstallMinutes -Activity "the $label update"
        if (-not (Test-InstallSucceeded -ExitCode $exitCode)) {
            $meaning = $script:VisualStudioInstallerExitMeanings[$exitCode]
            if (-not $meaning) { $meaning = "see the installer's logs: $script:GuestInstallerLogHint" }
            Write-LogEntry "  update failed: $label - exit ${exitCode}: $meaning" 'WARN'
            continue
        }
        $after = @(Get-GuestInstallerProduct -VM $VM | Where-Object { $_.InstanceId -eq $product.InstanceId })[0].Version
        $restart = if ($exitCode -eq 3010) { ' - a restart finishes it' } else { '' }
        if ($after -eq $product.Version) { Write-LogEntry "  up to date: $label $after$restart" 'INFO' }
        else { Write-LogEntry "  updated: $label $($product.Version) -> $after$restart" 'OK' }
    }
}
