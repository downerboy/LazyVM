# BuildTooling.ps1 - The tooling list a build installs, and what it could not install.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  BUILDING FROM THE TOOLING LIST
# ─────────────────────────────────────────────────────────────────────────────

function Get-BuildTooling {
    <#
      The tooling list a build installs: this VM's recorded list, or, for a
      VM that has none yet, the default list that ships with the module.
    #>
    param([switch]$Quiet)

    $paths = Get-ToolingPath
    $record = Read-ToolingRecord -Path $paths.Record
    if ($record) {
        if (-not $Quiet) { Write-LogEntry "Installing from this VM's tooling list: $($paths.Record)" 'INFO' }
        return $record
    }

    $defaultPath = Join-Path -Path $script:DataDir -ChildPath 'Tooling.Default.json'
    $default = Read-ToolingRecord -Path $defaultPath
    if (-not $default) { Stop-WithError "This VM has no tooling list yet and the default list is missing: $defaultPath" }
    if (-not $Quiet) { Write-LogEntry "This VM has no tooling list yet - installing the default one: $defaultPath" 'INFO' }
    return $default
}

function Write-ToolingReinstallReport {
    <#
      After a build: what the tooling list has that the guest still lacks,
      because it cannot be installed automatically. Recorded as
      AwaitingReinstall in the VM's tooling list, logged, and written to
      <StateDir>\reinstall-by-hand.txt.
    #>
    param([Parameter(Mandatory)]$Tooling)

    $observed = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory)
    $presentPrograms = @(@($observed.Programs) | ForEach-Object { $_.Name })

    $programs = @()
    foreach ($program in @($Tooling.Programs)) {
        if ($presentPrograms -notcontains $program.Name) {
            $programs += [ordered]@{ Name = $program.Name; Publisher = $program.Publisher }
        }
    }

    $extensions = @()
    foreach ($product in @($Tooling.Products)) {
        $key = "$($product.ProductId)|$($product.ChannelId)"
        $now = @($observed.Products) | Where-Object { "$($_.ProductId)|$($_.ChannelId)" -eq $key } | Select-Object -First 1
        $nowLinks = if ($now) { @($now.Extensions) } else { @() }
        $nowIds = if ($now) { @(@($now.UserExtensions) | ForEach-Object { $_.Id }) } else { @() }
        foreach ($extension in @($product.UserExtensions)) {
            $item = Get-RecordField -Item $extension -Name 'MarketplaceItem'
            if ($nowIds -contains $extension.Id) { continue }
            if ($item -and ($nowLinks -contains "https://marketplace.visualstudio.com/items?itemName=$item")) { continue }
            $extensions += [ordered]@{ ProductKey = $key; Id = $extension.Id; DisplayName = $extension.DisplayName; Publisher = $extension.Publisher }
        }
    }

    $reportPath = Join-Path $CFG.StateDir 'reinstall-by-hand.txt'
    if ($programs.Count + $extensions.Count -eq 0) {
        Write-LogEntry 'Everything in the tooling list is installed' 'OK'
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
        return
    }

    Write-LogEntry "$($programs.Count + $extensions.Count) item(s) in the tooling list could not be installed automatically - install these by hand:" 'WARN'
    $lines = @("Installed before, not reinstalled automatically ($(Get-Date -Format 'yyyy-MM-dd HH:mm')):", '')
    foreach ($program in $programs) {
        Write-LogEntry "  program: $($program.Name)  ($($program.Publisher))" 'WARN'
        $lines += "program    $($program.Name)  ($($program.Publisher))"
    }
    foreach ($extension in $extensions) {
        Write-LogEntry "  Visual Studio extension: $($extension.DisplayName)  [$($extension.Id)]" 'WARN'
        $lines += "extension  $($extension.DisplayName)  [$($extension.Id)]  - Extensions > Manage Extensions"
    }
    if (-not (Test-Path -LiteralPath $CFG.StateDir)) { New-Item -ItemType Directory -Path $CFG.StateDir -Force | Out-Null }
    $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-LogEntry "  List written to $reportPath" 'INFO'

    # Recorded in the VM's tooling list so the next daily run does not take
    # these as uninstalled.
    $paths = Get-ToolingPath
    if (Test-Path -LiteralPath $paths.Record) {
        $record = Get-Content -LiteralPath $paths.Record -Raw | ConvertFrom-Json
        $merged = [ordered]@{}
        foreach ($property in $record.PSObject.Properties) { $merged[$property.Name] = $property.Value }
        $merged['AwaitingReinstall'] = [ordered]@{ Programs = @($programs); Extensions = @($extensions) }
        Save-ToolingRecord -Record $merged -Path $paths.Record
    }
}
