# GuestSoftware.ps1 - Build phase 7: Windows, the disks inside the guest, then the tooling list.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Install-GuestSoftware {
    <#
      Starts the VM (from the ISO when the answer file is to install Windows),
      waits for Windows, prepares the disks and Windows settings in the
      guest, then installs everything in the VM's tooling list that the guest
      does not have yet: Visual Studio Installer products, SQL Server and
      winget packages.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [switch]$UsedUnattend
    )

    $settings = $VM.Settings
    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if (-not $machine) {
        Write-LogEntry "VM '$($VM.Name)' not found - skipping Phase 7" 'WARN'
        return
    }
    $credential = Assert-GuestCredential -VM $VM

    if ($machine.State -ne 'Running') {
        Write-LogEntry "VM is '$($machine.State)' - starting it" 'INFO'
        if ($UsedUnattend) { Start-VMFromInstallMedia -VM $VM }
        else { Start-VM -Name $VM.Name | Out-Null }
    }

    if (-not $UsedUnattend) {
        # Equally true of a VM set up by hand long ago, so not worded as an error.
        Write-LogEntry 'No answer-file disc is attached to this VM.' 'INFO'
        Write-LogEntry '  If the guest is already installed and signed in, that is expected - carry on.' 'INFO'
        Write-LogEntry '  If Windows Setup has not run yet, complete it by hand and create a local' 'INFO'
        Write-LogEntry "  administrator named '$($VM.Runtime.GuestAdminUser)' with the stored password." 'INFO'
    }

    Wait-GuestReady -VM $VM -Credential $credential -TimeoutMinutes $settings.GuestWaitMinutes -RequireProvisioned:$UsedUnattend

    # The answer-file disc holds the guest password in clear text, so it goes
    # before anything else runs.
    if ($UsedUnattend) { Remove-UnattendSeedDisk -VM $VM }

    # The data disks go on before SQL Server is installed, so its data
    # folders are on the data disk from the start.
    Add-SqlDataDisk -VM $VM
    Add-DevDriveDisk -VM $VM
    Add-UserDataDisk -VM $VM
    Connect-Guest -VM $VM -Credential $credential | Out-Null
    Expand-GuestSystemDrive -VM $VM
    # A rebuilt guest's C: cannot unlock the disks the old one encrypted;
    # their stored recovery passwords can. One that stays locked stops the
    # build here, before anything is restored onto it (#175).
    Unlock-GuestDataDisk -VM $VM
    Initialize-GuestSqlDisk -VM $VM
    Initialize-GuestDevDrive -VM $VM
    Initialize-GuestUserDisk -VM $VM
    Protect-GuestPersistentDisk -VM $VM -NewSystemDrive:$UsedUnattend
    Enable-GuestEnhancedSession -VM $VM
    Set-GuestCustomization -VM $VM

    # The VM's own recorded list, or the shared template's for a VM that has
    # none. VM.Template.json keeps the list the VM was first built from.
    $tooling = Get-BuildTooling -VM $VM

    # Anything already present is skipped: SQL setup with /ACTION=Install
    # against an existing instance fails outright, and running a bootstrapper
    # again would needlessly modify a working installation.
    $networkReady = Wait-GuestNetwork -VM $VM -TimeoutMinutes $settings.GuestNetworkWaitMinutes
    if ($networkReady) {
        Install-ToolingProduct -VM $VM -Tooling $tooling
    }
    else {
        Write-LogEntry 'The guest has no working DNS: products and packages that download cannot be installed' 'WARN'
        Write-LogEntry '  Re-run with -FromPhase 7 once the guest has internet.' 'INFO'
    }

    Install-SqlServerIfMissing -VM $VM

    if ($networkReady) {
        # The winget packages, and the winget matches of other programs (#24).
        Install-WingetPackage -VM $VM -Packages @($tooling.WingetInstalls())
        Install-OfficialInstaller -VM $VM -Tooling $tooling
    }

    Initialize-VMTooling -VM $VM
    if (-not (Write-ToolingReinstallReport -VM $VM -Tooling $tooling)) { return [BuildOutcome]::CompleteWithProblems }
}

function Wait-GuestNetwork {
    <#
      Waits for the guest to have working DNS and outbound HTTPS. PowerShell
      Direct runs over the VMBus and works with no network at all, so a
      reachable guest says nothing about whether it can download anything.
      Returns whether the network came up.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [int]$TimeoutMinutes = 10
    )

    $progress = @{ Announced = $false; LastDetail = '' }
    $up = Wait-Until -Timeout ([timespan]::FromMinutes($TimeoutMinutes)) -Interval ([timespan]::FromSeconds(15)) -State $progress -NoThrow -Condition {
        param($p)
        try {
            $network = Invoke-GuestScript -VM $VM -Activity 'guest network check' -TimeoutMinutes 3 -ScriptBlock {
                $result = [pscustomobject]@{ Dns = $false; Https = $false; Detail = '' }
                foreach ($name in 'winget.azureedge.net', 'www.microsoft.com') {
                    try { $null = [System.Net.Dns]::GetHostEntry($name); $result.Dns = $true; break }
                    catch { $result.Detail = "DNS: $($_.Exception.Message)" }
                }
                if ($result.Dns) {
                    try {
                        $client = New-Object System.Net.Sockets.TcpClient
                        $async = $client.BeginConnect('www.microsoft.com', 443, $null, $null)
                        $result.Https = $async.AsyncWaitHandle.WaitOne(8000, $false) -and $client.Connected
                        $client.Close()
                        $result.Detail = if ($result.Https) { '' } else { 'DNS resolves but port 443 did not connect' }
                    }
                    catch { $result.Detail = "HTTPS: $($_.Exception.Message)" }
                }
                return $result
            }
            if ($network.Dns -and $network.Https) { return $true }
            $p.LastDetail = "$($network.Detail)"
        }
        catch {
            $p.LastDetail = $_.Exception.Message
        }

        if (-not $p.Announced) {
            Write-LogEntry "Waiting up to $TimeoutMinutes minutes for the guest network to come up..." 'INFO'
            if ($p.LastDetail) { Write-LogEntry "  $($p.LastDetail)" 'INFO' }
            $p.Announced = $true
        }
        return $false
    }

    if ($up) {
        Write-LogEntry 'Guest network is up (DNS and HTTPS both working)' 'OK'
        return $true
    }
    Write-LogEntry "Guest network did not come up within $TimeoutMinutes minutes" 'WARN'
    if ($progress.LastDetail) { Write-LogEntry "  last error: $($progress.LastDetail)" 'WARN' }
    Write-LogEntry '  Check inside the guest:  Resolve-DnsName www.microsoft.com' 'INFO'
    return $false
}
