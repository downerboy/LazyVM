# GuestEnvironment.ps1 - The guest's Windows environment, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The environment variables a user set, PATH, the hosts file's entries and
# mapped drives are plain data, so they live in VM.json's GuestEnvironment
# (#131), recorded on every maintenance run and every capture, whenever they
# changed. A variable whose name looks secret is listed there by name only:
# its value is kept in the credential store, encrypted, never in VM.json.

function Test-SecretVariableName {
    <# Whether an environment variable's name says it holds a secret. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    return $Name -match $script:SecretVariablePattern
}

function Get-GuestEnvironmentSnapshot {
    <#
      Reads the environment in the guest: its variables (all but PATH) for
      the machine and LazyVM's guest account, both PATHs, the hosts file's
      active lines and the account's mapped drives.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'environment check' -TimeoutMinutes 5 -ScriptBlock {
        $out = @{ Machine = @{}; User = @{}; MachinePath = @(); UserPath = @(); Hosts = @(); MappedDrives = @() }
        foreach ($scope in 'Machine', 'User') {
            $variables = [Environment]::GetEnvironmentVariables($scope)
            foreach ($key in $variables.Keys) {
                if ($key -ne 'Path') { $out[$scope][$key] = [string]$variables[$key] }
            }
            $out["${scope}Path"] = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ })
        }
        $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
        $out.Hosts = @(Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' } | ForEach-Object { $_.Trim() })
        # Persistent mappings, which Windows reconnects at sign-in.
        foreach ($drive in @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
            $out.MappedDrives += [pscustomobject]@{ Letter = "$($drive.PSChildName.ToUpperInvariant()):"; Path = "$((Get-ItemProperty $drive.PSPath).RemotePath)" }
        }
        return $out
    }
}

function ConvertTo-GuestEnvironmentRecord {
    <#
      Turns what the guest reported ($Snapshot, from
      Get-GuestEnvironmentSnapshot) into VM.json's GuestEnvironment section,
      leaving out the variables Windows sets itself. Returns that section as
      Record and the secret variables' values apart, as Secrets: Scope\Name
      -> value.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)

    $record = [ordered]@{}
    $secretNames = [System.Collections.Generic.List[object]]::new()
    $secrets = @{}
    foreach ($scope in 'Machine', 'User') {
        $variables = [ordered]@{}
        $source = $Snapshot[$scope]
        foreach ($name in @($source.Keys | Sort-Object)) {
            if ($name -in $script:WindowsVariableNames) { continue }
            if (Test-SecretVariableName -Name $name) {
                $secretNames.Add([ordered]@{ Scope = $scope; Name = $name })
                $secrets["$scope\$name"] = [string]$source[$name]
            }
            else { $variables[$name] = [string]$source[$name] }
        }
        $record["${scope}Variables"] = $variables
    }
    $record.SecretVariables = @($secretNames)
    $record.MachinePath = @($Snapshot.MachinePath | ForEach-Object { [string]$_ })
    $record.UserPath = @($Snapshot.UserPath | ForEach-Object { [string]$_ })
    $record.Hosts = @($Snapshot.Hosts | ForEach-Object { [string]$_ })
    $record.MappedDrives = @($Snapshot.MappedDrives | ForEach-Object { [ordered]@{ Letter = [string]$_.Letter; Path = [string]$_.Path } })

    return [pscustomobject]@{ Record = $record; Secrets = $secrets }
}

function Read-GuestEnvironmentSecret {
    <# The VM's secret variables' values (Scope\Name -> value); empty when none are stored. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][VMContext]$VM)

    return Get-StoredSecretTable -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.EnvironmentCredFile
}

function Save-GuestEnvironmentSecret {
    <# Keeps the secret variables' values, encrypted, replacing what was kept. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Secrets
    )

    Save-StoredSecretTable -KeyPath $VM.Settings.CredKeyFile -Path $VM.Settings.EnvironmentCredFile -UserName 'environment' -Secrets $Secrets
}

function Update-GuestEnvironmentRecord {
    <#
      Records the guest's environment as it is now: in VM.json, and the
      secret values in the credential store, the store first so VM.json never
      names a secret that has no value. A variable, PATH entry, hosts entry or
      drive that was removed is removed from the record too. Writes nothing
      when nothing changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $converted = ConvertTo-GuestEnvironmentRecord -Snapshot (Get-GuestEnvironmentSnapshot -VM $VM)

    $secretsChanged = (ConvertTo-ComparableJson (Read-GuestEnvironmentSecret -VM $VM)) -ne (ConvertTo-ComparableJson $converted.Secrets)
    if ($secretsChanged) { Save-GuestEnvironmentSecret -VM $VM -Secrets $converted.Secrets }

    $change = @{ $script:GuestEnvironmentSettingName = $converted.Record }
    $profileChanged = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest environment changed').Count -gt 0
    if ($profileChanged -or $secretsChanged) {
        $record = $converted.Record
        $counts = @($record.MachineVariables.Count, $record.UserVariables.Count, $record.SecretVariables.Count, $record.Hosts.Count, $record.MappedDrives.Count)
        Write-LogEntry ('Guest environment recorded: {0} machine + {1} user variable(s), {2} kept encrypted, {3} hosts entr(ies), {4} mapped drive(s)' -f $counts) 'OK'
    }
    return ($profileChanged -or $secretsChanged)
}

function Get-GuestEnvironmentRestore {
    <#
      What a restore puts back into the guest: VM.json's GuestEnvironment as
      the file holds it now (it may have been recorded earlier in this run)
      and the secret values. $null when it was never recorded, so a capture
      from before #131 is used instead.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $record = $current[$script:GuestEnvironmentSettingName]
    if (-not $record) { return $null }
    return [pscustomobject]@{ Record = $record; Secrets = (Read-GuestEnvironmentSecret -VM $VM) }
}
