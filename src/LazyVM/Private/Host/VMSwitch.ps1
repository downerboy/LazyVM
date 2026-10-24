# VMSwitch.ps1 - The virtual switch the VM connects to.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Initialize-VMSwitch {
    <#
      The switch to connect the VM to: SwitchName when it exists. Otherwise an
      Internal switch with a NAT network is created (New-VMSwitch has no NAT
      type, and 'Default Switch' is owned by Windows and cannot be recreated).
      Records the switch used in $VM.Runtime.SwitchName and returns it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $existing = Get-VMSwitch -Name $settings.SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LogEntry "Switch '$($settings.SwitchName)' - OK ($($existing.SwitchType))" 'OK'
        $VM.Runtime.SwitchName = $settings.SwitchName
        return $settings.SwitchName
    }

    Write-LogEntry "Switch '$($settings.SwitchName)' not found" 'WARN'

    if (-not (Get-VMSwitch -Name $settings.NatSwitchName -ErrorAction SilentlyContinue)) {
        Write-LogEntry "Creating internal switch '$($settings.NatSwitchName)' with a NAT network..." 'INFO'
        New-VMSwitch -Name $settings.NatSwitchName -SwitchType Internal | Out-Null
    }

    $alias = "vEthernet ($($settings.NatSwitchName))"
    $prefixLength = [int]($settings.NatSubnet -split '/')[1]

    $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $settings.NatHostIP }
    if (-not $ip) {
        New-NetIPAddress -IPAddress $settings.NatHostIP -PrefixLength $prefixLength -InterfaceAlias $alias -ErrorAction Stop | Out-Null
        Write-LogEntry "Host gateway $($settings.NatHostIP)/$prefixLength assigned to '$alias'" 'OK'
    }

    $natNet = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $settings.NatSubnet }
    if (-not $natNet) {
        New-NetNat -Name "$($settings.NatSwitchName)-NAT" -InternalIPInterfaceAddressPrefix $settings.NatSubnet -ErrorAction Stop | Out-Null
        Write-LogEntry "NAT network created for $($settings.NatSubnet)" 'OK'
    }

    Write-LogEntry 'Note: this NAT network has no DHCP server. Set a static address inside the guest,' 'WARN'
    Write-LogEntry "      or switch $($VM.Name) back to 'Default Switch' once it is available." 'WARN'

    $VM.Runtime.SwitchName = $settings.NatSwitchName
    return $settings.NatSwitchName
}
