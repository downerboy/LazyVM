# GuestAppSetting.ps1 - The values under the AppSettings registry keys, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Each key AppSettings lists is read in the guest and kept in VM.json's
# GuestAppSettings (#131) as its values, subkeys included, recorded on every
# maintenance run and every capture, whenever they changed. A key that does
# not exist yet (the application was never started) is left out. A value
# whose name looks secret is listed there by name only: its data is kept in
# the credential store, encrypted, never in VM.json.

function Get-GuestAppSettingSnapshot {
    <#
      Reads each AppSettings key in the guest: Keys (Name, RegistryKey,
      Values: Path, Name, Kind, Data), the names of those that could not be
      read as Failed, and Notes. Binary data comes back as Base64.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $entries = @(foreach ($entry in @($VM.Settings.AppSettings)) { [ordered]@{ Name = "$($entry['Name'])"; RegistryKey = "$($entry['RegistryKey'])" } })
    $entriesJson = ConvertTo-Json -InputObject $entries -Compress

    return Invoke-GuestScript -VM $VM -Activity 'application settings check' -TimeoutMinutes 5 -ArgumentList @($entriesJson) -ScriptBlock {
        param($entriesJson)
        $out = @{ Keys = @(); Failed = @(); Notes = @() }
        foreach ($entry in @($entriesJson | ConvertFrom-Json)) {
            try {
                $hive, $subKey = $entry.RegistryKey -split '\\', 2
                $base = if ($hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
                $root = $base.OpenSubKey($subKey)
                if (-not $root) { continue }
                $values = @()
                $pending = [System.Collections.Generic.Queue[object]]::new()
                $pending.Enqueue([pscustomobject]@{ Path = ''; Key = $root })
                while ($pending.Count -gt 0) {
                    $current = $pending.Dequeue()
                    try {
                        foreach ($name in $current.Key.GetValueNames()) {
                            $kind = "$($current.Key.GetValueKind($name))"
                            if ($kind -notin 'String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary') { continue }
                            $data = $current.Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                            if ($kind -eq 'Binary') { $data = [Convert]::ToBase64String([byte[]]$data) }
                            elseif ($kind -eq 'MultiString') { $data = @($data) }
                            $values += [pscustomobject]@{ Path = $current.Path; Name = $name; Kind = $kind; Data = $data }
                        }
                        foreach ($child in $current.Key.GetSubKeyNames()) {
                            $path = if ($current.Path) { "$($current.Path)\$child" } else { $child }
                            $pending.Enqueue([pscustomobject]@{ Path = $path; Key = $current.Key.OpenSubKey($child) })
                        }
                    }
                    finally { $current.Key.Dispose() }
                }
                $out.Keys += [pscustomobject]@{ Name = $entry.Name; RegistryKey = $entry.RegistryKey; Values = $values }
            }
            catch {
                $out.Failed += $entry.Name
                $out.Notes += New-GuestNote -Level WARN -Text "$($entry.Name) settings could not be read: $($_.Exception.Message)"
            }
        }
        return [pscustomobject]$out
    }
}

function ConvertTo-GuestAppSettingRecord {
    <#
      Turns the keys the guest reported ($Key, from
      Get-GuestAppSettingSnapshot) into VM.json's GuestAppSettings, sorted so
      the same values always compare equal. Returns that list as Record and
      the secret values apart, as Secrets: Name\Path\ValueName -> Kind, Data.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Key)

    $record = [System.Collections.Generic.List[object]]::new()
    $secrets = @{}
    foreach ($item in @($Key | Where-Object { $_ } | Sort-Object -Property Name)) {
        $values = [System.Collections.Generic.List[object]]::new()
        $secretNames = [System.Collections.Generic.List[object]]::new()
        foreach ($value in @($item.Values | Where-Object { $_ } | Sort-Object -Property Path, Name)) {
            $data = if ($value.Kind -eq 'MultiString') { , @($value.Data | ForEach-Object { [string]$_ }) } else { $value.Data }
            if (Test-SecretVariableName -Name $value.Name) {
                $secretNames.Add([ordered]@{ Path = [string]$value.Path; Name = [string]$value.Name })
                $secrets["$($item.Name)\$($value.Path)\$($value.Name)"] = [ordered]@{ Kind = [string]$value.Kind; Data = $data }
            }
            else { $values.Add([ordered]@{ Path = [string]$value.Path; Name = [string]$value.Name; Kind = [string]$value.Kind; Data = $data }) }
        }
        $record.Add([ordered]@{ Name = [string]$item.Name; RegistryKey = [string]$item.RegistryKey; Values = @($values); SecretValues = @($secretNames) })
    }
    return [pscustomobject]@{ Record = @($record); Secrets = $secrets }
}

function Read-GuestAppSettingSecret {
    <# The VM's secret application setting values (Name\Path\ValueName -> Kind, Data); empty when none are stored. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][VMContext]$VM)

    return Get-StoredSecretTable -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.AppSettingsCredFile
}

function Update-GuestAppSettingRecord {
    <#
      Records the values under the AppSettings keys as they are now: in
      VM.json, and the secret ones in the credential store, the store first
      so VM.json never names a secret that has no value. A key or value that
      is gone is removed from the record too; a key that could not be read
      this time keeps what was recorded for it. Writes nothing when nothing
      changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $snapshot = Get-GuestAppSettingSnapshot -VM $VM
    Write-GuestNote -Notes @($snapshot.Notes)

    $converted = ConvertTo-GuestAppSettingRecord -Key @($snapshot.Keys)
    $record = @($converted.Record)
    $secrets = $converted.Secrets
    $failed = @($snapshot.Failed)
    if ($failed.Count -gt 0) {
        $recorded = Get-GuestAppSettingRestore -VM $VM
        if ($recorded) {
            $record = @(@($record) + @($recorded.Keys | Where-Object { $_['Name'] -in $failed }) | Sort-Object -Property { $_['Name'] })
            foreach ($name in @($recorded.Secrets.Keys)) {
                if (($name -split '\\', 2)[0] -in $failed) { $secrets[$name] = $recorded.Secrets[$name] }
            }
        }
    }

    $secretsChanged = (ConvertTo-ComparableJson (Read-GuestAppSettingSecret -VM $VM)) -ne (ConvertTo-ComparableJson $secrets)
    if ($secretsChanged) {
        Save-StoredSecretTable -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.AppSettingsCredFile -UserName 'appsettings' -Secrets $secrets
    }

    $change = @{ $script:GuestAppSettingName = $record }
    $profileChanged = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest application settings changed').Count -gt 0
    if ($profileChanged -or $secretsChanged) {
        Write-LogEntry "Guest application settings recorded: $($record.Count) key(s), $($secrets.Count) value(s) kept encrypted" 'OK'
    }
    return ($profileChanged -or $secretsChanged)
}

function Get-GuestAppSettingRestore {
    <#
      What a restore puts back into the guest: VM.json's GuestAppSettings as
      the file holds it now, as Keys, and the secret values, as Secrets.
      $null when they were never recorded, so a capture from before #131 is
      used instead; an empty Keys when the guest was recorded with none.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $keys = $current[$script:GuestAppSettingName]
    if ($null -eq $keys) { return $null }
    return [pscustomobject]@{ Keys = @($keys); Secrets = (Read-GuestAppSettingSecret -VM $VM) }
}
