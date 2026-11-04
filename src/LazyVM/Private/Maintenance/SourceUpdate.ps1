# SourceUpdate.ps1 - Updating the guest's PowerShell Gallery modules and dotnet global tools nightly (#293).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Each source is updated only when the guest has something from it. Both run
# over the session, as the guest account: its dotnet global tools and its own
# Gallery modules are in its profile, and the session's full token lets the
# modules installed for all users update too. Updates change versions, not
# what is installed, so the tooling list does not change.
#
# Invoke-ItemUpdate, shared with the installer product updates, holds the time
# budget: each item is updated on its own, its result logged as it comes.

function New-UpdateResult {
    <# One nightly update's result, as @{ Level; Text }: Level is INFO, OK, WARN or ERROR, as Write-LogEntry takes it. #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )

    return [pscustomobject]@{ Level = $Level; Text = $Text }
}

function ConvertTo-UpdateResult {
    <#
      What updating $Label did, from its version before and after: updated,
      up to date, or, with no version after, failed (New-UpdateResult).
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Before = '',
        [AllowNull()][object]$After
    )

    if (-not "$After") { return New-UpdateResult -Level WARN -Text "update failed: $Label - its version could not be read afterwards" }
    if ("$After" -eq $Before) { return New-UpdateResult -Level INFO -Text "up to date: $Label $After" }
    return New-UpdateResult -Level OK -Text "updated: $Label $Before -> $After"
}

function Invoke-ItemUpdate {
    <#
      Updates each of $Items, each @{ Label; ... }, with $Update, and logs
      each result as it comes, and returns it. $Update is given the item,
      $State (whatever the caller needs, as Wait-Until's -State) and the
      [datetime] tonight's budget ends at; it returns the item's result
      (New-UpdateResult; it may carry more for its caller). One that throws
      is logged as failed, and the next item goes on. Once $BudgetMinutes,
      counted from now, are up, no update starts.
    #>
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()][object[]]$Items = @(),
        [Parameter(Mandatory)][int]$BudgetMinutes,
        [Parameter(Mandatory)][scriptblock]$Update,
        [object]$State
    )

    $deadline = (Get-Date).AddMinutes($BudgetMinutes)
    foreach ($current in $Items) {
        if ((Get-Date) -ge $deadline) {
            $outcome = New-UpdateResult -Level INFO -Text "not started: $($current.Label) - tonight's time for updates ran out; tried again tomorrow"
        }
        else {
            try { $outcome = & $Update $current $State $deadline | Select-Object -Last 1 }
            catch { $outcome = New-UpdateResult -Level WARN -Text "update failed: $($current.Label) - $($_.Exception.Message)" }
        }
        Write-LogEntry "  $($outcome.Text)" $outcome.Level
        $outcome
    }
}

function Update-GuestSource {
    <#
      One update source, updated over the session. $List, run in the guest,
      returns @{ Items; Notes }: what the source has there, each item
      @{ Label; Version; ... }, and notes for the log (New-GuestNote). With
      no items, the log says $EmptyMessage and that is all. Otherwise each
      item is updated by $Update, run in the guest with the item in a guest
      call of its own, which returns @{ Version; Notes }: its version after,
      or $null, and notes for the log.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$EmptyMessage,
        [Parameter(Mandatory)][scriptblock]$List,
        [Parameter(Mandatory)][scriptblock]$Update
    )

    $listing = Invoke-GuestScript -VM $VM -Activity "listing for $Label" -TimeoutMinutes 5 -ScriptBlock $List
    Write-GuestNote -Notes @($listing.Notes)
    $items = @($listing.Items | Where-Object { $_ })
    if ($items.Count -eq 0) {
        Write-LogEntry "${Label}: $EmptyMessage - nothing to update" 'INFO'
        return
    }

    Write-LogEntry "${Label}: checking $($items.Count) for updates..." 'INFO'
    $null = Invoke-ItemUpdate -Items $items -BudgetMinutes $script:SourceUpdateBudgetMinutes -State @{ VM = $VM; Label = $Label; Update = $Update } -Update {
        param($item, $state)
        $after = Invoke-GuestScript -VM $state.VM -Activity "$($state.Label) - $($item.Label)" -TimeoutMinutes $script:SourceUpdateItemTimeoutMinutes `
            -ArgumentList @($item) -ScriptBlock $state.Update
        Write-GuestNote -Notes @($after.Notes)
        ConvertTo-UpdateResult -Label $item.Label -Before $item.Version -After $after.Version
    }
}

function Update-GuestGalleryModule {
    <#
      Updates the modules installed from the PowerShell Gallery, in Windows
      PowerShell and in PowerShell 7, each in the edition it was installed
      in, and only when the Gallery has a newer version, which goes in beside
      the old one; the version it made old is removed, so the two newest are
      kept (Invoke-GuestGalleryModuleUpdate). PowerShellGet and PackageManagement
      are left alone (Get-GuestGalleryModule). Removals recorded for modules
      no longer installed are forgotten, in the editions listed only, so an
      edition that could not be asked keeps its own (#309).
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Update-GuestSource -VM $VM -Label 'PowerShell Gallery updates' -EmptyMessage 'no modules from the PowerShell Gallery in the guest' `
        -List {
        $listing = Get-GuestGalleryModule
        foreach ($edition in @($listing.Editions)) { Remove-GuestModuleRemovalStale -Edition $edition -Label @($listing.Items.Label) }
        $listing
    } `
        -Update { param($module) Invoke-GuestGalleryModuleUpdate -Module $module }
}

function Update-GuestDotnetTool {
    <# Updates the guest account's dotnet global tools, each with dotnet tool update. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Update-GuestSource -VM $VM -Label 'dotnet tool updates' -EmptyMessage 'no dotnet global tools in the guest' `
        -List { [pscustomobject]@{ Items = @(Get-GuestDotnetTool); Notes = @() } } `
        -Update { param($tool) Invoke-GuestDotnetToolUpdate -Tool $tool }
}
