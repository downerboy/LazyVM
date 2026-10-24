# BuildTooling.ps1 - The tooling list a build installs, and what it could not install.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Get-BuildTooling {
    <#
      The tooling list a build installs: this VM's recorded list, or, for a
      VM that has none yet, the default list that ships with the module.
    #>
    [OutputType([ToolingRecord])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$Quiet
    )

    $recordPath = (Get-ToolingPath -VM $VM).Record
    $record = Read-ToolingRecord -Path $recordPath
    if ($record) {
        if (-not $Quiet) { Write-LogEntry "Installing from this VM's tooling list: $recordPath" 'INFO' }
        return $record
    }

    $defaultPath = Join-Path -Path $script:DataDir -ChildPath $script:DefaultToolingFileName
    $default = Read-ToolingRecord -Path $defaultPath
    if (-not $default) { throw "This VM has no tooling list yet and the default list is missing: $defaultPath" }
    if (-not $Quiet) { Write-LogEntry "This VM has no tooling list yet - installing the default one: $defaultPath" 'INFO' }
    return $default
}

function Save-ToolingTemplate {
    <#
      Keeps the tooling list a build installs as <Name>\Config\Tooling.Template.json,
      so the living Tooling.json can be diffed against what the VM started
      with. Written once: a VM that already has a copy keeps it, so running the
      build again or rebuilding a replacement VM never overwrites it, and
      maintenance never touches it.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingRecord]$Tooling
    )

    $templatePath = (Get-ToolingPath -VM $VM).Template
    if (Test-Path -LiteralPath $templatePath -PathType Leaf) { return }

    # Written as Tooling.json is, so the two diff line for line.
    Save-ToolingRecord -Record $Tooling -Path $templatePath
    Write-LogEntry "Kept a copy of the tooling list this VM is built from: $templatePath" 'INFO'
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
    $recordPath = (Get-ToolingPath -VM $VM).Record
    $record = Read-ToolingRecord -Path $recordPath
    if ($record) {
        $record.AwaitingReinstall = $awaiting
        Save-ToolingRecord -Record $record -Path $recordPath
    }
}
