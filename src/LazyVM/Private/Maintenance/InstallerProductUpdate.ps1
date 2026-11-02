# InstallerProductUpdate.ps1 - Updating the Visual Studio Installer products nightly with their own installer (#293).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Visual Studio Installer manages Visual Studio and SSMS 21 and later.
# winget never upgrades them (#235); the installer's update command does,
# here, while nobody is using them. It is never given --force, which would
# close a product someone has open. An update changes the version, not the
# workloads and components, so the tooling list does not change.
# https://learn.microsoft.com/visualstudio/install/use-command-line-parameters-to-install-visual-studio

function Update-GuestInstallerProduct {
    <#
      Updates each Visual Studio Installer product in the guest
      (Update-InstallerProduct), one after another, starting none once
      $script:InstallerProductUpdateBudgetMinutes are up, and logs each
      result. Returns whether an update needs a restart to finish, which the
      update itself does not make (--norestart): Windows updates make it when
      nobody can be disturbed (Update-GuestWindows -RestartNeeded).
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $products = @(Get-GuestInstallerProduct -VM $VM | ForEach-Object { $_ | Add-Member -NotePropertyName Label -NotePropertyValue $_.DisplayName -PassThru })
    if ($products.Count -eq 0) {
        Write-LogEntry 'Visual Studio Installer products: none in the guest - nothing to update' 'INFO'
        return $false
    }

    Write-LogEntry "Visual Studio Installer products: checking $($products.Count) for updates..." 'INFO'
    $results = @(Invoke-ItemUpdate -Items $products -BudgetMinutes $script:InstallerProductUpdateBudgetMinutes -State $VM -Update {
            param($product, $vm, $deadline)
            Update-InstallerProduct -VM $vm -Product $product -Deadline $deadline
        })
    return [bool]@($results | Where-Object { $_ -and $_.PSObject.Properties['RestartNeeded'] -and $_.RestartNeeded }).Count
}

function Update-InstallerProduct {
    <#
      Updates one Visual Studio Installer product, $Product as
      Get-GuestInstallerProduct lists it, with the installer's update
      command, quietly and without a restart, and returns the result
      (New-UpdateResult), with RestartNeeded when the update needs a restart
      to finish. It is skipped that night while any program runs from its
      folder (devenv or MSBuild for Visual Studio, Ssms.exe for SSMS), or
      when the installer says it is busy or in use. An incomplete product
      is repaired instead (Repair-IncompleteInstallerProduct). One a failed
      update left incomplete is repaired at once only when the installer
      gave up within $script:InstallerProductQuickFailureMinutes minutes and
      $Deadline, when tonight's budget ends, has not passed; otherwise the
      next night's check repairs it, so a timed-out update does not cost the
      night twice.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][object]$Product,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    $label = $Product.Label
    $guest = Invoke-GuestScript -VM $VM -Activity "checking whether $label is in use" -TimeoutMinutes 5 -ArgumentList @($Product.InstallPath) -ScriptBlock {
        param($installPath)
        [pscustomobject]@{ Installer = Get-GuestVisualStudioInstaller; Running = @(Get-GuestProcessNameInFolder -Folder $installPath) }
    }
    if (@($guest.Running).Count -gt 0) {
        return New-UpdateResult -Level INFO -Text "skipped: $label - in use ($(@($guest.Running) -join ', ')); tried again tomorrow"
    }
    if (-not (Test-InstallerProductComplete -Product $Product)) { return Repair-IncompleteInstallerProduct -VM $VM -Product $Product }

    $exitCode = $null
    $failure = $null
    $started = Get-Date
    try {
        $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $guest.Installer -ArgumentList @('update', '--installPath', "`"$($Product.InstallPath)`"", '--quiet', '--norestart') `
            -Name 'installer-product-update' -TimeoutMinutes $VM.Settings.VSInstallMinutes -Activity "the $label update"
    }
    catch { $failure = $_.Exception.Message }
    $after = Get-GuestInstallerProduct -VM $VM | Where-Object { $_.InstanceId -eq $Product.InstanceId } | Select-Object -First 1

    if (Test-InstallSucceeded -ExitCode $exitCode) {
        $result = ConvertTo-UpdateResult -Label $label -Before $Product.Version -After $(if ($after) { $after.Version })
        if ($exitCode -eq 3010) {
            $result.Text += ' - a restart finishes it'
            $result | Add-Member -NotePropertyName RestartNeeded -NotePropertyValue $true
        }
        return $result
    }
    if ($failure) { $reason = $failure }
    else {
        $meaning = $script:VisualStudioInstallerExitMeanings[$exitCode]
        if (-not $meaning) { $meaning = "see the installer's logs. $script:GuestInstallerLogHint" }
        $reason = "exit ${exitCode}: $meaning"
    }

    if ($after -and -not (Test-InstallerProductComplete -Product $after)) {
        $now = Get-Date
        if (-not $failure -and ($now - $started).TotalMinutes -lt $script:InstallerProductQuickFailureMinutes -and $now -lt $Deadline) {
            return Repair-IncompleteInstallerProduct -VM $VM -Product $Product
        }
        return New-UpdateResult -Level WARN -Text "update failed: $label - $reason; left incomplete, repaired tomorrow"
    }
    if ($exitCode -in $script:VisualStudioInstallerBusyExitCodes) {
        return New-UpdateResult -Level INFO -Text "skipped: $label - ${reason}; tried again tomorrow"
    }
    return New-UpdateResult -Level WARN -Text "update failed: $label - $reason"
}

function Repair-IncompleteInstallerProduct {
    <#
      Finishes an incomplete Visual Studio Installer product, $Product as
      Get-GuestInstallerProduct lists it, with the installer's repair
      command, as a build does (Repair-ToolingProduct, which logs the
      repair), and returns the result: repaired, so it is updated from the
      next night, or not, with what to do.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][object]$Product
    )

    $label = $Product.Label
    if (Repair-ToolingProduct -VM $VM -Product ([ToolingProduct]::FromObject($Product)) -InstallPath $Product.InstallPath) {
        return New-UpdateResult -Level OK -Text "repaired: $label - it was incomplete; updated from tomorrow"
    }
    return New-UpdateResult -Level WARN -Text ("repair failed: $label - it is incomplete; open the Visual Studio Installer in the VM and choose " +
        'Resume or Repair for it. Maintenance tries to repair it again tomorrow')
}
