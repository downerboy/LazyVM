# GuestFirewall.ps1 - The firewall rules added in the guest, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A rule someone added is plain data, so it lives in VM.json's
# GuestFirewallRules (#131), recorded on every maintenance run and every
# capture, whenever the rules changed. Windows' own rules belong to a group,
# and LazyVM's own start with its prefix: neither is recorded.

function Get-GuestFirewallSnapshot {
    <# Reads the enabled rules added in the guest, with their ports and addresses. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'firewall check' -TimeoutMinutes 10 -ArgumentList @($script:TaskPrefix) -ScriptBlock {
        param($excludePrefix)
        foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { -not $_.Group -and $_.Enabled -eq 'True' -and $_.DisplayName -notlike "$excludePrefix*" })) {
            $ports = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $addresses = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            [pscustomobject]@{
                DisplayName   = $rule.DisplayName
                Direction     = "$($rule.Direction)"
                Action        = "$($rule.Action)"
                Protocol      = "$($ports.Protocol)"
                LocalPort     = @($ports.LocalPort)
                RemoteAddress = @($addresses.RemoteAddress)
                Profile       = "$($rule.Profile)"
            }
        }
    }
}

function ConvertTo-GuestFirewallRecord {
    <#
      Turns the rules the guest reported ($Snapshot, from
      Get-GuestFirewallSnapshot) into VM.json's GuestFirewallRules, sorted by
      name so the same rules always compare equal.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Snapshot)

    foreach ($rule in @($Snapshot | Where-Object { $_ } | Sort-Object -Property DisplayName)) {
        [ordered]@{
            DisplayName   = [string]$rule.DisplayName
            Direction     = [string]$rule.Direction
            Action        = [string]$rule.Action
            Protocol      = [string]$rule.Protocol
            LocalPort     = @($rule.LocalPort | ForEach-Object { [string]$_ })
            RemoteAddress = @($rule.RemoteAddress | ForEach-Object { [string]$_ })
            Profile       = [string]$rule.Profile
        }
    }
}

function Update-GuestFirewallRecord {
    <#
      Records the guest's own firewall rules as they are now in VM.json. A
      rule that was removed is removed from the record too. Writes nothing
      when nothing changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $rules = @(ConvertTo-GuestFirewallRecord -Snapshot @(Get-GuestFirewallSnapshot -VM $VM))

    $change = @{ $script:GuestFirewallSettingName = $rules }
    $changed = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest firewall rules changed').Count -gt 0
    if ($changed) { Write-LogEntry "Guest firewall recorded: $($rules.Count) rule(s)" 'OK' }
    return $changed
}

function Get-GuestFirewallRestore {
    <#
      What a restore puts back into the guest: VM.json's GuestFirewallRules
      as the file holds it now, as Rules. $null when they were never
      recorded, so a capture from before #131 is used instead; an empty
      Rules when the guest was recorded with none.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $rules = $current[$script:GuestFirewallSettingName]
    if ($null -eq $rules) { return $null }
    return [pscustomobject]@{ Rules = @($rules) }
}
