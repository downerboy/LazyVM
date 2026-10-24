# ToolingRecord.ps1 - Each VM's tooling list: building it, comparing it, recording changes.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Each VM's tooling list is Config\VMs\<Name>\Tooling.json. The daily
# maintenance run compares the guest with it and adopts any change, after
# first taking a Hyper-V checkpoint (see Checkpoint.ps1), so every recorded
# version of the list has a checkpoint of the VM as it was then:
#
#   checkpoint  "Tooling <stamp>"                 the VM when it was recorded
#   file        History\Tooling-<stamp>.json      the list recorded with it
#
# A dated copy of the list is also kept for every day the check runs
# (History\Daily), whether or not it changed.
#
# Only additions and removals count as changes. Versions are not compared,
# and version numbers are stripped from program names, so routine updates of
# Visual Studio, SDKs or runtimes never cause a checkpoint.

function Get-NormalizedProgramName {
    <# "LINQPad 9 version 9.10.20" -> "LINQPad 9"; "JetBrains dotPeek 2026.3 EAP 5" -> "JetBrains dotPeek". #>
    param([string]$Name)

    $normalized = $Name
    $normalized = $normalized -replace '\(\s*\d+(\.\d+)+\s*\)', ''
    $normalized = $normalized -replace '\b(version\s+)?v?\d+(\.\d+)+\b', ''
    $normalized = $normalized -replace '\b(EAP|Preview|RC|Beta)\s*\d*\b', ''
    $normalized = $normalized -replace '\s+-\s*$', ''
    $normalized = $normalized -replace '\s{2,}', ' '
    return $normalized.Trim(' ', '-')
}

function Test-ToolingExcluded {
    <# True for winget packages matching one of $Patterns: part of Windows, or managed by the Visual Studio Installer. #>
    param(
        [string]$PackageId,
        [AllowEmptyCollection()][string[]]$Patterns = @()
    )

    foreach ($pattern in $Patterns) {
        if ($PackageId -like $pattern) { return $true }
    }
    return $false
}

function ConvertTo-ToolingRecord {
    <# Reduces an inventory to the tooling list: what is installed, without versions, sorted. #>
    [OutputType([ToolingRecord])]
    param(
        [Parameter(Mandatory)]$Inventory,
        [AllowEmptyCollection()][string[]]$WingetExclude = @()
    )

    $record = [ToolingRecord]::new()
    $record.RecordedAt = (Get-Date).ToString('o')

    $record.Products = [ToolingProduct[]]@(foreach ($item in @($Inventory.Products | Where-Object { $_ })) {
            $product = [ToolingProduct]::new()
            $product.ProductId = $item.ProductId
            $product.ChannelId = $item.ChannelId
            $product.DisplayName = $item.DisplayName
            $product.Components = [string[]]@(@($item.Components) | Where-Object { $_ } | Sort-Object -Unique)
            $product.Extensions = [string[]]@(@($item.ExportedExtensions) | Where-Object { $_ } | Sort-Object -Unique)
            # Marketplace links are looked up afterwards, by Add-MarketplaceItem.
            $product.UserExtensions = [ToolingExtension[]]@(@($item.UserExtensions) | Where-Object { $_ } | ForEach-Object { [ToolingExtension]::FromObject($_) } | Sort-Object Id)
            $product
        }) | Sort-Object { $_.Key() }

    $record.WingetPackages = [WingetPackage[]]@(@($Inventory.WingetPackages) | Where-Object { $_ -and -not (Test-ToolingExcluded -PackageId $_.Id -Patterns $WingetExclude) } |
            ForEach-Object { [WingetPackage]::FromObject($_) } | Sort-Object Id)

    $record.Programs = [ToolingProgram[]]@(@($Inventory.Programs) | Where-Object { $_ } |
            ForEach-Object { $program = [ToolingProgram]::FromObject($_); $program.Name = Get-NormalizedProgramName $program.Name; $program } |
            Group-Object Name | ForEach-Object { $_.Group[0] } | Sort-Object Name)
    return $record
}

function Get-SetChange {
    <# "+ label: item" for each item only in New, "- label: item" for each only in Old. #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [string[]]$Old = @(),
        [string[]]$New = @()
    )

    $oldSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $newSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Old) { if ($item) { [void]$oldSet.Add($item) } }
    foreach ($item in $New) { if ($item) { [void]$newSet.Add($item) } }

    $changes = @()
    foreach ($item in @($newSet | Sort-Object)) { if (-not $oldSet.Contains($item)) { $changes += "+ ${Label}: $item" } }
    foreach ($item in @($oldSet | Sort-Object)) { if (-not $newSet.Contains($item)) { $changes += "- ${Label}: $item" } }
    return $changes
}

function Compare-ToolingRecord {
    <# The additions and removals between two tooling lists, as readable lines. #>
    param(
        [Parameter(Mandatory)][ToolingRecord]$Old,
        [Parameter(Mandatory)][ToolingRecord]$New
    )

    $changes = @()
    foreach ($product in @($New.Products | Sort-Object { $_.Key() })) {
        $before = $Old.FindProduct($product.Key())
        if (-not $before) {
            $changes += "+ product: $($product.DisplayName) [$($product.ProductId), $($product.ChannelId)]"
            continue
        }
        $changes += Get-SetChange -Label "$($product.DisplayName) component" -Old $before.Components -New $product.Components
        $changes += Get-SetChange -Label "$($product.DisplayName) extension" -Old $before.ExtensionIdentities() -New $product.ExtensionIdentities()
    }
    foreach ($product in @($Old.Products | Sort-Object { $_.Key() })) {
        if (-not $New.FindProduct($product.Key())) {
            $changes += "- product: $($product.DisplayName) [$($product.ProductId), $($product.ChannelId)]"
        }
    }

    $changes += Get-SetChange -Label 'winget' -Old @($Old.WingetPackages | ForEach-Object { $_.Id }) -New @($New.WingetPackages | ForEach-Object { $_.Id })
    $changes += Get-SetChange -Label 'program' -Old @($Old.Programs | ForEach-Object { $_.Name }) -New @($New.Programs | ForEach-Object { $_.Name })
    $changes += Get-SetChange -Label 'awaiting reinstall' -Old $Old.Awaiting().Names() -New $New.Awaiting().Names()
    return @($changes)
}

function Get-ToolingPath {
    <# The VM's tooling list and its history folders. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $historyDir = Join-Path $VM.Settings.ProfileDir 'History'
    return [pscustomobject]@{
        Record     = Join-Path $VM.Settings.ProfileDir $script:ToolingFileName
        HistoryDir = $historyDir
        DailyDir   = Join-Path $historyDir 'Daily'
    }
}

function Read-ToolingRecord {
    <# The tooling list at $Path, or $null when there is none. #>
    [OutputType([ToolingRecord])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [ToolingRecord]::FromJson((Get-Content -LiteralPath $Path -Raw))
}

function Save-ToolingRecord {
    param(
        [Parameter(Mandatory)][ToolingRecord]$Record,
        [Parameter(Mandatory)][string]$Path
    )

    # Atomic, so a crash part-way through never leaves a half-written list.
    Write-TextFileAtomic -Path $Path -Text $Record.ToJson()
}

function Update-ToolingRecord {
    <#
      The daily tooling step, also run by Save-LazyVMTooling. Needs an open
      guest session. Returns the changes adopted (none when nothing changed).
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Write-LogEntry "Tooling Check - $($VM.Name)" 'PHASE'

    $paths = Get-ToolingPath -VM $VM
    $current = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude
    $previous = Read-ToolingRecord -Path $paths.Record
    Add-MarketplaceItem -Record $current -Previous $previous
    Merge-AwaitingReinstall -Record $current -Previous $previous

    # The day's copy, kept whether or not anything changed.
    Save-ToolingRecord -Record $current -Path (Join-Path $paths.DailyDir ('Tooling-{0}.json' -f (Get-Date -Format 'yyyyMMdd')))
    $cutoff = (Get-Date).AddDays(-[int]$VM.Settings.ToolingHistoryDays)
    Get-ChildItem -LiteralPath $paths.DailyDir -Filter 'Tooling-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue

    if ($previous) {
        $changes = @(Compare-ToolingRecord -Old $previous -New $current)
        if ($changes.Count -eq 0) {
            Write-LogEntry 'No tooling changes since the last recorded version' 'OK'
            return @()
        }
        Write-LogList -Heading "$($changes.Count) tooling change(s) found:" -Items $changes
    }
    else {
        $changes = @('first recording of this VM''s tooling')
        Write-LogEntry 'No tooling list recorded yet - recording the first one' 'INFO'
    }

    $stamp = Get-ToolingStamp -VM $VM
    try {
        New-ToolingCheckpoint -VM $VM -Name "$script:ToolingCheckpointPrefix $stamp"
    }
    catch {
        Write-LogError 'Could not take the checkpoint, so the changes were NOT recorded; the next run tries again' $_
        return @()
    }

    Save-ToolingRecord -Record $current -Path (Join-Path $paths.HistoryDir "Tooling-$stamp.json")
    Save-ToolingRecord -Record $current -Path $paths.Record
    Write-LogEntry "Tooling list recorded as version $stamp ($($paths.Record))" 'OK'
    return $changes
}
