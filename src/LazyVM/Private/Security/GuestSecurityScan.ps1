# GuestSecurityScan.ps1 - What runs in the guest for the nightly security scan (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Two script blocks that run in the guest, in Windows PowerShell 5.1,
# without the guest helpers:
# - $script:GuestSecurityScanWork, as SYSTEM through Invoke-GuestTask: a
#   Defender quick scan, then the facts the checks need ($script:SecurityCheck).
# - $script:SecurityFindingOpener, at each sign-in, connect and unlock, as the
#   user, from the -Command of the guest task LazyVM-SecurityFindings.
# Neither is given or returns anything secret.

# The collector. It only reads, apart from the quick scan; it changes
# nothing. Each area reads in a try/catch of its own, so one that cannot be
# read is a note, its facts are $null, and the others still run. The host
# decides what is a finding. Returns one line of JSON:
# { CollectedAt; Notes = @(@{ Level; Text }); Checks = @{ <area> = @{...} or $null } }.
# CollectedAt, the guest's time just before it read Defender's detections,
# is when the next scan counts new detections and events from.
#
# Its arguments: the quick scan's time limit; Since, when the last scan
# collected (ISO 8601, empty for the first scan, which reads back
# $FirstScanHours); and the patterns script blocks are tested against
# (SecurityEvent.ps1). The events between Since and CollectedAt are read for
# SecurityEvent.ps1's checks: what leaves the guest is who, what and when,
# never a script's text, a command line or a file's content.
$script:GuestSecurityScanWork = {
    param(
        [int]$QuickScanMinutes = 15,
        [string]$Since = '',
        [string[]]$ScriptPattern = @(),
        [int]$FirstScanHours = 24,
        # Where Windows keeps its crash files and its programs' data, as Windows reports them (not from the environment, #317); the tests give others.
        [string]$WindowsFolder = [Environment]::GetFolderPath('Windows'),
        [string]$ProgramDataFolder = [Environment]::GetFolderPath('CommonApplicationData')
    )

    $ErrorActionPreference = 'Stop'
    $notes = New-Object System.Collections.ArrayList

    function Add-ScanNote {
        param([string]$Level, [string]$Text)
        [void]$notes.Add(@{ Level = $Level; Text = $Text })
    }

    function Read-Check {
        <# What $Read returns for the area $Area, or $null and a note when it cannot be read. #>
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

    $scriptPatterns = @($ScriptPattern)
    $crashRoots = [ordered]@{
        Minidump          = [IO.Path]::Combine($WindowsFolder, 'Minidump')
        LiveKernelReports = [IO.Path]::Combine($WindowsFolder, 'LiveKernelReports')
        WER               = [IO.Path]::Combine($ProgramDataFolder, 'Microsoft', 'Windows', 'WER')
    }
    $collectedDate = [datetime]::UtcNow
    $collectedAt = $collectedDate.ToString('o')
    $checks = [ordered]@{}
    # The events and files counted are those since the last scan; a time that cannot be read counts as the first scan.
    $from = $collectedDate.AddHours(-$FirstScanHours)
    if ($Since) {
        $parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($Since, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $from = $parsed.UtcDateTime }
    }

    function Read-Event {
        <# The events of the log $LogName with these ids, from the last scan to now, newest first; none when there are none or the log is not there. #>
        param([string]$LogName, [int[]]$Id, [int]$Maximum = 5000)
        # In local time: Windows PowerShell 5.1 reads StartTime and EndTime as local whatever their kind, so a UTC time is hours off (#344).
        $filter = @{ LogName = $LogName; Id = $Id; StartTime = $from.ToLocalTime(); EndTime = $collectedDate.ToLocalTime() }
        try { return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Maximum -ErrorAction Stop) }
        catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*' -or "$($_.FullyQualifiedErrorId)" -like 'NoMatchingLogsFound*') { return @() }
            throw
        }
    }

    function Get-EventData {
        <# The fields of an event, from its EventData or its UserData, as text. Every field the checks read is there, empty when the event has none. #>
        param($record)
        $data = @{}
        foreach ($name in 'SubjectUserName', 'Channel', 'TargetUserName', 'SubStatus', 'IpAddress', 'WorkstationName', 'LogonType', 'MemberName', 'MemberSid', 'TargetSid',
            'ServiceName', 'ServiceFileName', 'ImagePath', 'SourceImage', 'TargetImage', 'GrantedAccess', 'Image', 'ScriptBlockText', 'ScriptBlockId') { $data[$name] = '' }
        $xml = [xml]$record.ToXml()
        foreach ($field in @($xml.SelectNodes('//*[local-name()="EventData"]/*[local-name()="Data"]'))) {
            if ($field.GetAttribute('Name')) { $data[$field.GetAttribute('Name')] = "$($field.InnerText)" }
        }
        foreach ($field in @($xml.SelectNodes('//*[local-name()="UserData"]/*/*'))) { $data[$field.LocalName] = "$($field.InnerText)" }
        return $data
    }

    function Get-EventTime {
        param($record)
        return $record.TimeCreated.ToUniversalTime().ToString('o')
    }

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
        $active = @()
        foreach ($threat in @(Get-MpThreat)) {
            $names["$($threat.ThreatID)"] = "$($threat.ThreatName)"
            if ($threat.IsActive) { $active += "$($threat.ThreatID)" }
        }
        $detections = foreach ($detection in @(Get-MpThreatDetection)) {
            $id = "$($detection.ThreatID)"
            @{
                DetectionId    = "$($detection.DetectionID)"
                ThreatId       = $id
                ThreatName     = $(if ($names.ContainsKey($id)) { $names[$id] } else { "threat $id" })
                DetectedAt     = ([datetime]$detection.InitialDetectionTime).ToUniversalTime().ToString('o')
                Resources      = @($detection.Resources | ForEach-Object { "$_" })
                ThreatStatusId = [int]$detection.ThreatStatusID
                ActionSuccess  = [bool]$detection.ActionSuccess
            }
        }
        @{ Detections = @($detections); ActiveThreatIds = @($active) }
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
        # counts is whether WinInit started LSASS protected (event 12) at this
        # boot. Only "no such event" means it did not; any other error is the
        # check failing.
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        $started = $false
        try {
            $started = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Wininit'; Id = 12; StartTime = $boot } -MaxEvents 1).Count -gt 0
        }
        catch {
            if ("$($_.FullyQualifiedErrorId)" -notlike 'NoMatchingEventsFound*') { throw }
        }
        @{ RunAsPPL = Get-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'; ProtectedSinceBoot = $started }
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

    $checks.LogCleared = Read-Check 'LogCleared' {
        $cleared = foreach ($record in @(Read-Event -LogName 'Security' -Id 1102 -Maximum 200)) {
            @{ Log = 'Security'; Time = (Get-EventTime $record); By = (Get-EventData $record).SubjectUserName }
        }
        # Event 104 is in the System log whichever log was cleared; its Channel says which.
        $cleared = @($cleared) + @(foreach ($record in @(Read-Event -LogName 'System' -Id 104 -Maximum 200)) {
                $data = Get-EventData $record
                @{ Log = $(if ($data.Channel) { $data.Channel } else { 'System' }); Time = (Get-EventTime $record); By = $data.SubjectUserName }
            })
        @{ Events = @($cleared) }
    }

    $checks.SignIn = Read-Check 'SignIn' {
        # Only wrong-password (0xC000006A) and unknown-user (0xC0000064) failures are guessing; an expired, locked or disabled account is not.
        function Get-SignInSource {
            param($Data)
            if ($Data.IpAddress -and $Data.IpAddress -ne '-') { return $Data.IpAddress }
            return $Data.WorkstationName
        }
        $failed = foreach ($record in @(Read-Event -LogName 'Security' -Id 4625)) {
            $data = Get-EventData $record
            if ("$($data.SubStatus)" -notin '0xc000006a', '0xc0000064') { continue }
            @{ Id = 4625; Time = (Get-EventTime $record); Account = $data.TargetUserName; Source = (Get-SignInSource $data); Type = [int]$data.LogonType }
        }
        # The successes that matter are those of an account and a source that failed.
        $succeeded = @()
        if (@($failed).Count -gt 0) {
            $accounts = @($failed | ForEach-Object { $_.Account.ToLowerInvariant() } | Select-Object -Unique)
            $sources = @($failed | ForEach-Object { $_.Source } | Select-Object -Unique)
            $succeeded = foreach ($record in @(Read-Event -LogName 'Security' -Id 4624 -Maximum 20000)) {
                $data = Get-EventData $record
                # 2 interactive, 3 network, 10 remote interactive.
                if ([int]$data.LogonType -notin 2, 3, 10) { continue }
                if ("$($data.TargetUserName)".ToLowerInvariant() -notin $accounts -or (Get-SignInSource $data) -notin $sources) { continue }
                @{ Id = 4624; Time = (Get-EventTime $record); Account = $data.TargetUserName; Source = (Get-SignInSource $data); Type = [int]$data.LogonType }
            }
        }
        @{ Events = @($failed) + @($succeeded) }
    }

    $checks.AccountChange = Read-Check 'AccountChange' {
        $changes = foreach ($record in @(Read-Event -LogName 'Security' -Id 4720, 4732, 4697 -Maximum 500)) {
            $data = Get-EventData $record
            switch ($record.Id) {
                4720 { @{ Id = 4720; Time = (Get-EventTime $record); Name = $data.TargetUserName; By = $data.SubjectUserName } }
                4732 {
                    # Only the Administrators group, by its well-known SID.
                    if ($data.TargetSid -ne 'S-1-5-32-544') { continue }
                    $member = if ($data.MemberName -and $data.MemberName -ne '-') { $data.MemberName } else { $data.MemberSid }
                    @{ Id = 4732; Time = (Get-EventTime $record); Name = $member; By = $data.SubjectUserName }
                }
                4697 { @{ Id = 4697; Time = (Get-EventTime $record); Name = $data.ServiceName; By = $data.SubjectUserName; Path = $data.ServiceFileName } }
            }
        }
        $services = foreach ($record in @(Read-Event -LogName 'System' -Id 7045 -Maximum 500)) {
            $data = Get-EventData $record
            @{ Id = 7045; Time = (Get-EventTime $record); Name = $data.ServiceName; Path = $data.ImagePath }
        }
        @{ Events = @($changes) + @($services) }
    }

    $checks.Sysmon = Read-Check 'Sysmon' {
        $log = 'Microsoft-Windows-Sysmon/Operational'
        $seen = foreach ($record in @(Read-Event -LogName $log -Id 10, 8 -Maximum 500)) {
            $data = Get-EventData $record
            if ($record.Id -eq 10) {
                if ("$($data.TargetImage)" -notlike '*\lsass.exe') { continue }
                @{ Id = 10; Time = (Get-EventTime $record); Image = $data.SourceImage; Target = $data.TargetImage; Access = $data.GrantedAccess }
            }
            else { @{ Id = 8; Time = (Get-EventTime $record); Image = $data.SourceImage; Target = $data.TargetImage } }
        }
        # Programs started from a Temp or Downloads folder; Sysmon logs every process, so more are read.
        $started = foreach ($record in @(Read-Event -LogName $log -Id 1 -Maximum 20000)) {
            $data = Get-EventData $record
            if ("$($data.Image)" -notmatch '(?i)\\(Temp|Downloads)\\') { continue }
            @{ Id = 1; Time = (Get-EventTime $record); Image = $data.Image }
        }
        @{ Events = @($seen) + @($started) }
    }

    $checks.PowerShellScript = Read-Check 'PowerShellScript' {
        $logs = [ordered]@{ PowerShell = 'Microsoft-Windows-PowerShell/Operational'; PowerShellCore = 'PowerShellCore/Operational' }
        $skipped = 0
        $suspicious = foreach ($name in $logs.Keys) {
            foreach ($record in @(Read-Event -LogName $logs[$name] -Id 4104 -Maximum 10000)) {
                $text = "$((Get-EventData $record).ScriptBlockText)"
                $matched = @()
                for ($index = 0; $index -lt $scriptPatterns.Count; $index++) {
                    # A pattern that takes too long on a script counts as no match.
                    try { if ([regex]::IsMatch($text, $scriptPatterns[$index], [Text.RegularExpressions.RegexOptions]::None, [timespan]::FromSeconds(2))) { $matched += $index } }
                    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { $skipped++ }
                }
                if ($matched.Count -gt 0) { @{ Log = $name; Time = (Get-EventTime $record); BlockId = (Get-EventData $record).ScriptBlockId; Matched = @($matched) } }
            }
        }
        if ($skipped -gt 0) {
            $blocks = if ($skipped -eq 1) { '1 script block' } else { "$skipped script blocks" }
            Add-ScanNote -Level 'WARN' -Text "Security scan: $blocks took too long to test against one of the patterns, so were not checked for it"
        }
        @{ Events = @($suspicious | Select-Object -First 25) }
    }

    $checks.CrashDump = Read-Check 'CrashDump' {
        $roots = $crashRoots
        $items = New-Object System.Collections.ArrayList
        foreach ($name in $roots.Keys) {
            if (-not (Test-Path -LiteralPath $roots[$name])) { continue }
            # By hand, not Get-ChildItem -Recurse, which follows links out of the folder.
            $pending = New-Object System.Collections.Generic.Stack[string]
            $pending.Push($roots[$name])
            while ($pending.Count -gt 0 -and $items.Count -lt 100) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction SilentlyContinue)) {
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
                    elseif ($entry.LastWriteTimeUtc -gt $from -and $entry.LastWriteTimeUtc -le $collectedDate) {
                        [void]$items.Add(@{ Folder = $name; Name = $entry.Name; Time = $entry.LastWriteTimeUtc.ToString('o'); Size = [long]$entry.Length })
                    }
                }
            }
        }
        @{ Items = @($items) }
    }

    # The task's result is one line of text, so the facts go back as JSON.
    return (ConvertTo-Json -InputObject @{ CollectedAt = $collectedAt; Notes = @($notes); Checks = $checks } -Depth 6 -Compress)
}

# The sign-in opener: opens LazyVM Findings.txt on the public desktop in
# Notepad when a scan asked for it (the stamp under HKLM:\SOFTWARE\LazyVM,
# $script:GuestSecurityAlertValueName) and it has not been opened for that
# stamp yet (the user's own HKCU:\SOFTWARE\LazyVM). The stamp is recorded
# before Notepad starts, so it never opens twice for one scan. It runs as
# the task's -Command, one statement to a line joined with '; '
# (Get-SecurityFindingOpenerArgument), so there is no script file anyone
# could change; hence no comments or double quotes inside it. Each value is
# read so that one not set yet, or its key, is $null, under StrictMode too.
$script:SecurityFindingOpener = {
    $alert = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\LazyVM' -Name 'SecurityFindingsAlert' -ErrorAction SilentlyContinue
    $file = [System.IO.Path]::Combine([Environment]::GetFolderPath('CommonDesktopDirectory'), 'LazyVM Findings.txt')
    if (-not $alert -or -not (Test-Path -LiteralPath $file)) { return }
    $userKey = 'HKCU:\SOFTWARE\LazyVM'
    if ((Get-ItemPropertyValue -Path $userKey -Name 'SecurityFindingsOpened' -ErrorAction SilentlyContinue) -eq $alert) { return }
    if (-not (Test-Path -LiteralPath $userKey)) { New-Item -Path $userKey -Force | Out-Null }
    Set-ItemProperty -Path $userKey -Name 'SecurityFindingsOpened' -Value $alert
    Start-Process -FilePath ([System.IO.Path]::Combine([Environment]::GetFolderPath('System'), 'notepad.exe')) -ArgumentList ([string][char]34 + $file + [char]34)
}

function Get-SecurityFindingOpenerArgument {
    <#
      The guest task's arguments for powershell.exe: the opener's text as
      -Command, one line, in plain text (no -EncodedCommand, which reads as
      obfuscation in the event logs).
    #>
    [OutputType([string])]
    param()

    $command = (@("$script:SecurityFindingOpener" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join '; ')
    return "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$command`""
}
