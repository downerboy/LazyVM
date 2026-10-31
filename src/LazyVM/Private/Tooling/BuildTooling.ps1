# BuildTooling.ps1 - The tooling list a build installs, and what it could not install.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Get-BuildTooling {
    <#
      The tooling list a build installs: the one in this VM's VM.json, or,
      while VM.json has none yet, the shared template's.
    #>
    [OutputType([ToolingRecord])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$Quiet
    )

    $record = Read-VMTooling -VM $VM
    if ($record) {
        if (-not $Quiet) { Write-LogEntry "Installing from this VM's tooling list, in VM.json" 'INFO' }
        return $record
    }

    if (-not $Quiet) { Write-LogEntry "This VM has no tooling list yet - installing the shared template's" 'INFO' }
    return [ToolingRecord]::FromObject($VM.Settings[$script:ToolingSettingName])
}

function Initialize-VMTooling {
    <#
      After a build: records what the guest has as the VM's tooling list,
      while VM.json has none yet, so the VM has its own list from the start
      rather than from the first daily run (#30). No checkpoint: there is no
      earlier list to go back to.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (Read-VMTooling -VM $VM) { return }

    $current = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude
    # The list the build installed from (the shared template's) keeps its
    # official installers and earlier answers.
    Add-ToolingSource -VM $VM -Record $current -Previous (Get-BuildTooling -VM $VM -Quiet)
    Save-VMTooling -VM $VM -Record $current -Reason 'first tooling list recorded at the end of the build'
    Write-LogEntry "This VM's tooling list recorded in VM.json" 'OK'
}

function Write-ToolingReinstallReport {
    <#
      After a build: what the tooling list has that the guest still lacks,
      because it cannot be installed automatically. Recorded as
      AwaitingReinstall in the VM's tooling list, logged, and written to
      <StateDir>\reinstall-by-hand.txt. The winget packages it lacks are
      logged too: those failed to install, and the next build tries them
      again (#226). Returns $true when nothing is missing.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingRecord]$Tooling
    )

    $observed = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude
    $present = @($observed.Programs | ForEach-Object { $_.Name })

    $awaiting = [AwaitingReinstall]::new()
    $awaiting.Programs = [ToolingProgram[]]@($Tooling.Programs | Where-Object { $_ -and $present -notcontains $_.Name })
    $awaiting.Extensions = [AwaitingExtension[]]@(foreach ($product in @($Tooling.Products)) {
            foreach ($missing in @(Get-MissingProductExtension -Product $product -Observed $observed.FindProduct($product.Key()) | Where-Object { $_.Id })) {
                [AwaitingExtension]::FromObject(@{ ProductKey = $product.Key(); Id = $missing.Id; DisplayName = $missing.DisplayName; Publisher = $missing.Publisher })
            }
        })

    $missingWinget = @(Get-MissingWingetPackage -Tooling $Tooling -Observed $observed -WingetExclude $VM.Settings.ToolingWingetExclude)
    if ($missingWinget.Count -gt 0) {
        Write-LogList -Heading "$($missingWinget.Count) winget package(s) in the tooling list are not installed - run Phase 7 again with -FromPhase 7:" -Items @($missingWinget | ForEach-Object { $_.Id }) -Level WARN
    }

    $allInstalled = ($awaiting.Count() -eq 0) -and ($missingWinget.Count -eq 0)
    $reportPath = Join-Path $VM.Settings.StateDir 'reinstall-by-hand.txt'
    if ($awaiting.Count() -eq 0) {
        if ($allInstalled) { Write-LogEntry 'Everything in the tooling list is installed' 'OK' }
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
        return $allInstalled
    }

    $lines = @($awaiting.Programs | ForEach-Object { "program    $($_.Name)  ($($_.Publisher))" }) +
    @($awaiting.Extensions | ForEach-Object { "extension  $($_.DisplayName)  [$($_.Id)]  - Extensions > Manage Extensions" })
    Write-LogList -Heading "$($awaiting.Count()) item(s) in the tooling list could not be installed automatically - install these by hand:" -Items $lines -Level WARN
    New-Folder -Path $VM.Settings.StateDir
    @("Installed before, not reinstalled automatically ($(Get-Date -Format 'yyyy-MM-dd HH:mm')):", '') + $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-LogEntry "  List written to $reportPath" 'INFO'

    # Recorded in the VM's tooling list, so the next daily run does not take
    # these as uninstalled.
    $record = Read-VMTooling -VM $VM
    if ($record) {
        $record.AwaitingReinstall = $awaiting
        Save-VMTooling -VM $VM -Record $record -Reason 'items to reinstall by hand recorded'
    }
    return $allInstalled
}

function Get-MissingWingetPackage {
    <#
      The winget packages in $Tooling that $Observed, the guest's tooling as
      it is now, does not have. Packages the tooling list excludes are never
      missing: the observed list leaves them out as well.
    #>
    [OutputType([WingetPackage])]
    param(
        [Parameter(Mandatory)][ToolingRecord]$Tooling,
        [Parameter(Mandatory)][ToolingRecord]$Observed,
        [AllowEmptyCollection()][string[]]$WingetExclude = @()
    )

    $installed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Observed.WingetPackages | ForEach-Object { $_.Id }), [StringComparer]::OrdinalIgnoreCase)
    return [WingetPackage[]]@($Tooling.WingetPackages | Where-Object {
            $_ -and $_.Id -and -not $installed.Contains($_.Id) -and -not (Test-ToolingExcluded -PackageId $_.Id -Patterns $WingetExclude)
        })
}
