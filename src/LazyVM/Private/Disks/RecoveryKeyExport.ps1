# RecoveryKeyExport.ps1 - The BitLocker recovery passwords, exported to a file the user keeps offline (#286).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# LazyVM's copy of the recovery passwords is in its credential store
# (BitLocker.ps1). If that is lost (the profile is deleted, the disk fails,
# the DPAPI keys are lost), only a copy kept elsewhere can unlock the VMs'
# encrypted disks. Export-LazyVMRecoveryKey writes that copy, and records in
# the VM's Config folder which keys it held, by disk GUID and key ID, never
# the passwords. A key not in that record, such as a new disk's or one
# BitLocker gave a new key ID, is reminded of: at the end of a build, in the
# maintenance log, by the next command run by hand on the VM, and by
# Test-LazyVM. In this file, a recovery key is a disk's 48-digit BitLocker
# recovery password.

# How many unexported keys of each VM this run has reminded of, by VM name,
# so a run reminds again only when there are more (Complete-CommandRun
# clears it).
$script:RunRecoveryKeyReminder = @{}

function Get-NoRecoveryKeyMessage {
    <# What to say when no recovery password is stored for the VMs $VMName yet. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$VMName)

    return "No BitLocker recovery password is stored for '$($VMName -join "', '")' yet. Build-LazyVM and the daily maintenance turn BitLocker on and store them."
}

function Get-RecoveryKeyExportCommand {
    <#
      The command the reminders show: every VM's keys to one file, so
      replacing last time's file with it (-Force) never drops another VM's
      keys.
    #>
    [OutputType([string])]
    param()

    return 'Export-LazyVMRecoveryKey -Path <a file on a USB drive>'
}

function Get-RecoveryKeyStamp {
    <# What identifies one exported key in the record: its disk GUID and BitLocker key ID, no secret. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][psobject]$Key)

    return '{0}|{1}' -f "$($Key.DiskGuid)".ToUpperInvariant(), "$($Key.KeyId)".ToUpperInvariant()
}

function Read-RecoveryKeyExportRecord {
    <#
      The VM's record of its last export: when (Exported, as text) and the
      stamps of the keys it held. $null when there is none, or it cannot be
      read, which counts as nothing exported.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $path = $VM.Settings.RecoveryKeyExportFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        return [pscustomobject]@{
            Exported = if ($record.PSObject.Properties['Exported']) { [string]$record.Exported } else { '' }
            Stamps   = @(@($record.Keys) | ForEach-Object { Get-RecoveryKeyStamp -Key $_ })
        }
    }
    catch { return $null }
}

function Save-RecoveryKeyExportRecord {
    <# Records $Keys (from Get-StoredRecoveryKey) as the VM's last export, by disk GUID and key ID only. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Keys
    )

    $record = [ordered]@{
        Exported = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Keys     = @($Keys | ForEach-Object { [ordered]@{ DiskGuid = "$($_.DiskGuid)"; KeyId = "$($_.KeyId)" } })
    }
    Write-TextFileAtomic -Path $VM.Settings.RecoveryKeyExportFile -Text (ConvertTo-Json -InputObject $record -Depth 3)
}

function Select-UnexportedRecoveryKey {
    <# Of the stored $Keys, those the export $Record (from Read-RecoveryKeyExportRecord, or $null) did not hold. #>
    [OutputType('LazyVM.RecoveryPassword')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Keys,
        [AllowNull()][psobject]$Record
    )

    $exported = if ($Record) { $Record.Stamps } else { @() }
    return @($Keys | Where-Object { $exported -notcontains (Get-RecoveryKeyStamp -Key $_) })
}

function Get-UnexportedRecoveryKey {
    <# The VM's stored recovery passwords that its last export did not hold. Throws when the store cannot be read. #>
    [OutputType('LazyVM.RecoveryPassword')]
    param([Parameter(Mandatory)][VMContext]$VM)

    return Select-UnexportedRecoveryKey -Keys @(Get-StoredRecoveryKey -VM $VM) -Record (Read-RecoveryKeyExportRecord -VM $VM)
}

function Write-RecoveryKeyReminder {
    <#
      Reminds, in one line with the command to run, when a recovery password
      of the VM's is not exported yet: shown once, and logged. Within a run,
      only when there are more than it last reminded of. Never throws: a
      reminder must not stop the command it runs in.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        $record = Read-RecoveryKeyExportRecord -VM $VM
        $unexported = @(Select-UnexportedRecoveryKey -Keys @(Get-StoredRecoveryKey -VM $VM) -Record $record)
    }
    catch {
        Write-LogError "Could not check whether the BitLocker recovery passwords of $($VM.Name) are exported (non-fatal)" $_
        return
    }
    $count = $unexported.Count
    $reminded = if ($script:RunRecoveryKeyReminder.ContainsKey($VM.Name)) { $script:RunRecoveryKeyReminder[$VM.Name] } else { 0 }
    if ($count -le $reminded) { return }
    $script:RunRecoveryKeyReminder[$VM.Name] = $count

    # Exported before BitLocker's key ID was known: the passwords are in the file, their key IDs are not.
    $exportedWithoutId = @(if ($record) { $unexported | Where-Object { $record.Stamps -contains ('{0}|' -f "$($_.DiskGuid)".ToUpperInvariant()) } })
    $message = if ($exportedWithoutId.Count -eq $count) {
        "The BitLocker key ID of $count exported recovery password(s) of $($VM.Name) is now known; export again so the file shows it: $(Get-RecoveryKeyExportCommand)"
    }
    else {
        "$count BitLocker recovery password(s) of $($VM.Name) not exported yet. Keep a copy offline with: $(Get-RecoveryKeyExportCommand)"
    }
    Write-LogWarning $message
}

function Format-RecoveryKeyExport {
    <#
      The text of the exported file: what it is for, then each key on lines
      of its own, grouped by VM, so a screen reader reads one field at a time.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Keys)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('LazyVM BitLocker recovery passwords')
    $lines.Add("Exported $(Get-Date -Format 'yyyy-MM-dd HH:mm') from $env:COMPUTERNAME.")
    $lines.Add('')
    $lines.Add('Anyone with this file can unlock these disks. Keep it offline, such as on a USB drive kept somewhere safe, not on this computer or in the cloud.')
    $lines.Add('LazyVM keeps its own encrypted copy; this file is for when that copy is lost.')
    $lines.Add('When BitLocker asks for a recovery key, it shows the start of a key ID. Type the recovery password listed under the same key ID.')
    foreach ($group in @($Keys | Group-Object -Property Name)) {
        $lines.Add('')
        $lines.Add("VM: $($group.Name)")
        foreach ($key in $group.Group) {
            $keyId = if ($key.KeyId) { $key.KeyId } else { 'not known yet; LazyVM learns it at the next maintenance run' }
            $lines.Add('')
            $lines.Add("  Disk: $($key.Disk)")
            $lines.Add("  Disk GUID: $($key.DiskGuid)")
            $lines.Add("  Key ID: $keyId")
            $lines.Add("  Recorded: $(([datetime]$key.Recorded).ToString('yyyy-MM-dd'))")
            $lines.Add("  Recovery password: $($key.RecoveryPassword)")
        }
    }
    return ($lines -join "`r`n") + "`r`n"
}
