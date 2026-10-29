# GuestScheduledTask.ps1 - The scheduled tasks created in the guest, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A task someone created in the root task folder is kept in VM.json's
# GuestScheduledTasks (#131) as the XML Export-ScheduledTask writes,
# recorded on every maintenance run and every capture, whenever the tasks
# changed. LazyVM's own tasks start with its prefix and are left out.

function Get-GuestScheduledTaskSnapshot {
    <#
      Exports the tasks in the guest's root folder: Tasks (Name, Xml), the
      names of those that could not be exported as Failed, and Notes.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'scheduled task check' -TimeoutMinutes 10 -ArgumentList @($script:TaskPrefix) -ScriptBlock {
        param($excludePrefix)
        $out = @{ Tasks = @(); Failed = @(); Notes = @() }
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -notlike "$excludePrefix*" })) {
            try {
                $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
                $out.Tasks += [pscustomobject]@{ Name = $task.TaskName; Xml = [string]$xml }
            }
            catch {
                $out.Failed += $task.TaskName
                $out.Notes += New-GuestNote -Level WARN -Text "scheduled task '$($task.TaskName)' could not be exported: $($_.Exception.Message)"
            }
        }
        return [pscustomobject]$out
    }
}

function ConvertTo-GuestScheduledTaskRecord {
    <# Turns exported tasks (Name, Xml) into VM.json's GuestScheduledTasks, sorted by name so the same tasks always compare equal. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Task)

    foreach ($item in @($Task | Where-Object { $_ } | Sort-Object -Property Name)) {
        [ordered]@{ Name = [string]$item.Name; Xml = ([string]$item.Xml).TrimStart([char]0xFEFF) }
    }
}

function Update-GuestScheduledTaskRecord {
    <#
      Records the guest's own scheduled tasks as they are now in VM.json. A
      task that was removed is removed from the record too; one that could
      not be exported this time keeps what was recorded for it. Writes
      nothing when nothing changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $snapshot = Get-GuestScheduledTaskSnapshot -VM $VM
    Write-GuestNote -Notes @($snapshot.Notes)

    $tasks = @($snapshot.Tasks)
    $failed = @($snapshot.Failed)
    if ($failed.Count -gt 0) {
        $recorded = Get-GuestScheduledTaskRestore -VM $VM
        if ($recorded) { $tasks += @($recorded.Tasks | Where-Object { $_.Name -in $failed }) }
    }
    $record = @(ConvertTo-GuestScheduledTaskRecord -Task $tasks)

    $change = @{ $script:GuestScheduledTaskSettingName = $record }
    $changed = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest scheduled tasks changed').Count -gt 0
    if ($changed) { Write-LogEntry "Guest scheduled tasks recorded: $($record.Count) task(s)" 'OK' }
    return $changed
}

function Get-GuestScheduledTaskRestore {
    <#
      What a restore puts back into the guest: VM.json's GuestScheduledTasks
      as the file holds it now, as Tasks. $null when they were never
      recorded, so a capture from before #131 is used instead; an empty
      Tasks when the guest was recorded with none.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $tasks = $current[$script:GuestScheduledTaskSettingName]
    if ($null -eq $tasks) { return $null }
    return [pscustomobject]@{ Tasks = @($tasks) }
}
