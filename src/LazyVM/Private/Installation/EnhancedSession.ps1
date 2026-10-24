# EnhancedSession.ps1 - Clipboard and drive sharing in VMConnect.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Enable-GuestEnhancedSession {
    <#
      Enhanced Session Mode carries clipboard and drive redirection over the
      VMBus using RDP, not over the VM's network: no address, no account and
      no firewall rule, so nothing that can drift. It needs the host switched
      on, the VM's transport set, and Remote Desktop enabled in the guest.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.EnableEnhancedSession) { return }

    try {
        if (-not (Get-VMHost).EnableEnhancedSessionMode) {
            Set-VMHost -EnableEnhancedSessionMode $true
            Write-LogEntry 'Enhanced session mode enabled on the Hyper-V host' 'OK'
        }
        Set-VM -VMName $VM.Name -EnhancedSessionTransportType HvSocket -ErrorAction Stop
        Write-LogEntry 'VM enhanced session transport set to HvSocket (VMBus)' 'OK'
    }
    catch {
        Write-LogEntry "Could not configure enhanced session mode on the host: $($_.Exception.Message)" 'WARN'
        return
    }

    try {
        $notes = Invoke-GuestScript -VM $VM -Activity 'enable Remote Desktop in guest' -TimeoutMinutes 10 -ScriptBlock {
            $ErrorActionPreference = 'Continue'
            $notes = @()

            $ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
            if ((Get-ItemProperty -Path $ts -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections -ne 0) {
                Set-ItemProperty -Path $ts -Name 'fDenyTSConnections' -Value 0 -Type DWord
                $notes += New-GuestNote -Level OK -Text 'Remote Desktop Services enabled'
            }
            else { $notes += New-GuestNote -Level OK -Text 'Remote Desktop Services already enabled' }

            try {
                Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
                $notes += New-GuestNote -Level OK -Text 'Remote Desktop firewall rules enabled'
            }
            catch { $notes += New-GuestNote -Level WARN -Text "firewall rules: $($_.Exception.Message)" }

            # Drive redirection is what makes host folders appear in the guest.
            # A policy of 1 here silently disables copy and paste of files.
            $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
            if (Test-Path $policy) {
                foreach ($name in 'fDisableCdm', 'fDisableClip') {
                    if ((Get-ItemProperty -Path $policy -Name $name -ErrorAction SilentlyContinue).$name -eq 1) {
                        Remove-ItemProperty -Path $policy -Name $name -ErrorAction SilentlyContinue
                        $notes += New-GuestNote -Level OK -Text "cleared policy $name, which was blocking redirection"
                    }
                }
            }
            return $notes
        }
        Write-GuestNote -Notes $notes
        Write-LogEntry '  In VMConnect: Show Options > Local Resources > More > Drives to share host drives.' 'INFO'
    }
    catch {
        Write-LogError 'Could not enable Remote Desktop in the guest (non-fatal)' $_
    }
}
