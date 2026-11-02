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
# A finding's Id is made from what was found, area first, such as
# 'Firewall:Public:Off'. The same thing found again has the same Id; when it
# changes, so does the Id. The area is the facts' name for the check, so a
# check the guest could not read tonight keeps its findings open.

# The order findings are listed in: most serious first, then the newest.
$script:SecurityFindingSeverities = @('High', 'Medium', 'Low', 'Info')
$script:SecurityFindingStatuses = @('New', 'Still open', 'Resolved')

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
    <# One finding, before it is compared with the last scan. #>
    [OutputType('LazyVM.SecurityFinding')]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium', 'Low', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$WhatWeFound,
        [Parameter(Mandatory)][string]$WhyItMatters,
        [Parameter(Mandatory)][string]$HowToFix
    )

    return [pscustomobject]@{
        PSTypeName   = 'LazyVM.SecurityFinding'
        Id           = $Id
        Severity     = $Severity
        Title        = $Title
        WhatWeFound  = $WhatWeFound
        WhyItMatters = $WhyItMatters
        HowToFix     = $HowToFix
    }
}

function Get-SecurityFindingArea {
    <# The area of the finding Id $Id: the part before the first colon. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Id)

    return ($Id -split ':', 2)[0]
}

function ConvertTo-SecurityFinding {
    <#
      Every finding in the facts $Check the guest script collected: the
      Defender checks, then the settings measured against the Microsoft
      security baseline. An area the guest could not read ($null) gives
      none. $Since is when the last scan ran, $null for the first.
    #>
    [OutputType('LazyVM.SecurityFinding')]
    param(
        [Parameter(Mandatory)][object]$Check,
        [AllowNull()][object]$Since,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt
    )

    # By area; an area the facts do not have is $null, as one the guest could not read.
    $fact = @{}
    foreach ($property in $Check.PSObject.Properties) { $fact[$property.Name] = $property.Value }
    $found = @(
        if ($null -ne $fact.Defender) { Get-DefenderStatusFinding -Fact $fact.Defender }
        if ($null -ne $fact.DefenderDetection) { Get-DefenderDetectionFinding -Fact $fact.DefenderDetection -Since $Since }
        if ($null -ne $fact.Firewall) { Get-FirewallFinding -Fact $fact.Firewall }
        if ($null -ne $fact.UAC) { Get-UacFinding -Fact $fact.UAC }
        if ($null -ne $fact.BitLocker) { Get-BitLockerFinding -Fact $fact.BitLocker }
        if ($null -ne $fact.SMBv1) { Get-Smb1Finding -Fact $fact.SMBv1 }
        if ($null -ne $fact.RemoteDesktop) { Get-RemoteDesktopFinding -Fact $fact.RemoteDesktop }
        if ($null -ne $fact.Account) { Get-GuestAccountFinding -Fact $fact.Account }
        if ($null -ne $fact.LSA) { Get-LsaProtectionFinding -Fact $fact.LSA }
        if ($null -ne $fact.SecureBoot) { Get-SecureBootFinding -Fact $fact.SecureBoot }
        if ($null -ne $fact.VBS) { Get-VbsFinding -Fact $fact.VBS }
        if ($null -ne $fact.AutoRun) { Get-AutoRunFinding -Fact $fact.AutoRun }
        if ($null -ne $fact.WindowsUpdate) { Get-WindowsUpdatePauseFinding -Fact $fact.WindowsUpdate -ScannedAt $ScannedAt }
        if ($null -ne $fact.AutoLogon) { Get-AutoLogonFinding -Fact $fact.AutoLogon }
    )
    return $found
}

function Get-UncheckedSecurityArea {
    <# The areas of the facts $Check the guest could not read tonight. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$Check)

    return @($Check.PSObject.Properties | Where-Object { $null -eq $_.Value } | ForEach-Object { $_.Name })
}

function Get-DefenderStatusFinding {
    <# Defender Antivirus, its real-time and tamper protection, and how old its virus definitions are. #>
    [OutputType('LazyVM.SecurityFinding')]
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
      it still lists on the first scan), by its detection id, so each
      detection is a finding of its own.
    #>
    [OutputType('LazyVM.SecurityFinding')]
    param(
        [Parameter(Mandatory)][object]$Fact,
        [AllowNull()][object]$Since
    )

    foreach ($detection in @($Fact.Detections)) {
        $detectedAt = [datetimeoffset]::Parse([string]$detection.DetectedAt, [cultureinfo]::InvariantCulture)
        if ($null -ne $Since -and $detectedAt -le [datetimeoffset]$Since) { continue }

        $status = [int]$detection.ThreatStatusId
        $done = if ($script:DefenderThreatStatus.ContainsKey($status)) { $script:DefenderThreatStatus[$status] } else { "reported status $status" }
        $handled = $status -in $script:DefenderThreatHandled -and $detection.ActionSuccess
        $where = @($detection.Resources | ForEach-Object { "$_" -replace '^[a-z]+:_', '' })
        $whereText = if ($where.Count -gt 0) { " in $($where -join '; ')" } else { '' }
        $fix = if ($handled) {
            'Defender dealt with it. Think about where the file came from, and do not run it again. Open Windows Security, choose Virus and threat protection, then Protection history, for the details.'
        }
        else {
            'Open Windows Security, choose Virus and threat protection, then Protection history, and choose the action Defender recommends. Then run a full scan. If you cannot remove it, rebuild the VM with Invoke-LazyVMRebuild.'
        }
        New-SecurityFinding -Id "DefenderDetection:$($detection.ThreatName):$($detection.DetectionId)" -Severity $(if ($handled) { 'Medium' } else { 'High' }) `
            -Title "Defender found $($detection.ThreatName)" `
            -WhatWeFound "Defender found $($detection.ThreatName) on $($detectedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))$whereText. Defender $done." `
            -WhyItMatters 'Malware got into this VM. Whatever brought it in may bring more.' `
            -HowToFix $fix
    }
}

function Get-FirewallFinding {
    <# Each Windows Firewall profile that is off, or that lets every connection in. #>
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
    param([Parameter(Mandatory)][object]$Fact)

    if (-not $Fact.Running) {
        New-SecurityFinding -Id 'VBS:Status:NotRunning' -Severity Low -Title 'Virtualization-based security is not running' `
            -WhatWeFound 'Windows is not running virtualization-based security (VBS), so Memory integrity and Credential Guard cannot run either.' `
            -WhyItMatters 'VBS keeps sign-in secrets and the Windows kernel apart from the rest of the system, out of malware''s reach.' `
            -HowToFix 'VBS in a Hyper-V VM needs nested virtualization. On the host, as administrator, with the VM off, run: Set-VMProcessor -VMName <the VM''s name> -ExposeVirtualizationExtensions $true. Then start the VM, and in Windows Security, under Device security, then Core isolation details, turn on Memory integrity.'
    }
}

function Get-AutoRunFinding {
    <# AutoRun, when it is not off for every drive as the Microsoft security baseline sets it. #>
    [OutputType('LazyVM.SecurityFinding')]
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
    [OutputType('LazyVM.SecurityFinding')]
    param(
        [Parameter(Mandatory)][object]$Fact,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt
    )

    $until = @($Fact.PausedUntil | ForEach-Object {
            $parsed = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse([string]$_, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $parsed }
        } | Where-Object { $_ -gt $ScannedAt } | Sort-Object -Descending)
    if ($until.Count -gt 0) {
        New-SecurityFinding -Id 'WindowsUpdate:Updates:Paused' -Severity Medium -Title 'Windows updates are paused' `
            -WhatWeFound "Windows Update is paused until $($until[0].ToLocalTime().ToString('yyyy-MM-dd'))." `
            -WhyItMatters 'Security fixes do not install while updates are paused, and nightly maintenance cannot install them either.' `
            -HowToFix 'In the VM, open Settings, then Windows Update, and choose Resume updates.'
    }
}

function Get-AutoLogonFinding {
    <# Automatic sign-in, which LazyVM keeps on by design: reported for information. #>
    [OutputType('LazyVM.SecurityFinding')]
    param([Parameter(Mandatory)][object]$Fact)

    if ($Fact.On) {
        New-SecurityFinding -Id 'AutoLogon:Winlogon:On' -Severity Info -Title 'Automatic sign-in is on' `
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
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()][object[]]$Current = @(),
        [AllowEmptyCollection()][object[]]$Previous = @(),
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt,
        [AllowEmptyCollection()][string[]]$Unchecked = @()
    )

    $open = @{}
    foreach ($finding in @($Previous | Where-Object { $_.Status -ne 'Resolved' })) { $open[$finding.Id] = $finding }
    $now = $ScannedAt.ToString('yyyy-MM-dd HH:mm')
    $currentIds = @($Current | ForEach-Object { $_.Id })

    $result = @(
        foreach ($finding in $Current) {
            $earlier = $open[$finding.Id]
            ConvertTo-ComparedSecurityFinding -Finding $finding -Status $(if ($earlier) { 'Still open' } else { 'New' }) -FirstSeen $(if ($earlier) { $earlier.FirstSeen } else { $now })
        }
        foreach ($finding in $open.Values) {
            if ($finding.Id -in $currentIds) { continue }
            $status = if ((Get-SecurityFindingArea -Id $finding.Id) -in $Unchecked) { 'Still open' } else { 'Resolved' }
            ConvertTo-ComparedSecurityFinding -Finding $finding -Status $status -FirstSeen $finding.FirstSeen
        }
    )
    return @($result | Sort-Object -Property @(
            @{ Expression = { $script:SecurityFindingSeverities.IndexOf($_.Severity) } }
            @{ Expression = { $script:SecurityFindingStatuses.IndexOf($_.Status) } }
            @{ Expression = { $_.Id } }
        ))
}

function ConvertTo-ComparedSecurityFinding {
    <# $Finding with its Status and when it was FirstSeen, in the order the findings file keeps. #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Finding,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$FirstSeen
    )

    return [pscustomobject][ordered]@{
        Id           = $Finding.Id
        Severity     = $Finding.Severity
        Title        = $Finding.Title
        WhatWeFound  = $Finding.WhatWeFound
        WhyItMatters = $Finding.WhyItMatters
        HowToFix     = $Finding.HowToFix
        FirstSeen    = $FirstSeen
        Status       = $Status
    }
}

function Test-SecurityFindingAlert {
    <# Whether the scan found something new that is High or Medium: what opens the findings file at the next sign-in. #>
    [OutputType([bool])]
    param([AllowEmptyCollection()][object[]]$Finding = @())

    return @($Finding | Where-Object { $_.Status -eq 'New' -and $_.Severity -in 'High', 'Medium' }).Count -gt 0
}

function Format-SecurityFinding {
    <# One finding as lines of text, one field to a line. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$Finding)

    return @(
        "Id: $($Finding.Id)"
        "Severity: $($Finding.Severity)"
        "Title: $($Finding.Title)"
        "What we found: $($Finding.WhatWeFound)"
        "Why it matters: $($Finding.WhyItMatters)"
        "How to fix: $($Finding.HowToFix)"
        "First seen: $($Finding.FirstSeen)"
        "Status: $($Finding.Status)"
    )
}

function Format-SecurityFindingCount {
    <# How many findings there are, and how many of them are new, still open and resolved, as one sentence. #>
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Finding = @())

    $count = { param($status) @($Finding | Where-Object { $_.Status -eq $status }).Count }
    $noun = if ($Finding.Count -eq 1) { 'finding' } else { 'findings' }
    return "$($Finding.Count) ${noun}: $(& $count 'New') new, $(& $count 'Still open') still open, $(& $count 'Resolved') resolved."
}

function Format-SecurityFindingReport {
    <#
      The text of LazyVM Findings.txt on the guest's desktop: what it is,
      when the scan ran, then each finding one field to a line, with a blank
      line between, and Windows line endings for Notepad.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][object[]]$Finding = @(),
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("LazyVM security findings for $VMName")
    $lines.Add("Scanned on $($ScannedAt.ToString('yyyy-MM-dd HH:mm')).")
    $lines.Add('LazyVM only reports what it finds. It changed nothing in this VM.')
    $lines.Add('This file is replaced after every nightly scan.')
    $lines.Add('')
    if ($Finding.Count -eq 0) {
        $lines.Add('No security findings. Everything LazyVM checks looks right.')
    }
    else {
        $lines.Add((Format-SecurityFindingCount -Finding $Finding))
        $lines.Add("On the host, see them with: Get-LazyVMSecurityFinding -Name $VMName")
        for ($i = 0; $i -lt $Finding.Count; $i++) {
            $lines.Add('')
            $lines.Add("Finding $($i + 1) of $($Finding.Count)")
            foreach ($line in (Format-SecurityFinding -Finding $Finding[$i])) { $lines.Add($line) }
        }
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Get-SecurityFindingReminderMessage {
    <# The one-line reminder of the VM's open High and Medium findings, or $null when it has none. #>
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][object[]]$Finding = @(),
        [Parameter(Mandatory)][string]$VMName
    )

    $open = @($Finding | Where-Object { $_.Status -ne 'Resolved' })
    $high = @($open | Where-Object { $_.Severity -eq 'High' }).Count
    $medium = @($open | Where-Object { $_.Severity -eq 'Medium' }).Count
    if ($high + $medium -eq 0) { return $null }
    return "$($high + $medium) security finding(s) on $VMName need attention ($high High, $medium Medium). See them with: Get-LazyVMSecurityFinding -Name $VMName"
}
