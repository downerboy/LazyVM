# Guest.SecurityScan.ps1 - Runs in the guest as SYSTEM: a Defender quick scan, then the facts the security checks need (#290).
# Self-contained for Windows PowerShell 5.1: run as a guest task (Invoke-GuestTask), without Guest.Helpers.ps1.
#
# It only reads, apart from the quick scan; it changes nothing. Each check
# reads in a try/catch of its own, so one that cannot be read is reported
# as a note, its area is $null, and the others still run. The host decides
# what is a finding (SecurityFinding.ps1). Returns one line of JSON:
# { Notes = @(@{ Level; Text }); Checks = @{ <area> = @{...} or $null } }.
# Nothing secret is passed to it or returned.
param([int]$QuickScanMinutes = 15)

$ErrorActionPreference = 'Stop'
$notes = New-Object System.Collections.ArrayList

function Add-ScanNote {
    param([string]$Level, [string]$Text)
    [void]$notes.Add(@{ Level = $Level; Text = $Text })
}

function Read-Check {
    <# What $Read returns for the check $Area, or $null and a note when it cannot be read. #>
    param([string]$Area, [scriptblock]$Read)
    try { return (& $Read) }
    catch {
        Add-ScanNote -Level 'WARN' -Text "Security scan: could not read $Area ($($_.Exception.Message)); the next night tries again"
        return $null
    }
}

function Get-RegistryValue {
    <# A registry value, or $null when it or its key is not there. #>
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($item) { return $item.$Name }
    return $null
}

# The quick scan first, so the detections below include what it finds. It
# is given $QuickScanMinutes; one that takes longer is stopped and tried
# again the next night.
try {
    $scan = Start-MpScan -ScanType QuickScan -AsJob
    try {
        if (Wait-Job -Job $scan -Timeout ($QuickScanMinutes * 60)) {
            $null = Receive-Job -Job $scan -ErrorAction Stop
            Add-ScanNote -Level 'OK' -Text 'Security scan: Defender quick scan finished'
        }
        else {
            Stop-Job -Job $scan
            Add-ScanNote -Level 'WARN' -Text "Security scan: Defender quick scan did not finish within $QuickScanMinutes minutes; the next night tries again"
        }
    }
    finally { Remove-Job -Job $scan -Force -ErrorAction SilentlyContinue }
}
catch { Add-ScanNote -Level 'WARN' -Text "Security scan: Defender quick scan could not run ($($_.Exception.Message)); the next night tries again" }

$checks = [ordered]@{}

$checks.Defender = Read-Check 'Defender' {
    $status = Get-MpComputerStatus
    @{
        AMServiceEnabled              = [bool]$status.AMServiceEnabled
        AntivirusEnabled              = [bool]$status.AntivirusEnabled
        RealTimeProtectionEnabled     = [bool]$status.RealTimeProtectionEnabled
        IsTamperProtected             = [bool]$status.IsTamperProtected
        AntivirusSignatureAge         = [int]$status.AntivirusSignatureAge
        AntivirusSignatureLastUpdated = ([datetime]$status.AntivirusSignatureLastUpdated).ToString('yyyy-MM-dd')
    }
}

$checks.DefenderDetection = Read-Check 'DefenderDetection' {
    $names = @{}
    foreach ($threat in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $names["$($threat.ThreatID)"] = "$($threat.ThreatName)" }
    $detections = foreach ($detection in @(Get-MpThreatDetection)) {
        $id = "$($detection.ThreatID)"
        @{
            DetectionId    = "$($detection.DetectionID)"
            ThreatName     = $(if ($names.ContainsKey($id)) { $names[$id] } else { "threat $id" })
            DetectedAt     = ([datetime]$detection.InitialDetectionTime).ToUniversalTime().ToString('o')
            Resources      = @($detection.Resources | ForEach-Object { "$_" })
            ThreatStatusId = [int]$detection.ThreatStatusID
            ActionSuccess  = [bool]$detection.ActionSuccess
        }
    }
    @{ Detections = @($detections) }
}

$checks.Firewall = Read-Check 'Firewall' {
    $profiles = foreach ($firewallProfile in @(Get-NetFirewallProfile -PolicyStore ActiveStore)) {
        @{ Name = "$($firewallProfile.Name)"; Enabled = ("$($firewallProfile.Enabled)" -eq 'True'); DefaultInboundAction = "$($firewallProfile.DefaultInboundAction)" }
    }
    @{ Profiles = @($profiles) }
}

$checks.UAC = Read-Check 'UAC' {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    @{
        EnableLUA                  = Get-RegistryValue -Path $key -Name 'EnableLUA'
        ConsentPromptBehaviorAdmin = Get-RegistryValue -Path $key -Name 'ConsentPromptBehaviorAdmin'
        PromptOnSecureDesktop      = Get-RegistryValue -Path $key -Name 'PromptOnSecureDesktop'
    }
}

$checks.BitLocker = Read-Check 'BitLocker' {
    $volumes = foreach ($volume in @(Get-BitLockerVolume | Where-Object { "$($_.VolumeType)" -in 'OperatingSystem', 'Data' -and "$($_.MountPoint)" -match '^[A-Za-z]:$' })) {
        @{ MountPoint = "$($volume.MountPoint)"; ProtectionStatus = "$($volume.ProtectionStatus)" }
    }
    @{ Volumes = @($volumes) }
}

$checks.SMBv1 = Read-Check 'SMBv1' {
    @{ Enabled = [bool](Get-SmbServerConfiguration).EnableSMB1Protocol }
}

$checks.RemoteDesktop = Read-Check 'RemoteDesktop' {
    # A policy, when set, wins over the setting.
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $deny = Get-RegistryValue -Path $policy -Name 'fDenyTSConnections'
    if ($null -eq $deny) { $deny = Get-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' }
    $nla = Get-RegistryValue -Path $policy -Name 'UserAuthentication'
    if ($null -eq $nla) { $nla = Get-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' }
    @{ Enabled = ($null -ne $deny -and [int]$deny -eq 0); Nla = ($null -ne $nla -and [int]$nla -eq 1) }
}

$checks.Account = Read-Check 'Account' {
    # The built-in Guest account, by its well-known RID, whatever its name.
    $guest = @(Get-LocalUser | Where-Object { "$($_.SID)" -like 'S-1-5-*-501' })
    @{ GuestEnabled = (@($guest | Where-Object { $_.Enabled }).Count -gt 0) }
}

$checks.LSA = Read-Check 'LSA' {
    # Windows can turn LSA protection on without a registry value, so what
    # counts is whether WinInit started LSASS protected (event 12) at this boot.
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $started = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Wininit'; Id = 12; StartTime = $boot } -MaxEvents 1 -ErrorAction SilentlyContinue)
    @{ RunAsPPL = Get-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'; ProtectedSinceBoot = ($started.Count -gt 0) }
}

$checks.SecureBoot = Read-Check 'SecureBoot' {
    @{ On = [bool](Confirm-SecureBootUEFI) }
}

$checks.VBS = Read-Check 'VBS' {
    $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard'
    # 2: running.
    @{ Running = ([int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 2) }
}

$checks.AutoRun = Read-Check 'AutoRun' {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    @{ NoAutorun = Get-RegistryValue -Path $key -Name 'NoAutorun'; NoDriveTypeAutoRun = Get-RegistryValue -Path $key -Name 'NoDriveTypeAutoRun' }
}

$checks.WindowsUpdate = Read-Check 'WindowsUpdate' {
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $until = foreach ($name in 'PauseUpdatesExpiryTime', 'PauseQualityUpdatesEndTime') {
        $value = Get-RegistryValue -Path $key -Name $name
        if ($value) { "$value" }
    }
    @{ PausedUntil = @($until) }
}

$checks.AutoLogon = Read-Check 'AutoLogon' {
    @{ On = ("$(Get-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon')" -eq '1') }
}

# The task's result is one line of text, so the facts go back as JSON.
return (ConvertTo-Json -InputObject @{ Notes = @($notes); Checks = $checks } -Depth 6 -Compress)
