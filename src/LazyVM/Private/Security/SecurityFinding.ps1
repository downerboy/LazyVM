# SecurityFinding.ps1 - What the nightly security scan found, compared with the last scan and put in words (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The guest script (Data\Guest.SecurityScan.ps1) only collects facts. These
# functions, which only compute, turn the facts into findings, mark each one
# New, Still open or Resolved against the last scan, and write them out in
# plain text, one field per line, so a screen reader reads one field at a
# time. Every finding says what was found, why it matters and how to fix it;
# LazyVM itself changes nothing.
#
# A finding (the SecurityFinding class) has an Id made from what was found,
# area first, such as 'Firewall:Public:Off'. Ids are opaque: the same thing
# found again has the same Id; when it changes, so does the Id. The area is
# the facts' name for the check ($script:SecurityCheck), so a check the guest
# could not read tonight keeps its findings open.

# Defender's own threshold for virus definitions that are out of date.
$script:DefenderSignatureMaxAgeDays = 7

# What Defender did about a detection, by its ThreatStatusID. Those it dealt
# with are Medium findings; anything else is High.
$script:DefenderThreatStatus = @{
    1   = 'detected it, and has not acted on it yet'
    2   = 'cleaned it'
    3   = 'quarantined it'
    4   = 'removed it'
    5   = 'allowed it, because someone chose to'
    6   = 'blocked it'
    102 = 'could not quarantine it'
    103 = 'could not remove it'
    104 = 'could not allow it'
    105 = 'abandoned it'
    107 = 'could not block it'
}
$script:DefenderThreatHandled = @(2, 3, 4, 6)

function New-SecurityFinding {
    <# One finding, before it is compared with the last scan; $Where lists the full paths of the files it is about, if any. #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium', 'Low', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$WhatWeFound,
        [Parameter(Mandatory)][string]$WhyItMatters,
        [Parameter(Mandatory)][string]$HowToFix,
        [string[]]$Where = @()
    )

    $finding = [SecurityFinding]::new($Id, $Severity, $Title, $WhatWeFound, $WhyItMatters, $HowToFix)
    $finding.Where = $Where
    return $finding
}

# Each area the guest script reads, in its order, with the check that turns
# its facts into findings. Each check gets the area's facts and the scan
# (Since: when the last scan collected, $null for the first; ScannedAt).
# The guest script's areas are these (SecurityScan.Tests.ps1 checks).
$script:SecurityCheck = [ordered]@{
    Defender          = { param($fact) Get-DefenderStatusFinding -Fact $fact }
    DefenderDetection = { param($fact, $scan) Get-DefenderDetectionFinding -Fact $fact -Since $scan.Since }
    Firewall          = { param($fact) Get-FirewallFinding -Fact $fact }
    UAC               = { param($fact) Get-UacFinding -Fact $fact }
    BitLocker         = { param($fact) Get-BitLockerFinding -Fact $fact }
    SMBv1             = { param($fact) Get-Smb1Finding -Fact $fact }
    RemoteDesktop     = { param($fact) Get-RemoteDesktopFinding -Fact $fact }
    Account           = { param($fact) Get-GuestAccountFinding -Fact $fact }
    LSA               = { param($fact) Get-LsaProtectionFinding -Fact $fact }
    SecureBoot        = { param($fact) Get-SecureBootFinding -Fact $fact }
    VBS               = { param($fact) Get-VbsFinding -Fact $fact }
    AutoRun           = { param($fact) Get-AutoRunFinding -Fact $fact }
    WindowsUpdate     = { param($fact, $scan) Get-WindowsUpdatePauseFinding -Fact $fact -ScannedAt $scan.ScannedAt }
    AutoLogon         = { param($fact) Get-AutoLogonFinding -Fact $fact }
    # What happened since the last scan (SecurityEvent.ps1).
    LogCleared        = { param($fact) Get-LogClearedFinding -Fact $fact }
    SignIn            = { param($fact) Get-SignInFinding -Fact $fact }
    AccountChange     = { param($fact) Get-AccountChangeFinding -Fact $fact }
    Sysmon            = { param($fact) Get-SysmonFinding -Fact $fact }
    PowerShellScript  = { param($fact) Get-PowerShellScriptFinding -Fact $fact }
    CrashDump         = { param($fact) Get-CrashDumpFinding -Fact $fact }
}

function ConvertTo-SecurityFinding {
    <#
      Every finding in the facts $Check the guest script collected, area by
      area ($script:SecurityCheck): the Defender checks, then the settings
      measured against the Microsoft security baseline. An area the guest
      could not read ($null) gives none. $Since is when the last scan
      collected, $null for the first.
    #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][object]$Check,
        [AllowNull()][object]$Since,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt
    )

    $scan = @{ Since = $Since; ScannedAt = $ScannedAt }
    foreach ($area in $script:SecurityCheck.Keys) {
        $fact = [RecordReader]::Field($Check, $area)
        if ($null -ne $fact) { & $script:SecurityCheck[$area] $fact $scan }
    }
}

function Get-UncheckedSecurityArea {
    <# The areas $Area (the settings checks, by default) the guest could not read tonight: those the facts $Check have no facts for. #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Check,
        [string[]]$Area = @($script:SecurityCheck.Keys)
    )

    return @($Area | Where-Object { $null -eq [RecordReader]::Field($Check, $_) })
}

function Get-DefenderStatusFinding {
    <# Defender Antivirus, its real-time and tamper protection, and how old its virus definitions are. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $openDefender = 'Open Windows Security in the VM, choose Virus and threat protection, and turn it on under Manage settings.'
    if (-not $Fact.AMServiceEnabled -or -not $Fact.AntivirusEnabled) {
        New-SecurityFinding -Id 'Defender:Antivirus:Off' -Severity High -Title 'Microsoft Defender Antivirus is off' `
            -WhatWeFound 'Defender Antivirus is not running in this VM.' `
            -WhyItMatters 'Nothing checks the files and programs in this VM for malware.' `
            -HowToFix "$openDefender If another antivirus program turned Defender off, make sure that program is running and up to date."
        return
    }
    if (-not $Fact.RealTimeProtectionEnabled) {
        New-SecurityFinding -Id 'Defender:RealTimeProtection:Off' -Severity High -Title 'Defender real-time protection is off' `
            -WhatWeFound 'Defender does not check files as they are opened, downloaded or run.' `
            -WhyItMatters 'Malware can run before the nightly scan finds it. Malware also turns this off to hide itself.' `
            -HowToFix "$openDefender Then turn on Real-time protection."
    }
    if (-not $Fact.IsTamperProtected) {
        New-SecurityFinding -Id 'Defender:TamperProtection:Off' -Severity Medium -Title 'Defender tamper protection is off' `
            -WhatWeFound 'Programs can change Defender''s settings, or turn it off.' `
            -WhyItMatters 'Malware often turns Defender off first. Tamper protection stops that.' `
            -HowToFix "$openDefender Then turn on Tamper protection."
    }
    if ([int]$Fact.AntivirusSignatureAge -gt $script:DefenderSignatureMaxAgeDays) {
        New-SecurityFinding -Id 'Defender:Signatures:OutOfDate' -Severity Medium -Title 'Defender''s virus definitions are out of date' `
            -WhatWeFound "Defender's virus definitions are $($Fact.AntivirusSignatureAge) days old. They were last updated on $($Fact.AntivirusSignatureLastUpdated)." `
            -WhyItMatters 'Defender cannot recognize malware that is newer than its definitions.' `
            -HowToFix 'Make sure the VM can reach the internet. Nightly maintenance installs Windows updates, which bring new definitions. To update them now, open Windows Security, choose Virus and threat protection, then Protection updates, then Check for updates.'
    }
}

function Get-DefenderDetectionFinding {
    <#
      Each threat Defender detected since the last scan ($Since; every one
      it still lists on the first scan), and, for each threat it still
      lists as active, its newest detection, however long ago it was found.
      The Id is the threat's id and the detection's id, so each detection
      is a finding of its own, whatever name Defender gives the threat. A
      detection is not resolved by time passing: it stays a finding while
      Defender lists its threat as active.
    #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][object]$Fact,
        [AllowNull()][object]$Since
    )

    $active = @($Fact.ActiveThreatIds | ForEach-Object { "$_" })
    $detections = @($Fact.Detections | Sort-Object -Property { [datetimeoffset]::Parse([string]$_.DetectedAt, [cultureinfo]::InvariantCulture) } -Descending)
    $newestOfActive = @{}
    foreach ($detection in $detections) {
        $threat = "$($detection.ThreatId)"
        if ($threat -in $active -and -not $newestOfActive.ContainsKey($threat)) { $newestOfActive[$threat] = "$($detection.DetectionId)" }
    }
    foreach ($detection in @($Fact.Detections)) {
        $detectedAt = [datetimeoffset]::Parse([string]$detection.DetectedAt, [cultureinfo]::InvariantCulture)
        $isActive = "$($detection.ThreatId)" -in $active
        $isNew = $null -eq $Since -or $detectedAt -gt [datetimeoffset]$Since
        $isNewestOfActive = $isActive -and $newestOfActive["$($detection.ThreatId)"] -eq "$($detection.DetectionId)"
        if (-not $isNew -and -not $isNewestOfActive) { continue }

        $status = [int]$detection.ThreatStatusId
        $done = if ($script:DefenderThreatStatus.ContainsKey($status)) { $script:DefenderThreatStatus[$status] } else { "reported status $status" }
        $handled = -not $isActive -and $status -in $script:DefenderThreatHandled -and $detection.ActionSuccess
        $where = @($detection.Resources | ForEach-Object { "$_" -replace '^[a-z]+:_', '' })
        $still = if ($isActive) { ' Defender still lists it as active.' } else { '' }
        $fix = if ($handled) {
            'Defender dealt with it. Think about where the file came from, and do not run it again. Open Windows Security, choose Virus and threat protection, then Protection history, for the details.'
        }
        else {
            'Open Windows Security, choose Virus and threat protection, then Protection history, and choose the action Defender recommends. Then run a full scan. If you cannot remove it, rebuild the VM with Invoke-LazyVMRebuild.'
        }
        New-SecurityFinding -Id "DefenderDetection:$($detection.ThreatId):$($detection.DetectionId)" -Severity $(if ($handled) { 'Medium' } else { 'High' }) `
            -Title "Defender found $($detection.ThreatName)" `
            -WhatWeFound "Defender found $($detection.ThreatName) on $($detectedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')). Defender $done.$still" `
            -WhyItMatters 'Malware got into this VM. Whatever brought it in may bring more.' `
            -HowToFix $fix -Where $where
    }
}

function Get-FirewallFinding {
    <# Each Windows Firewall profile that is off, or that lets every connection in. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    foreach ($firewallProfile in @($Fact.Profiles)) {
        $name = $firewallProfile.Name
        if (-not $firewallProfile.Enabled) {
            New-SecurityFinding -Id "Firewall:${name}:Off" -Severity High -Title "The Windows Firewall is off for the $name profile" `
                -WhatWeFound "The firewall's $name profile is turned off." `
                -WhyItMatters 'Any program on the network can connect to the services running in this VM.' `
                -HowToFix "Open Windows Security in the VM, choose Firewall and network protection, then $name network, and turn on Microsoft Defender Firewall."
        }
        elseif ("$($firewallProfile.DefaultInboundAction)" -eq 'Allow') {
            New-SecurityFinding -Id "Firewall:${name}:InboundAllowed" -Severity Medium -Title "The $name firewall profile lets every connection in" `
                -WhatWeFound "The firewall's $name profile allows incoming connections that no rule allows." `
                -WhyItMatters 'Services in this VM can be reached from the network even when no rule lets them.' `
                -HowToFix "In the VM, as administrator, run: Set-NetFirewallProfile -Name $name -DefaultInboundAction Block"
        }
    }
}

function Get-UacFinding {
    <# User Account Control: off, elevating administrators without asking, or asking off the secure desktop. A value not set is Windows' default, which is on. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $policy = 'Change it in Local Security Policy (secpol.msc), under Local Policies, then Security Options,'
    if ($null -ne $Fact.EnableLUA -and [int]$Fact.EnableLUA -eq 0) {
        New-SecurityFinding -Id 'UAC:EnableLUA:Off' -Severity High -Title 'User Account Control is off' `
            -WhatWeFound 'User Account Control is turned off, so every program an administrator starts runs with full rights.' `
            -WhyItMatters 'Any program, malware included, can change the whole VM without asking.' `
            -HowToFix "$policy setting User Account Control: Run all administrators in Admin Approval Mode to Enabled. Then restart the VM."
    }
    if ($null -ne $Fact.ConsentPromptBehaviorAdmin -and [int]$Fact.ConsentPromptBehaviorAdmin -eq 0) {
        New-SecurityFinding -Id 'UAC:AdminPrompt:Off' -Severity Medium -Title 'Administrators get full rights without being asked' `
            -WhatWeFound 'User Account Control elevates programs for administrators without asking.' `
            -WhyItMatters 'A program can take full rights without you noticing.' `
            -HowToFix "$policy setting User Account Control: Behavior of the elevation prompt for administrators to Prompt for consent on the secure desktop."
    }
    if ($null -ne $Fact.PromptOnSecureDesktop -and [int]$Fact.PromptOnSecureDesktop -eq 0) {
        New-SecurityFinding -Id 'UAC:SecureDesktop:Off' -Severity Low -Title 'The User Account Control prompt is not on the secure desktop' `
            -WhatWeFound 'The User Account Control prompt appears on the normal desktop.' `
            -WhyItMatters 'Other programs can see the prompt there, and could answer it.' `
            -HowToFix "$policy setting User Account Control: Switch to the secure desktop when prompting for elevation to Enabled."
    }
}

function Get-BitLockerFinding {
    <# Each disk in the VM whose BitLocker protection is off. A locked disk, whose state is unknown, is left out. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    foreach ($volume in @($Fact.Volumes | Where-Object { "$($_.ProtectionStatus)" -eq 'Off' })) {
        $letter = "$($volume.MountPoint)".TrimEnd(':')
        New-SecurityFinding -Id "BitLocker:${letter}:Off" -Severity Medium -Title "BitLocker does not protect $($volume.MountPoint)" `
            -WhatWeFound "BitLocker protection is off for $($volume.MountPoint)." `
            -WhyItMatters 'Anyone who copies this disk off the host can read everything on it.' `
            -HowToFix 'Nightly maintenance turns BitLocker on for every disk, so this usually fixes itself by the next night. If Windows Update suspended it, it resumes when the VM restarts. If it stays, read why in the VM''s log on the host.'
    }
}

function Get-Smb1Finding {
    <# The SMB 1 file-sharing protocol, when the file server still accepts it. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    if ($Fact.Enabled) {
        New-SecurityFinding -Id 'SMBv1:Server:On' -Severity High -Title 'The old SMB 1 file-sharing protocol is on' `
            -WhatWeFound 'The file server in this VM accepts SMB 1 connections.' `
            -WhyItMatters 'SMB 1 has known flaws that worms such as WannaCry used to spread.' `
            -HowToFix 'In the VM, as administrator, run: Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force'
    }
}

function Get-RemoteDesktopFinding {
    <# Remote Desktop that lets anyone reach the sign-in screen, without Network Level Authentication. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    if ($Fact.Enabled -and -not $Fact.Nla) {
        New-SecurityFinding -Id 'RemoteDesktop:NLA:Off' -Severity High -Title 'Remote Desktop does not ask who you are first' `
            -WhatWeFound 'Remote Desktop is on without Network Level Authentication.' `
            -WhyItMatters 'Anyone who can reach the VM gets its sign-in screen, and can try passwords or attack Remote Desktop itself before signing in.' `
            -HowToFix 'In the VM, open Settings, then System, then Remote Desktop, and turn on Require devices to use Network Level Authentication to connect.'
    }
}

function Get-GuestAccountFinding {
    <# The built-in Guest account, when it is turned on. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    if ($Fact.GuestEnabled) {
        New-SecurityFinding -Id 'Account:Guest:Enabled' -Severity High -Title 'The Guest account is on' `
            -WhatWeFound 'The built-in Guest account, which needs no password, is turned on.' `
            -WhyItMatters 'Anyone can sign in to the VM, or reach its shared folders, without a password.' `
            -HowToFix 'In the VM, as administrator, run: Get-LocalUser | Where-Object SID -like ''*-501'' | Disable-LocalUser'
    }
}

function Get-LsaProtectionFinding {
    <# LSA protection, when Windows did not start LSASS as a protected process and is not set to. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $setToStart = $null -ne $Fact.RunAsPPL -and [int]$Fact.RunAsPPL -in 1, 2
    if (-not $Fact.ProtectedSinceBoot -and -not $setToStart) {
        New-SecurityFinding -Id 'LSA:Protection:Off' -Severity Medium -Title 'LSA protection is off' `
            -WhatWeFound 'Windows did not start the Local Security Authority (LSASS) as a protected process.' `
            -WhyItMatters 'Without it, a program running as administrator can read the passwords and sign-in tokens LSASS holds.' `
            -HowToFix 'In the VM, open Windows Security, choose Device security, then Core isolation details, turn on Local Security Authority protection, and restart the VM.'
    }
}

function Get-SecureBootFinding {
    <# Secure Boot, when it is off. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    if (-not $Fact.On) {
        New-SecurityFinding -Id 'SecureBoot:UEFI:Off' -Severity Medium -Title 'Secure Boot is off' `
            -WhatWeFound 'The VM starts without Secure Boot.' `
            -WhyItMatters 'Malware that loads before Windows, such as a bootkit, can start unnoticed.' `
            -HowToFix 'On the host, as administrator, with the VM off, run: Set-VMFirmware -VMName <the VM''s name> -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows. Then start the VM.'
    }
}

function Get-VbsFinding {
    <# Virtualization-based security, when it is not running. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    if (-not $Fact.Running) {
        New-SecurityFinding -Id 'VBS:Status:NotRunning' -Severity Low -Title 'Virtualization-based security is not running' `
            -WhatWeFound 'Windows is not running virtualization-based security (VBS), so Memory integrity and Credential Guard cannot run either.' `
            -WhyItMatters 'VBS keeps sign-in secrets and the Windows kernel apart from the rest of the system, out of malware''s reach.' `
            -HowToFix 'VBS in a Hyper-V VM needs nested virtualization, which does not work with dynamic memory. On the host, as administrator, with the VM off, run: Set-VMMemory -VMName <the VM''s name> -DynamicMemoryEnabled $false, then Set-VMProcessor -VMName <the VM''s name> -ExposeVirtualizationExtensions $true. Then start the VM, and in Windows Security, under Device security, then Core isolation details, turn on Memory integrity. The VM then always uses its full memory, and a rebuild makes it again without either change.'
    }
}

function Get-AutoRunFinding {
    <# AutoRun, when it is not off for every drive as the Microsoft security baseline sets it. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $off = $null -ne $Fact.NoAutorun -and [int]$Fact.NoAutorun -eq 1 -and $null -ne $Fact.NoDriveTypeAutoRun -and [int]$Fact.NoDriveTypeAutoRun -eq 255
    if (-not $off) {
        New-SecurityFinding -Id 'AutoRun:AllDrives:On' -Severity Low -Title 'AutoRun is not off for every drive' `
            -WhatWeFound 'Windows can still run or offer to run what a disc, a USB drive or an attached disk image holds when it appears.' `
            -WhyItMatters 'Malware spreads on removable drives this way.' `
            -HowToFix 'In the VM, open Local Group Policy (gpedit.msc), go to Computer Configuration, then Administrative Templates, then Windows Components, then AutoPlay Policies. Set Turn off AutoPlay to Enabled for All drives, and Set the default behavior for AutoRun to Enabled with Do not execute any autorun commands.'
    }
}

function Get-WindowsUpdatePauseFinding {
    <# Windows Update, when its updates are paused until a date still to come. Dates that cannot be read are left out. #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][object]$Fact,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt
    )

    $until = @($Fact.PausedUntil | ForEach-Object {
            $parsed = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse([string]$_, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $parsed }
        } | Where-Object { $_ -gt $ScannedAt } | Sort-Object -Descending)
    if ($until.Count -gt 0) {
        # The Id's date in UTC, so it does not depend on the host's time zone.
        New-SecurityFinding -Id "WindowsUpdate:PausedUntil:$($until[0].UtcDateTime.ToString('yyyy-MM-dd'))" -Severity Medium -Title 'Windows updates are paused' `
            -WhatWeFound "Windows Update is paused until $($until[0].ToLocalTime().ToString('yyyy-MM-dd'))." `
            -WhyItMatters 'Security fixes do not install while updates are paused, and nightly maintenance cannot install them either.' `
            -HowToFix 'In the VM, open Settings, then Windows Update, and choose Resume updates.'
    }
}

# Automatic sign-in's finding, which the first build approves (Add-DefaultSecurityApproval).
$script:AutoLogonFindingId = 'AutoLogon:Winlogon:On'
$script:AutoLogonFindingTitle = 'Automatic sign-in is on'

function Get-AutoLogonFinding {
    <# Automatic sign-in, which LazyVM keeps on by design: reported for information. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    if ($Fact.On) {
        New-SecurityFinding -Id $script:AutoLogonFindingId -Severity Info -Title $script:AutoLogonFindingTitle `
            -WhatWeFound 'Windows signs the guest account in by itself whenever the VM starts.' `
            -WhyItMatters 'LazyVM keeps it on by design, so maintenance can work in your session. Anyone who can open the VM on the host is signed in without a password, so keep the host locked.' `
            -HowToFix 'Nothing to do. Only a VM built with Build-LazyVM -NoUnattend is without it.'
    }
}

function Compare-SecurityFinding {
    <#
      Tonight's findings $Current against the last scan's $Previous: each is
      New, first seen now, or Still open, first seen when it first was. An
      open finding of the last scan not found tonight is Resolved, listed
      this once; when its area is in $Unchecked, which the guest could not
      read tonight, it is kept as Still open instead. Most serious first,
      then the newest.
    #>
    [OutputType([SecurityFinding])]
    param(
        [AllowEmptyCollection()][SecurityFinding[]]$Current = @(),
        [AllowEmptyCollection()][SecurityFinding[]]$Previous = @(),
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt,
        [AllowEmptyCollection()][string[]]$Unchecked = @()
    )

    $open = @{}
    foreach ($finding in @($Previous | Where-Object { $_.Status -ne 'Resolved' })) { $open[$finding.Id] = $finding }
    $currentIds = @($Current | ForEach-Object { $_.Id })

    $result = @(
        foreach ($finding in $Current) {
            $earlier = $open[$finding.Id]
            if ($earlier) { $finding.Compared('Still open', $earlier.FirstSeen) } else { $finding.Compared('New', $ScannedAt) }
        }
        foreach ($finding in $open.Values) {
            if ($finding.Id -in $currentIds) { continue }
            $finding.Compared($(if ($finding.Area() -in $Unchecked) { 'Still open' } else { 'Resolved' }), $finding.FirstSeen)
        }
    )
    return @($result | Sort-Object -Property @(
            @{ Expression = { [SecurityFinding]::Severities.IndexOf($_.Severity) } }
            @{ Expression = { [SecurityFinding]::Statuses.IndexOf($_.Status) } }
            @{ Expression = { $_.Id } }
        ))
}

function Test-SecurityFindingAlert {
    <#
      Whether the scan found something new of a severity that alerts
      ($AlertSeverity, the setting GuestSecurityScanAlertSeverity): what opens
      the findings file at the next sign-in.
    #>
    [OutputType([bool])]
    param(
        [AllowEmptyCollection()][object[]]$Finding = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AlertSeverity
    )

    return @($Finding | Where-Object { $_.Status -eq 'New' -and $_.Severity -in $AlertSeverity }).Count -gt 0
}

function Format-SecurityFinding {
    <#
      One finding as lines of text, one field to a line. The files it is
      about are listed by full path, or with -NamesOnly by file name only,
      as on the guest's desktop, which every user of the VM can read.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][SecurityFinding]$Finding,
        [switch]$NamesOnly
    )

    $where = @($Finding.Where | ForEach-Object { if ($NamesOnly) { Split-Path -Path $_ -Leaf } else { $_ } })
    return @(
        "Id: $($Finding.Id)"
        "Severity: $($Finding.Severity)"
        "Title: $($Finding.Title)"
        "What we found: $($Finding.WhatWeFound)"
        if ($where.Count -gt 0) { "Where: $($where -join '; ')" }
        "Why it matters: $($Finding.WhyItMatters)"
        "How to fix: $($Finding.HowToFix)"
        "First seen: $(Format-SecurityFindingTime -Time $Finding.FirstSeen)"
        "Status: $($Finding.Status)"
    )
}

function Format-SecurityFindingTime {
    <# A scan's time as the findings show it: local, to the minute. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][datetimeoffset]$Time)

    return $Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Format-SecurityFindingCount {
    <# How many findings there are, and how many of them are new, still open and resolved, as one sentence. #>
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Finding = @())

    $count = { param($status) @($Finding | Where-Object { $_.Status -eq $status }).Count }
    $noun = if ($Finding.Count -eq 1) { 'finding' } else { 'findings' }
    return "$($Finding.Count) ${noun}: $(& $count 'New') new, $(& $count 'Still open') still open, $(& $count 'Resolved') resolved."
}

function ConvertTo-PowerShellQuotedString {
    <# $Text as a single-quoted PowerShell string, so a command made with it runs with $Text as it is. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return "'" + $Text.Replace("'", "''") + "'"
}

# The shape each severity has in LazyVM Findings.html, as HTML entities (a
# triangle, a diamond, a circle, a square), so a severity is told apart
# without its colour.
$script:SecuritySeverityIcon = @{ High = '&#9650;'; Medium = '&#9670;'; Low = '&#9679;'; Info = '&#9632;' }

function Format-SecurityFindingReport {
    <#
      LazyVM Findings.html on the guest's desktop (#367): what it is, when
      the scan ran, then each finding in a section of its own under a
      heading, alternately dark and light blue, its fields as a list, files
      by name only. An open finding has the host command that approves it,
      with a button that copies it. Every value is HTML-encoded, and the
      page's policy lets it load nothing from anywhere.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][SecurityFinding[]]$Finding = @(),
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt
    )

    $title = "LazyVM security findings for $VMName"
    $name = ConvertTo-PowerShellQuotedString -Text $VMName
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add('<section class="summary" aria-label="Summary">')
    if ($Finding.Count -eq 0) {
        $body.Add('<p>No security findings. Everything LazyVM checks looks right.</p>')
    }
    else {
        $body.Add("<p>$(ConvertTo-HtmlText (Format-SecurityFindingCount -Finding $Finding))</p>")
    }
    $body.Add('<p>LazyVM only reports what it finds. It changed nothing in this VM. This page is replaced after every nightly scan.</p>')
    if ($Finding.Count -gt 0) {
        $body.Add('<p>The commands on this page run on the host, in PowerShell, not in this VM. Copy one here, then paste it on the host.</p>')
        $body.Add('<p>On the host, to see the findings:</p>')
        $body.Add("<p class=`"command`"><code id=`"list`">Get-LazyVMSecurityFinding -Name $(ConvertTo-HtmlText $name)</code><button type=`"button`" data-copy=`"list`" aria-label=`"Copy list command`">Copy</button></p>")
        $body.Add('<p id="copied" role="status" aria-live="polite"></p>')
    }
    $body.Add('</section>')
    for ($i = 0; $i -lt $Finding.Count; $i++) {
        $body.Add((Format-SecurityFindingSection -Finding $Finding[$i] -Number ($i + 1) -Count $Finding.Count -VMName $VMName))
    }
    return New-HtmlPage -Title $title -Subtitle "Scanned on $(Format-SecurityFindingTime -Time $ScannedAt)." -Body $body -WithCopyScript:($Finding.Count -gt 0)
}

function Format-SecurityFindingSection {
    <# One finding of LazyVM Findings.html: Format-SecurityFindingReport. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][SecurityFinding]$Finding,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$VMName
    )

    $severity = $Finding.Severity.ToLowerInvariant()
    $icon = $script:SecuritySeverityIcon[$Finding.Severity]
    $status = $Finding.Status.ToLowerInvariant().Replace(' ', '-')
    $where = @($Finding.Where | ForEach-Object { Split-Path -Path $_ -Leaf })
    # Every value is HTML by the time it is a field's, so the list is written as it is.
    $fields = [ordered]@{ 'Id' = (ConvertTo-HtmlText $Finding.Id); 'Severity' = (ConvertTo-HtmlText $Finding.Severity); 'What we found' = (ConvertTo-HtmlText $Finding.WhatWeFound) }
    if ($where.Count -gt 0) { $fields['Where'] = ConvertTo-HtmlText ($where -join '; ') }
    $fields['Why it matters'] = ConvertTo-HtmlText $Finding.WhyItMatters
    $fields['How to fix'] = ConvertTo-HtmlText $Finding.HowToFix
    $fields['First seen'] = ConvertTo-HtmlText (Format-SecurityFindingTime -Time $Finding.FirstSeen)
    $fields['Status'] = "<span class=`"chip $(ConvertTo-HtmlText $status)`">$(ConvertTo-HtmlText $Finding.Status)</span>"

    $html = [System.Collections.Generic.List[string]]::new()
    $html.Add("<section class=`"finding $severity`" aria-labelledby=`"finding-$Number`">")
    $html.Add("<h2 id=`"finding-$Number`">Finding $Number of ${Count}: <span class=`"badge $severity`"><span aria-hidden=`"true`">$icon</span> $(ConvertTo-HtmlText $Finding.Severity)</span> $(ConvertTo-HtmlText $Finding.Title)</h2>")
    $html.Add('<dl>')
    foreach ($field in $fields.GetEnumerator()) { $html.Add("<dt>$($field.Key)</dt><dd>$($field.Value)</dd>") }
    $html.Add('</dl>')
    if ($Finding.Status -ne 'Resolved') {
        $command = "Approve-LazyVMSecurityFinding -Name $(ConvertTo-PowerShellQuotedString -Text $VMName) -Id $(ConvertTo-PowerShellQuotedString -Text $Finding.Id)"
        $html.Add('<p>If you expect this, approve it on the host (in PowerShell), so it is no longer reported:</p>')
        $html.Add("<p class=`"command`"><code id=`"approve-$Number`">$(ConvertTo-HtmlText $command)</code><button type=`"button`" data-copy=`"approve-$Number`" aria-label=`"Copy approve command for finding $Number`">Copy</button></p>")
    }
    $html.Add('</section>')
    return $html -join "`n"
}

function Get-SecurityFindingReminderMessage {
    <#
      The one-line reminder of the VM's open findings of a severity that
      alerts ($AlertSeverity, the setting GuestSecurityScanAlertSeverity), with
      how many of each, or $null when it has none.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][object[]]$Finding = @(),
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AlertSeverity
    )

    $open = @($Finding | Where-Object { $_.Status -ne 'Resolved' -and $_.Severity -in $AlertSeverity })
    if ($open.Count -eq 0) { return $null }
    $counts = foreach ($level in [SecurityFinding]::Severities) {
        $count = @($open | Where-Object { $_.Severity -eq $level }).Count
        if ($count -gt 0) { "$count $level" }
    }
    return "$($open.Count) security finding(s) on $VMName need attention ($(@($counts) -join ', ')). See them with: Get-LazyVMSecurityFinding -Name $VMName"
}
