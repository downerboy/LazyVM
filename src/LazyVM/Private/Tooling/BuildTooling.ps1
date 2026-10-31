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
      <StateDir>\reinstall-by-hand.txt.
    #>
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

    $reportPath = Join-Path $VM.Settings.StateDir 'reinstall-by-hand.txt'
    if ($awaiting.Count() -eq 0) {
        Write-LogEntry 'Everything in the tooling list is installed' 'OK'
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
        return
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
}
