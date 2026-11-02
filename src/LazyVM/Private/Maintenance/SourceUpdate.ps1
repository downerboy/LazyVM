# SourceUpdate.ps1 - Updating the guest's PowerShell Gallery modules and dotnet global tools nightly (#293).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Each source is updated only when the guest has something from it. Both run
# over the session, as the guest account: its dotnet global tools and its own
# Gallery modules are in its profile, and the session's full token lets the
# modules installed for all users update too. Updates change versions, not
# what is installed, so the tooling list does not change.

function Update-GuestSource {
    <#
      One update source, updated over the session. $List, run in the guest,
      lists what the source has there; with nothing, the log says so and that
      is all. Otherwise $Update, run in the guest with that list and the time
      budget, updates it and returns a note for each (Invoke-GuestItemUpdate),
      which is logged. No update starts after 20 minutes, and the session
      gives the updates 30, so none is cut off halfway.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Nothing,
        [Parameter(Mandatory)][scriptblock]$List,
        [Parameter(Mandatory)][scriptblock]$Update
    )

    $items = @(Invoke-GuestScript -VM $VM -Activity "listing for $Source" -TimeoutMinutes 5 -ScriptBlock $List)
    if ($items.Count -eq 0) {
        Write-LogEntry "${Source}: $Nothing - nothing to update" 'INFO'
        return
    }

    $budgetMinutes = 20
    Write-LogEntry "${Source}: checking $($items.Count) for updates..." 'INFO'
    $notes = Invoke-GuestScript -VM $VM -Activity $Source -TimeoutMinutes ($budgetMinutes + 10) -ArgumentList @($items, $budgetMinutes) -ScriptBlock $Update
    Write-GuestNote -Notes @($notes)
}

function Update-GuestGalleryModule {
    <#
      Updates the modules installed from the PowerShell Gallery, in Windows
      PowerShell and in PowerShell 7, each with Update-Module in the edition
      it was installed in. A module still in use keeps working: the new
      version is installed beside it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Update-GuestSource -VM $VM -Source 'PowerShell Gallery updates' -Nothing 'no modules from the PowerShell Gallery in the guest' `
        -List { Get-GuestGalleryModule } `
        -Update { param($modules, $budgetMinutes) Invoke-GuestGalleryModuleUpdate -Modules $modules -BudgetMinutes $budgetMinutes }
}

function Update-GuestDotnetTool {
    <# Updates the guest account's dotnet global tools, each with dotnet tool update. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Update-GuestSource -VM $VM -Source 'dotnet tool updates' -Nothing 'no dotnet global tools in the guest' `
        -List { Get-GuestDotnetTool } `
        -Update { param($tools, $budgetMinutes) Invoke-GuestDotnetToolUpdate -Tools $tools -BudgetMinutes $budgetMinutes }
}
