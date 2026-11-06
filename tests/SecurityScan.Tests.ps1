# SecurityScan.Tests.ps1
# The nightly security scan of each guest (#290, part 1): the guest script
# that collects the facts, the pure functions that turn them into findings
# and compare them with the last scan, the findings file on the guest's
# desktop and the sign-in opener, and the reminder on the host. The guest is
# mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $scannedAt = [datetimeoffset]::new(2026, 11, 2, 2, 40, 0, [timespan]::FromHours(-8))

    function New-GoodCheck {
        <# What the guest script reports for a guest that meets every check, as the host reads it back from JSON. #>
        $checks = [ordered]@{
            Defender          = @{ AMServiceEnabled = $true; AntivirusEnabled = $true; RealTimeProtectionEnabled = $true; IsTamperProtected = $true; AntivirusSignatureAge = 0; AntivirusSignatureLastUpdated = '2026-11-01' }
            DefenderDetection = @{ Detections = @(); ActiveThreatIds = @() }
            Firewall          = @{ Profiles = @(@{ Name = 'Domain'; Enabled = $true; DefaultInboundAction = 'Block' }, @{ Name = 'Private'; Enabled = $true; DefaultInboundAction = 'NotConfigured' }, @{ Name = 'Public'; Enabled = $true; DefaultInboundAction = 'Block' }) }
            UAC               = @{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 5; PromptOnSecureDesktop = 1 }
            BitLocker         = @{ Volumes = @(@{ MountPoint = 'C:'; ProtectionStatus = 'On' }) }
            SMBv1             = @{ Enabled = $false }
            RemoteDesktop     = @{ Enabled = $true; Nla = $true }
            Account           = @{ GuestEnabled = $false }
            LSA               = @{ RunAsPPL = $null; ProtectedSinceBoot = $true }
            SecureBoot        = @{ On = $true }
            VBS               = @{ Running = $true }
            AutoRun           = @{ NoAutorun = 1; NoDriveTypeAutoRun = 255 }
            WindowsUpdate     = @{ PausedUntil = @() }
            AutoLogon         = @{ On = $false }
            LogCleared        = @{ Events = @() }
            SignIn            = @{ Events = @() }
            AccountChange     = @{ Events = @() }
            Sysmon            = @{ Events = @() }
            PowerShellScript  = @{ Events = @() }
            CrashDump         = @{ Items = @() }
        }
        return (ConvertTo-Json -InputObject $checks -Depth 6 | ConvertFrom-Json -DateKind String)
    }

    function New-TestFinding {
        <# A finding as the scan keeps it. #>
        param(
            [string]$Id = 'Firewall:Public:Off',
            [string]$Severity = 'High',
            [string]$Status = 'New',
            [string]$FirstSeen = '2026-11-01T02:40:00.0000000-08:00',
            [string[]]$Where = @()
        )

        $record = @{ Id = $Id; Severity = $Severity; Title = "Title of $Id"; WhatWeFound = 'found'; Where = $Where; WhyItMatters = 'why'; HowToFix = 'fix'; FirstSeen = $FirstSeen; Status = $Status }
        return InModuleScope $module -Parameters @{ Record = $record } { param($Record) [SecurityFinding]::FromObject($Record) }
    }

    function Format-TestTime {
        <# A time as the findings show it. #>
        param([Parameter(Mandatory)][string]$Time)
        return ([datetimeoffset]::Parse($Time)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    }

    function ConvertTo-TestFinding {
        <# Runs the checks on $Check inside the module. #>
        param(
            [Parameter(Mandatory)][object]$Check,
            [AllowNull()][object]$Since
        )

        return @(InModuleScope $module -Parameters @{ Check = $Check; Since = $Since; ScannedAt = $scannedAt } {
                param($Check, $Since, $ScannedAt)
                ConvertTo-SecurityFinding -Check $Check -Since $Since -ScannedAt $ScannedAt
            })
    }

    function New-TestVM {
        <# The context of VM Alpha under $Root, with the scan on unless $Off. #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$Off
        )

        $settings = @{
            VMName                         = 'Alpha'
            Root                           = $Root
            GuestSecurityScan              = -not $Off
            GuestSecurityScanAlertSeverity = @('High', 'Medium', 'Low', 'Info')
            SecurityFindingsFile           = Join-Path -Path $Root -ChildPath 'Alpha/Logs/SecurityFindings.json'
            SecurityBaselineFile           = Join-Path -Path $Root -ChildPath 'Alpha/Config/SecurityBaseline.json'
        }
        return InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }
    }

    function New-TestRoot {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
}

Describe 'ConvertTo-SecurityFinding' {
    It 'finds nothing on a guest that meets every check' {
        $found = @(ConvertTo-TestFinding -Check (New-GoodCheck))

        $found.Count | Should -Be 0
    }

    It 'reports <Case> as <Severity> <Id>' -ForEach @(
        @{ Case = 'Defender Antivirus off'; Area = 'Defender'; Field = 'AntivirusEnabled'; Value = $false; Id = 'Defender:Antivirus:Off'; Severity = 'High' }
        @{ Case = 'the Defender service off'; Area = 'Defender'; Field = 'AMServiceEnabled'; Value = $false; Id = 'Defender:Antivirus:Off'; Severity = 'High' }
        @{ Case = 'real-time protection off'; Area = 'Defender'; Field = 'RealTimeProtectionEnabled'; Value = $false; Id = 'Defender:RealTimeProtection:Off'; Severity = 'High' }
        @{ Case = 'tamper protection off'; Area = 'Defender'; Field = 'IsTamperProtected'; Value = $false; Id = 'Defender:TamperProtection:Off'; Severity = 'Medium' }
        @{ Case = 'virus definitions 8 days old'; Area = 'Defender'; Field = 'AntivirusSignatureAge'; Value = 8; Id = 'Defender:Signatures:OutOfDate'; Severity = 'Medium' }
        @{ Case = 'UAC off'; Area = 'UAC'; Field = 'EnableLUA'; Value = 0; Id = 'UAC:EnableLUA:Off'; Severity = 'High' }
        @{ Case = 'administrators elevated without a prompt'; Area = 'UAC'; Field = 'ConsentPromptBehaviorAdmin'; Value = 0; Id = 'UAC:AdminPrompt:Off'; Severity = 'Medium' }
        @{ Case = 'the UAC prompt off the secure desktop'; Area = 'UAC'; Field = 'PromptOnSecureDesktop'; Value = 0; Id = 'UAC:SecureDesktop:Off'; Severity = 'Low' }
        @{ Case = 'SMBv1 on'; Area = 'SMBv1'; Field = 'Enabled'; Value = $true; Id = 'SMBv1:Server:On'; Severity = 'High' }
        @{ Case = 'Remote Desktop without NLA'; Area = 'RemoteDesktop'; Field = 'Nla'; Value = $false; Id = 'RemoteDesktop:NLA:Off'; Severity = 'High' }
        @{ Case = 'the Guest account on'; Area = 'Account'; Field = 'GuestEnabled'; Value = $true; Id = 'Account:Guest:Enabled'; Severity = 'High' }
        @{ Case = 'LSA protection off'; Area = 'LSA'; Field = 'ProtectedSinceBoot'; Value = $false; Id = 'LSA:Protection:Off'; Severity = 'Medium' }
        @{ Case = 'Secure Boot off'; Area = 'SecureBoot'; Field = 'On'; Value = $false; Id = 'SecureBoot:UEFI:Off'; Severity = 'Medium' }
        @{ Case = 'VBS not running'; Area = 'VBS'; Field = 'Running'; Value = $false; Id = 'VBS:Status:NotRunning'; Severity = 'Low' }
        @{ Case = 'AutoRun not off for every drive'; Area = 'AutoRun'; Field = 'NoDriveTypeAutoRun'; Value = 145; Id = 'AutoRun:AllDrives:On'; Severity = 'Low' }
        @{ Case = 'AutoRun not set to do nothing'; Area = 'AutoRun'; Field = 'NoAutorun'; Value = $null; Id = 'AutoRun:AllDrives:On'; Severity = 'Low' }
        @{ Case = 'automatic sign-in, by design'; Area = 'AutoLogon'; Field = 'On'; Value = $true; Id = 'AutoLogon:Winlogon:On'; Severity = 'Info' }
    ) {
        $check = New-GoodCheck
        $check.$Area.$Field = $Value

        $found = @(ConvertTo-TestFinding -Check $check)

        $found.Count | Should -Be 1
        $found[0].Id | Should -Be $Id
        $found[0].Severity | Should -Be $Severity
        foreach ($field in 'Title', 'WhatWeFound', 'WhyItMatters', 'HowToFix') { $found[0].$field | Should -Not -BeNullOrEmpty -Because $field }
    }

    It 'reports only the antivirus when it is off, not its real-time protection as well' {
        $check = New-GoodCheck
        $check.Defender.AntivirusEnabled = $false
        $check.Defender.RealTimeProtectionEnabled = $false

        @(ConvertTo-TestFinding -Check $check).Id | Should -Be @('Defender:Antivirus:Off')
    }

    It 'says how old the virus definitions are, and leaves a week alone' {
        $check = New-GoodCheck
        $check.Defender.AntivirusSignatureAge = 7
        @(ConvertTo-TestFinding -Check $check).Count | Should -Be 0

        $check.Defender.AntivirusSignatureAge = 12
        @(ConvertTo-TestFinding -Check $check)[0].WhatWeFound | Should -BeLike '*12 days old*2026-11-01*'
    }

    It 'reports a firewall profile that is <Case>' -ForEach @(
        @{ Case = 'off'; Enabled = $false; Inbound = 'Block'; Id = 'Firewall:Public:Off'; Severity = 'High' }
        @{ Case = 'on but lets every connection in'; Enabled = $true; Inbound = 'Allow'; Id = 'Firewall:Public:InboundAllowed'; Severity = 'Medium' }
    ) {
        $check = New-GoodCheck
        $check.Firewall.Profiles[2].Enabled = $Enabled
        $check.Firewall.Profiles[2].DefaultInboundAction = $Inbound

        $found = @(ConvertTo-TestFinding -Check $check)

        $found.Id | Should -Be @($Id)
        $found[0].Severity | Should -Be $Severity
        $found[0].Title | Should -BeLike '*Public*'
    }

    It 'reports each disk BitLocker does not protect, by its letter' {
        $check = New-GoodCheck
        $check.BitLocker.Volumes = @([pscustomobject]@{ MountPoint = 'C:'; ProtectionStatus = 'On' }, [pscustomobject]@{ MountPoint = 'W:'; ProtectionStatus = 'Off' }, [pscustomobject]@{ MountPoint = 'U:'; ProtectionStatus = 'Unknown' })

        $found = @(ConvertTo-TestFinding -Check $check)

        $found.Id | Should -Be @('BitLocker:W:Off')
        $found[0].Severity | Should -Be 'Medium'
    }

    It 'leaves Remote Desktop alone when it is off, NLA or not' {
        $check = New-GoodCheck
        $check.RemoteDesktop.Enabled = $false
        $check.RemoteDesktop.Nla = $false

        @(ConvertTo-TestFinding -Check $check).Count | Should -Be 0
    }

    It 'takes LSA protection set to start at the next restart as on' {
        $check = New-GoodCheck
        $check.LSA.ProtectedSinceBoot = $false
        $check.LSA.RunAsPPL = 2

        @(ConvertTo-TestFinding -Check $check).Count | Should -Be 0
    }

    It 'reports Windows Update paused only until a date still to come' {
        $check = New-GoodCheck
        $check.WindowsUpdate.PausedUntil = @('2026-10-01T00:00:00Z')
        @(ConvertTo-TestFinding -Check $check).Count | Should -Be 0

        $check.WindowsUpdate.PausedUntil = @('2026-10-01T00:00:00Z', '2026-11-20T23:30:00Z', 'not a date')
        $found = @(ConvertTo-TestFinding -Check $check)
        $found.Id | Should -Be @('WindowsUpdate:PausedUntil:2026-11-20')
        $found[0].Severity | Should -Be 'Medium'
        $found[0].WhatWeFound | Should -BeLike ('*' + ([datetimeoffset]'2026-11-20T23:30:00Z').ToLocalTime().ToString('yyyy-MM-dd') + '*')
    }

    It 'leaves out an area the guest could not read' {
        $check = New-GoodCheck
        $check.Firewall = $null
        $check.Defender = $null

        @(ConvertTo-TestFinding -Check $check).Count | Should -Be 0
    }

    Context 'Defender detections' {
        BeforeAll {
            function New-DetectionCheck {
                param([object[]]$Detection, [string[]]$Active = @())
                $check = New-GoodCheck
                $check.DefenderDetection.Detections = @($Detection)
                $check.DefenderDetection.ActiveThreatIds = @($Active)
                return $check
            }

            $quarantined = [pscustomobject]@{ DetectionId = '{D1}'; ThreatId = '101'; ThreatName = 'Trojan:Win32/Sample'; DetectedAt = '2026-11-01T20:00:00.0000000Z'; Resources = @('file:_C:\Users\dev\Downloads\x.exe'); ThreatStatusId = 3; ActionSuccess = $true }
            $notRemoved = [pscustomobject]@{ DetectionId = '{D2}'; ThreatId = '102'; ThreatName = 'Backdoor:Win32/Other'; DetectedAt = '2026-11-01T21:00:00.0000000Z'; Resources = @('file:_C:\Tools\y.dll'); ThreatStatusId = 103; ActionSuccess = $false }
            $old = [pscustomobject]@{ DetectionId = '{D0}'; ThreatId = '100'; ThreatName = 'Trojan:Win32/Old'; DetectedAt = '2026-10-20T10:00:00.0000000Z'; Resources = @(); ThreatStatusId = 4; ActionSuccess = $true }
            $since = [datetimeoffset]::Parse('2026-11-01T02:40:00-08:00')
        }

        It 'reports each detection since the last scan, by its detection id, Medium when Defender dealt with it and High when not' {
            $found = @(ConvertTo-TestFinding -Check (New-DetectionCheck -Detection $quarantined, $notRemoved, $old) -Since $since)

            $found.Id | Should -Be @('DefenderDetection:101:{D1}', 'DefenderDetection:102:{D2}')
            $found[0].Title | Should -Be 'Defender found Trojan:Win32/Sample'
            $found[0].Severity | Should -Be 'Medium'
            $found[0].WhatWeFound | Should -BeLike '*Trojan:Win32/Sample*quarantined*'
            $found[0].Where | Should -Be @('C:\Users\dev\Downloads\x.exe')
            $found[1].Severity | Should -Be 'High'
            $found[1].WhatWeFound | Should -BeLike '*could not remove it*'
        }

        It 'keeps reporting, as High, an older detection whose threat Defender still lists as active' {
            $found = @(ConvertTo-TestFinding -Check (New-DetectionCheck -Detection $old -Active '100') -Since $since)

            $found.Id | Should -Be @('DefenderDetection:100:{D0}')
            $found[0].Severity | Should -Be 'High'
            $found[0].WhatWeFound | Should -BeLike '*still lists it as active*'
        }

        It 'reports only the newest detection of a threat that is still active, not its older ones' {
            $older = [pscustomobject]@{ DetectionId = '{D9}'; ThreatId = '100'; ThreatName = 'Trojan:Win32/Old'; DetectedAt = '2026-10-01T10:00:00.0000000Z'; Resources = @(); ThreatStatusId = 4; ActionSuccess = $true }

            $found = @(ConvertTo-TestFinding -Check (New-DetectionCheck -Detection $older, $old -Active '100') -Since $since)

            $found.Id | Should -Be @('DefenderDetection:100:{D0}')
        }

        It 'reports every detection Defender still lists on the first scan' {
            @(ConvertTo-TestFinding -Check (New-DetectionCheck -Detection $quarantined, $old) -Since $null).Count | Should -Be 2
        }
    }
}

Describe 'Get-UncheckedSecurityArea' {
    It 'names the areas the guest could not read' {
        $check = New-GoodCheck
        $check.Firewall = $null
        $check.LSA = $null

        $unchecked = InModuleScope $module -Parameters @{ Check = $check } { param($Check) Get-UncheckedSecurityArea -Check $Check }

        $unchecked | Should -Be @('Firewall', 'LSA')
    }

    It 'names an area the facts do not have at all' {
        $check = New-GoodCheck
        $check.PSObject.Properties.Remove('AutoRun')

        InModuleScope $module -Parameters @{ Check = $check } { param($Check) Get-UncheckedSecurityArea -Check $Check } | Should -Be @('AutoRun')
    }
}

Describe 'Compare-SecurityFinding' {
    BeforeAll {
        function Compare-TestFinding {
            param(
                [object[]]$Current = @(),
                [object[]]$Previous = @(),
                [string[]]$Unchecked = @()
            )
            return @(InModuleScope $module -Parameters @{ Current = $Current; Previous = $Previous; Unchecked = $Unchecked; ScannedAt = $scannedAt } {
                    param($Current, $Previous, $Unchecked, $ScannedAt)
                    Compare-SecurityFinding -Current $Current -Previous $Previous -ScannedAt $ScannedAt -Unchecked $Unchecked
                })
        }

        function New-CurrentFinding {
            param([string]$Id = 'Firewall:Public:Off', [string]$Severity = 'High')
            return InModuleScope $module -Parameters @{ Id = $Id; Severity = $Severity } {
                param($Id, $Severity)
                New-SecurityFinding -Id $Id -Severity $Severity -Title "Title of $Id" -WhatWeFound 'found' -WhyItMatters 'why' -HowToFix 'fix'
            }
        }
    }

    It 'marks a finding the last scan did not have as New, first seen now' {
        $result = @(Compare-TestFinding -Current (New-CurrentFinding))

        $result[0].Status | Should -Be 'New'
        $result[0].FirstSeen | Should -Be $scannedAt
    }

    It 'marks a finding the last scan had as Still open, first seen when it was' {
        $result = @(Compare-TestFinding -Current (New-CurrentFinding) -Previous (New-TestFinding -Status 'New' -FirstSeen '2026-10-30T02:40:00.0000000-08:00'))

        $result[0].Status | Should -Be 'Still open'
        $result[0].FirstSeen | Should -Be ([datetimeoffset]'2026-10-30T02:40:00-08:00')
    }

    It 'marks an open finding the scan no longer finds as Resolved, once' {
        $previous = @(
            New-TestFinding -Id 'UAC:EnableLUA:Off' -Status 'Still open'
            New-TestFinding -Id 'SMBv1:Server:On' -Status 'Resolved'
        )

        $result = @(Compare-TestFinding -Previous $previous)

        $result.Id | Should -Be @('UAC:EnableLUA:Off')
        $result[0].Status | Should -Be 'Resolved'
    }

    It 'marks a finding that is back after it was resolved as New' {
        $result = @(Compare-TestFinding -Current (New-CurrentFinding) -Previous (New-TestFinding -Status 'Resolved' -FirstSeen '2026-10-01T02:40:00.0000000-08:00'))

        $result[0].Status | Should -Be 'New'
        $result[0].FirstSeen | Should -Be $scannedAt
    }

    It 'keeps an open finding of an area the guest could not read tonight as Still open' {
        $result = @(Compare-TestFinding -Previous (New-TestFinding -Id 'Firewall:Public:Off' -Status 'New') -Unchecked 'Firewall')

        $result[0].Status | Should -Be 'Still open'
        $result[0].Id | Should -Be 'Firewall:Public:Off'
    }

    It 'puts High first, then the new ones' {
        $current = @(
            New-CurrentFinding -Id 'VBS:Status:NotRunning' -Severity 'Low'
            New-CurrentFinding -Id 'Account:Guest:Enabled' -Severity 'High'
            New-CurrentFinding -Id 'SMBv1:Server:On' -Severity 'High'
        )

        $result = @(Compare-TestFinding -Current $current -Previous (New-TestFinding -Id 'Account:Guest:Enabled' -Status 'New'))

        $result.Id | Should -Be @('SMBv1:Server:On', 'Account:Guest:Enabled', 'VBS:Status:NotRunning')
    }
}

Describe 'Test-SecurityFindingAlert' {
    It 'is <Expected> for a <Status> <Severity> finding when High and Medium alert' -ForEach @(
        @{ Status = 'New'; Severity = 'High'; Expected = $true }
        @{ Status = 'New'; Severity = 'Medium'; Expected = $true }
        @{ Status = 'New'; Severity = 'Low'; Expected = $false }
        @{ Status = 'New'; Severity = 'Info'; Expected = $false }
        @{ Status = 'Still open'; Severity = 'High'; Expected = $false }
        @{ Status = 'Resolved'; Severity = 'High'; Expected = $false }
    ) {
        $finding = New-TestFinding -Status $Status -Severity $Severity

        InModuleScope $module -Parameters @{ Finding = $finding } { param($Finding) Test-SecurityFindingAlert -Finding @($Finding) -AlertSeverity 'High', 'Medium' } | Should -Be $Expected
    }

    It 'is $false for anything when no severity alerts' {
        $finding = New-TestFinding -Status 'New' -Severity 'High'

        InModuleScope $module -Parameters @{ Finding = $finding } { param($Finding) Test-SecurityFindingAlert -Finding @($Finding) -AlertSeverity @() } | Should -BeFalse
    }
}

Describe 'Format-SecurityFindingReport' {
    It 'says what it is, that LazyVM changed nothing, then each finding one field per line' {
        $findings = @((New-TestFinding -Id 'Firewall:Public:Off' -Where 'C:\Users\dev\Downloads\x.exe'), (New-TestFinding -Id 'AutoLogon:Winlogon:On' -Severity 'Info' -Status 'Still open'))

        $text = InModuleScope $module -Parameters @{ Finding = $findings; ScannedAt = $scannedAt } { param($Finding, $ScannedAt) Format-SecurityFindingReport -Finding $Finding -VMName 'Alpha' -ScannedAt $ScannedAt }
        $lines = $text -split "`r`n"

        $lines[0] | Should -Be 'LazyVM security findings for Alpha'
        $lines | Should -Contain "Scanned on $(Format-TestTime -Time $scannedAt.ToString('o'))."
        $lines | Should -Contain 'LazyVM only reports what it finds. It changed nothing in this VM.'
        $lines | Should -Contain '2 findings: 1 new, 1 still open, 0 resolved.'
        $lines | Should -Contain 'Finding 1 of 2'
        $lines | Should -Contain 'Id: Firewall:Public:Off'
        $lines | Should -Contain 'Severity: High'
        $lines | Should -Contain 'Title: Title of Firewall:Public:Off'
        $lines | Should -Contain 'What we found: found'
        $lines | Should -Contain 'Where: x.exe'
        $lines | Should -Contain 'Why it matters: why'
        $lines | Should -Contain 'How to fix: fix'
        $lines | Should -Contain "First seen: $(Format-TestTime -Time '2026-11-01T02:40:00-08:00')"
        $lines | Should -Contain 'Status: New'
        $text | Should -Not -Match "(?<!`r)`n"
        $text | Should -Not -BeLike '*Downloads*'
    }

    It 'lists the full paths in the log' {
        $lines = InModuleScope $module -Parameters @{ Finding = (New-TestFinding -Where 'C:\Users\dev\Downloads\x.exe') } { param($Finding) Format-SecurityFinding -Finding $Finding }

        $lines | Should -Contain 'Where: C:\Users\dev\Downloads\x.exe'
    }

    It 'says so when there is nothing to report' {
        $text = InModuleScope $module -Parameters @{ ScannedAt = $scannedAt } { param($ScannedAt) Format-SecurityFindingReport -Finding @() -VMName 'Alpha' -ScannedAt $ScannedAt }

        $text | Should -BeLike '*No security findings. Everything LazyVM checks looks right.*'
    }
}

Describe 'Get-SecurityFindingReminderMessage' {
    It 'counts the open High and Medium findings, with the command to see them' {
        $findings = @(
            New-TestFinding -Severity 'High' -Status 'New'
            New-TestFinding -Severity 'Medium' -Status 'Still open'
            New-TestFinding -Severity 'Medium' -Status 'Resolved'
            New-TestFinding -Severity 'Low' -Status 'New'
        )

        $message = InModuleScope $module -Parameters @{ Finding = $findings } { param($Finding) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -AlertSeverity 'High', 'Medium' }

        $message | Should -Be '2 security finding(s) on Alpha need attention (1 High, 1 Medium). See them with: Get-LazyVMSecurityFinding -Name Alpha'
    }

    It 'says nothing when only resolved findings, or those of severities that do not alert, are left' {
        $findings = @((New-TestFinding -Severity 'Low'), (New-TestFinding -Severity 'High' -Status 'Resolved'))

        InModuleScope $module -Parameters @{ Finding = $findings } { param($Finding) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -AlertSeverity 'High', 'Medium' } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-GuestSecurityScan' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        Mock -ModuleName $module Publish-GuestSecurityFinding { }
        $script:check = New-GoodCheck
        $script:collectedAt = '2026-11-02T10:40:00.0000000Z'
        Mock -ModuleName $module Get-GuestSecurityFact { [pscustomobject]@{ CollectedAt = $script:collectedAt; Checks = $script:check } }
        # A guest whose places programs start from are all empty, and read.
        $script:noPersistence = [ordered]@{}
        foreach ($area in (InModuleScope $module { @($script:PersistenceCheck.Keys) })) { $script:noPersistence[$area] = @() }
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = [pscustomobject]$script:noPersistence } }
    }

    It 'leaves the guest alone when GuestSecurityScan is off' {
        InModuleScope $module -Parameters @{ VM = (New-TestVM -Root (New-TestRoot) -Off) } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestSecurityFact -Times 0
        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'turned off in the settings \(GuestSecurityScan\)' }
    }

    It 'has the guest read from when the last scan collected, and from the first scan''s window when there was none (#290)' {
        $vm = New-TestVM -Root (New-TestRoot)

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }
        $script:collectedAt = '2026-11-03T10:40:00.0000000Z'
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestSecurityFact -Times 1 -Exactly -ParameterFilter { $null -eq $Since }
        Should -Invoke -ModuleName $module Get-GuestSecurityFact -Times 1 -Exactly -ParameterFilter { $null -ne $Since -and ([datetimeoffset]$Since) -eq [datetimeoffset]'2026-11-02T10:40:00Z' }
    }

    It 'keeps the findings, logs each one, and asks the guest to open the desktop file for new High ones, once' {
        $vm = New-TestVM -Root (New-TestRoot)
        $script:check.SMBv1.Enabled = $true

        $result = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM })

        $result.Count | Should -Be 0
        $record = Get-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json -DateKind String
        [datetimeoffset]::Parse($record.ScannedAt) | Should -Be ([datetimeoffset]$script:collectedAt)
        @($record.Findings).Id | Should -Be @('SMBv1:Server:On')
        @($record.Findings)[0].Status | Should -Be 'New'
        [datetimeoffset]::Parse(@($record.Findings)[0].FirstSeen) | Should -Be ([datetimeoffset]$script:collectedAt)
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*Id: SMBv1:Server:On*' -and $Level -eq 'WARN' }
        Should -Invoke -ModuleName $module Install-GuestSecurityFindingOpener -Times 1 -Exactly
        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 1 -Exactly -ParameterFilter { $AlertScanId -match '^\d{8}-\d{6}$' -and $Text -like '*Id: SMBv1:Server:On*' }

        # The next night finds the same: still open, so the file is not asked to open again.
        $script:collectedAt = '2026-11-03T10:40:00.0000000Z'
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        @((Get-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json).Findings)[0].Status | Should -Be 'Still open'
        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 1 -Exactly -ParameterFilter { $AlertScanId -eq '' -and $Text -like '*Status: Still open*' }
    }

    It 'keeps nothing when the findings did not reach the guest, so the next night they are still new' {
        $vm = New-TestVM -Root (New-TestRoot)
        $script:check.SMBv1.Enabled = $true
        Mock -ModuleName $module Publish-GuestSecurityFinding { throw 'the guest stopped answering' }

        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM } } | Should -Throw '*stopped answering*'

        $vm.Settings.SecurityFindingsFile | Should -Not -Exist
    }

    It 'takes a kept finding with <Case> as unreadable, so as a first scan' -ForEach @(
        @{ Case = 'no FirstSeen'; Field = 'FirstSeen'; Value = $null }
        @{ Case = 'a status it does not know'; Field = 'Status'; Value = 'Closed' }
    ) {
        $vm = New-TestVM -Root (New-TestRoot)
        $finding = (New-TestFinding).ToRecord()
        $finding[$Field] = $Value
        New-Item -ItemType Directory -Path (Split-Path -Path $vm.Settings.SecurityFindingsFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Value (ConvertTo-Json -InputObject @{ ScannedAt = '2026-11-01T10:40:00Z'; Findings = @($finding) } -Depth 4)

        $record = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Read-SecurityFindingRecord -VM $VM }

        $record | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*could not be read*first scan*' -and $Level -eq 'WARN' }
    }

    It 'takes findings it cannot read as a first scan, and says so' {
        $vm = New-TestVM -Root (New-TestRoot)
        New-Item -ItemType Directory -Path (Split-Path -Path $vm.Settings.SecurityFindingsFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Value 'not json'

        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*could not be read*first scan*' -and $Level -eq 'WARN' }
        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 1 -Exactly
    }

    It 'keeps a detection open while Defender lists it as active, and resolves it once it does not' {
        $vm = New-TestVM -Root (New-TestRoot)
        # Detected an hour before the first collection.
        $script:check.DefenderDetection.Detections = @([pscustomobject]@{ DetectionId = '{D1}'; ThreatId = '7'; ThreatName = 'Trojan:Win32/Sample'; DetectedAt = '2026-11-02T09:40:00Z'; Resources = @(); ThreatStatusId = 103; ActionSuccess = $false })
        $script:check.DefenderDetection.ActiveThreatIds = @('7')
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        $script:collectedAt = '2026-11-03T10:40:00.0000000Z'
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }
        @((Get-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json).Findings)[0].Status | Should -Be 'Still open'

        $script:collectedAt = '2026-11-04T10:40:00.0000000Z'
        $script:check.DefenderDetection.ActiveThreatIds = @()
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }
        $findings = @((Get-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json).Findings)
        $findings.Count | Should -Be 1
        $findings[0].Status | Should -Be 'Resolved'
    }
}

Describe 'Get-GuestSecurityFact' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-GuestTask { '{"CollectedAt":"2026-11-02T10:40:00Z","Notes":[{"Level":"OK","Text":"Defender quick scan finished"}],"Checks":{"SMBv1":{"Enabled":false},"Firewall":null}}' }
    }

    It 'runs the collector as SYSTEM within its time budget, and logs what it reports' {
        $vm = New-TestVM -Root (New-TestRoot)

        $facts = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-GuestSecurityFact -VM $VM }

        $facts.Checks.SMBv1.Enabled | Should -BeFalse
        $facts.CollectedAt | Should -Be '2026-11-02T10:40:00Z'
        $expected = InModuleScope $module { "$script:GuestSecurityScanWork" }
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            -not $AsGuestUser -and $TimeoutMinutes -eq 20 -and "$Work" -eq $expected -and $ArgumentList[0] -eq 15
        }
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*Defender quick scan finished*' -and $Level -eq 'OK' }
    }

    It 'has the guest read the first scan''s window, 24 hours back, when there is no earlier scan (#290)' {
        $vm = New-TestVM -Root (New-TestRoot)

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-GuestSecurityFact -VM $VM -Since $null }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq '' -and $ArgumentList[3] -eq 24 }
    }

    It 'has the guest read the events and files since the last scan, in UTC (#290)' {
        $vm = New-TestVM -Root (New-TestRoot)
        $since = [datetimeoffset]::new(2026, 11, 2, 2, 40, 0, [timespan]::FromHours(-8))

        $null = InModuleScope $module -Parameters @{ VM = $vm; Since = $since } { param($VM, $Since) Get-GuestSecurityFact -VM $VM -Since $Since }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { [datetimeoffset]::Parse($ArgumentList[1]) -eq $since -and $ArgumentList[1] -like '*Z' }
    }

    It 'gives the guest the patterns script blocks are tested against, and nothing else about them (#290)' {
        $vm = New-TestVM -Root (New-TestRoot)
        $patterns = InModuleScope $module { @($script:SuspiciousPowerShell | ForEach-Object { $_.Pattern }) }

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-GuestSecurityFact -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { ($ArgumentList[2] -join '|') -ceq ($patterns -join '|') -and $ArgumentList.Count -eq 4 }
    }
}

Describe 'Publish-GuestSecurityFinding' {
    BeforeEach { Mock -ModuleName $module Invoke-GuestScript { } }

    It 'writes the file through the guest session, with the stamp of the scan it is to open for' {
        $vm = New-TestVM -Root (New-TestRoot)

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Publish-GuestSecurityFinding -VM $VM -Text 'the findings' -AlertScanId '20261102-024000' }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'the findings' -and $ArgumentList[1] -eq 'LazyVM Findings.txt' -and $ArgumentList[2] -eq 'HKLM:\SOFTWARE\LazyVM' -and
            $ArgumentList[3] -eq 'SecurityFindingsAlert' -and $ArgumentList[4] -eq '20261102-024000'
        }
    }

    It 'never clears the stamp, so a file not opened yet still opens after a scan that found nothing new' {
        $guest = InModuleScope $module { (Get-Command Publish-GuestSecurityFinding).ScriptBlock.ToString() }

        $guest | Should -Not -Match 'Remove-ItemProperty'
    }
}

Describe 'Install-GuestSecurityFindingOpener' {
    It 'registers the task at sign-in, connect and unlock, with the opener as its command' {
        Mock -ModuleName $module Invoke-GuestScript { }
        $vm = New-TestVM -Root (New-TestRoot)
        $argument = InModuleScope $module { Get-SecurityFindingOpenerArgument }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-GuestSecurityFindingOpener -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'LazyVM-SecurityFindings' -and $ArgumentList[1] -eq $argument -and
            "$($ArgumentList[2])" -eq '1 3 8' -and $ArgumentList.Count -eq 3
        }
    }
}

Describe 'Write-SecurityFindingReminder' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Test-Unattended { $false }
    }

    It 'reminds once, in one line, of the open findings' {
        $vm = New-TestVM -Root (New-TestRoot)
        InModuleScope $module -Parameters @{ VM = $vm; Finding = @(New-TestFinding -Severity 'High') } {
            param($VM, $Finding)
            Save-SecurityFindingRecord -VM $VM -ScannedAt ([datetimeoffset]::Now) -Finding $Finding
        }

        $warned = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Write-SecurityFindingReminder -VM $VM 3>&1 })

        $warned.Count | Should -Be 1
        "$($warned[0])" | Should -BeLike '1 security finding(s) on Alpha need attention*Get-LazyVMSecurityFinding -Name Alpha'
    }

    It 'says nothing before the first scan' {
        $warned = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root (New-TestRoot)) } { param($VM) Write-SecurityFindingReminder -VM $VM 3>&1 })

        $warned.Count | Should -Be 0
    }

    It 'is one of the reminders a command run by hand shows first' {
        Mock -ModuleName $module Write-MaintenanceTaskWarning { }
        Mock -ModuleName $module Write-RecoveryKeyReminder { }
        Mock -ModuleName $module Write-SecurityFindingReminder { }

        InModuleScope $module -Parameters @{ VM = (New-TestVM -Root (New-TestRoot)) } { param($VM) Write-RunReminder -VM $VM }

        Should -Invoke -ModuleName $module Write-SecurityFindingReminder -Times 1 -Exactly
    }
}

Describe 'Get-LazyVMSecurityFinding' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-LogEntry { }
        $script:vm = New-TestVM -Root (New-TestRoot)
        Mock -ModuleName $module Initialize-CommandRun { $script:vm }
    }

    It 'lists the last scan''s findings, with the VM''s name' {
        InModuleScope $module -Parameters @{ VM = $script:vm; Finding = @((New-TestFinding), (New-TestFinding -Id 'VBS:Status:NotRunning' -Severity 'Low')) } {
            param($VM, $Finding)
            Save-SecurityFindingRecord -VM $VM -ScannedAt ([datetimeoffset]::Now) -Finding $Finding
        }

        $result = @(Get-LazyVMSecurityFinding -Name Alpha)

        $result.Id | Should -Be @('Firewall:Public:Off', 'VBS:Status:NotRunning')
        $result[0].Name | Should -Be 'Alpha'
        $result[0].PSObject.TypeNames[0] | Should -Be 'LazyVM.SecurityFinding'
        $result[0].FirstSeen | Should -BeOfType [datetimeoffset]
        @($result[0].PSObject.Properties.Name) | Should -Be @('Name', 'Id', 'Severity', 'Title', 'WhatWeFound', 'Where', 'WhyItMatters', 'HowToFix', 'FirstSeen', 'Status')
    }

    It 'says when no scan has run yet, and returns nothing' {
        $result = @(Get-LazyVMSecurityFinding -Name Alpha -WarningVariable warned -WarningAction SilentlyContinue)

        $result.Count | Should -Be 0
        "$warned" | Should -BeLike '*No security scan has run on Alpha yet*'
    }
}

Describe 'The guest collector' {
    BeforeAll {
        # Whatever this test runner has, every Windows command the collector
        # reads through fails here, as in a guest that cannot answer.
        $script:collectorCommands = @('Start-MpScan', 'Get-MpComputerStatus', 'Get-MpThreat', 'Get-MpThreatDetection', 'Get-NetFirewallProfile', 'Get-BitLockerVolume',
            'Get-SmbServerConfiguration', 'Get-LocalUser', 'Get-CimInstance', 'Confirm-SecureBootUEFI', 'Get-WinEvent')
        foreach ($name in $script:collectorCommands) { Set-Item -Path "function:global:$name" -Value { throw 'not available' } }
    }

    AfterAll {
        foreach ($name in $script:collectorCommands) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    It 'reads every area the host checks, in its order, and reports one it cannot read as a note, never failing' {
        $facts = InModuleScope $module { & $script:GuestSecurityScanWork 0 } | ConvertFrom-Json
        $checked = InModuleScope $module { @($script:SecurityCheck.Keys) }

        @($facts.Checks.PSObject.Properties.Name) | Should -Be $checked
        { [datetimeoffset]::Parse($facts.CollectedAt) } | Should -Not -Throw
        @($facts.Notes | Where-Object { $_.Text -like '*quick scan could not run*' }).Count | Should -Be 1
        foreach ($area in 'Defender', 'DefenderDetection', 'Firewall', 'BitLocker', 'SMBv1', 'Account', 'LSA', 'SecureBoot', 'VBS') {
            $facts.Checks.$area | Should -BeNullOrEmpty -Because $area
            @($facts.Notes | Where-Object { $_.Level -eq 'WARN' -and $_.Text -like "*read $area *" }).Count | Should -Be 1 -Because $area
        }
    }

    It 'reads the events the host reviews, and reports only who, what and when, never a script, a command line or a path inside a file (#290)' {
        function global:New-TestEvent {
            param([int]$Id, [datetime]$At, [hashtable]$Data = @{}, [switch]$UserData)
            $fields = ($Data.GetEnumerator() | ForEach-Object { if ($UserData) { "<$($_.Key)>$($_.Value)</$($_.Key)>" } else { "<Data Name='$($_.Key)'>$($_.Value)</Data>" } }) -join ''
            $body = if ($UserData) { "<UserData><LogFileCleared>$fields</LogFileCleared></UserData>" } else { "<EventData>$fields</EventData>" }
            $record = [pscustomobject]@{ Id = $Id; TimeCreated = $At }
            $xml = "<Event>$body</Event>"
            $record | Add-Member -MemberType ScriptMethod -Name ToXml -Value ({ $xml }.GetNewClosure())
            return $record
        }
        $at = [datetime]::UtcNow.AddHours(-1)
        $eventsByLog = @{
            'Security'                                 = @(
                (New-TestEvent -Id 1102 -At $at -Data @{ SubjectUserName = 'intruder' } -UserData)
                (New-TestEvent -Id 4720 -At $at -Data @{ TargetUserName = 'newuser'; SubjectUserName = 'sean' })
                (New-TestEvent -Id 4732 -At $at -Data @{ MemberSid = 'S-1-5-21-1'; MemberName = '-'; TargetSid = 'S-1-5-32-544'; SubjectUserName = 'sean' })
                (New-TestEvent -Id 4732 -At $at -Data @{ MemberSid = 'S-1-5-21-2'; MemberName = '-'; TargetSid = 'S-1-5-32-545'; SubjectUserName = 'sean' })
            )
            'System'                                   = @(
                (New-TestEvent -Id 104 -At $at -Data @{ Channel = 'Application'; SubjectUserName = 'intruder' } -UserData)
                (New-TestEvent -Id 7045 -At $at -Data @{ ServiceName = 'EvilSvc'; ImagePath = 'C:\Tools\evil.exe' })
            )
            'Microsoft-Windows-Sysmon/Operational'     = @(
                (New-TestEvent -Id 10 -At $at -Data @{ SourceImage = 'C:\x\dump.exe'; TargetImage = 'C:\Windows\System32\lsass.exe'; GrantedAccess = '0x1010' })
                (New-TestEvent -Id 1 -At $at -Data @{ Image = 'C:\Users\sean\AppData\Local\Temp\setup.exe'; CommandLine = 'setup.exe --secret hunter2' })
                (New-TestEvent -Id 1 -At $at -Data @{ Image = 'C:\Windows\System32\notepad.exe' })
            )
            'Microsoft-Windows-PowerShell/Operational' = @(
                (New-TestEvent -Id 4104 -At $at -Data @{ ScriptBlockId = 'b1'; ScriptBlockText = '$b = [Convert]::FromBase64String($secret); iex $b' })
                (New-TestEvent -Id 4104 -At $at -Data @{ ScriptBlockId = 'b2'; ScriptBlockText = 'Get-Date' })
            )
        }
        Set-Item -Path 'function:global:Get-WinEvent' -Value ({
                param($FilterHashtable, $MaxEvents)
                $events = @($eventsByLog[$FilterHashtable.LogName] | Where-Object { $_ -and $_.Id -in $FilterHashtable.Id } | Select-Object -First $MaxEvents)
                if ($events.Count -eq 0) { $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('none'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null); throw $e }
                $events
            }.GetNewClosure())
        try {
            $patterns = InModuleScope $module { @($script:SuspiciousPowerShell | ForEach-Object { $_.Pattern }) }

            $json = InModuleScope $module -Parameters @{ Patterns = $patterns } { param($Patterns) & $script:GuestSecurityScanWork 0 '' $Patterns 24 }
            $facts = $json | ConvertFrom-Json

            @($facts.Checks.LogCleared.Events | ForEach-Object { "$($_.Log):$($_.By)" }) | Should -Be @('Security:intruder', 'Application:intruder')
            @($facts.Checks.AccountChange.Events | ForEach-Object { $_.Id }) | Should -Be @(4720, 4732, 7045)
            $facts.Checks.AccountChange.Events[1].Name | Should -Be 'S-1-5-21-1'
            $facts.Checks.AccountChange.Events[2].Path | Should -Be 'C:\Tools\evil.exe'
            @($facts.Checks.Sysmon.Events | ForEach-Object { $_.Id }) | Should -Be @(10, 1)
            $facts.Checks.Sysmon.Events[0].Access | Should -Be '0x1010'
            @($facts.Checks.PowerShellScript.Events).Count | Should -Be 1
            $facts.Checks.PowerShellScript.Events[0].BlockId | Should -Be 'b1'
            @($facts.Checks.PowerShellScript.Events[0].Matched) | Should -Be @(1)
            $json | Should -Not -Match 'hunter2'
            $json | Should -Not -Match 'FromBase64String'
        }
        finally {
            Remove-Item -Path 'function:global:New-TestEvent' -ErrorAction SilentlyContinue
            Set-Item -Path 'function:global:Get-WinEvent' -Value { throw 'not available' }
        }
    }

    It 'counts a failure only for a wrong password or an unknown user, and a success only for the accounts and sources that failed (#290)' {
        function global:New-TestEvent {
            param([int]$Id, [datetime]$At, [hashtable]$Data)
            $fields = ($Data.GetEnumerator() | ForEach-Object { "<Data Name='$($_.Key)'>$($_.Value)</Data>" }) -join ''
            $record = [pscustomobject]@{ Id = $Id; TimeCreated = $At }
            $xml = "<Event><EventData>$fields</EventData></Event>"
            $record | Add-Member -MemberType ScriptMethod -Name ToXml -Value ({ $xml }.GetNewClosure())
            return $record
        }
        $at = [datetime]::UtcNow.AddHours(-1)
        $eventsByLog = @{
            'Security' = @(
                (New-TestEvent -Id 4625 -At $at -Data @{ TargetUserName = 'sean'; IpAddress = '10.0.0.9'; LogonType = 3; SubStatus = '0xC000006A' })
                (New-TestEvent -Id 4625 -At $at -Data @{ TargetUserName = 'sean'; IpAddress = '10.0.0.9'; LogonType = 3; SubStatus = '0xC0000071' })
                (New-TestEvent -Id 4624 -At $at -Data @{ TargetUserName = 'Sean'; IpAddress = '10.0.0.9'; LogonType = 3 })
                (New-TestEvent -Id 4624 -At $at -Data @{ TargetUserName = 'sean'; IpAddress = '10.0.0.9'; LogonType = 5 })
                (New-TestEvent -Id 4624 -At $at -Data @{ TargetUserName = 'other'; IpAddress = '10.0.0.9'; LogonType = 3 })
                (New-TestEvent -Id 4624 -At $at -Data @{ TargetUserName = 'sean'; IpAddress = '10.0.0.77'; LogonType = 3 })
            )
        }
        Set-Item -Path 'function:global:Get-WinEvent' -Value ({
                param($FilterHashtable, $MaxEvents)
                $events = @($eventsByLog[$FilterHashtable.LogName] | Where-Object { $_ -and $_.Id -in $FilterHashtable.Id } | Select-Object -First $MaxEvents)
                if ($events.Count -eq 0) { $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('none'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null); throw $e }
                $events
            }.GetNewClosure())
        try {
            $facts = InModuleScope $module { & $script:GuestSecurityScanWork 0 } | ConvertFrom-Json

            @($facts.Checks.SignIn.Events | ForEach-Object { "$($_.Id):$($_.Account):$($_.Source)" }) | Should -Be @('4625:sean:10.0.0.9', '4624:Sean:10.0.0.9')
        }
        finally {
            Remove-Item -Path 'function:global:New-TestEvent' -ErrorAction SilentlyContinue
            Set-Item -Path 'function:global:Get-WinEvent' -Value { throw 'not available' }
        }
    }

    It 'gives Get-WinEvent the window in the guest''s local time, as Windows PowerShell 5.1 reads it whatever the time''s kind (#344)' {
        $calls = [System.Collections.Generic.List[hashtable]]::new()
        Set-Item -Path 'function:global:Get-WinEvent' -Value ({
                param($FilterHashtable, $MaxEvents)
                $calls.Add(@{ Filter = $FilterHashtable; MaxEvents = $MaxEvents })
                $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('none'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null)
                throw $e
            }.GetNewClosure())
        try {
            $null = InModuleScope $module { & $script:GuestSecurityScanWork 0 '2026-11-06T22:10:00.0000000Z' }

            $calls.Count | Should -BeGreaterThan 0
            foreach ($call in $calls) {
                $call.Filter.StartTime.Kind | Should -Be 'Local'
                $call.Filter.EndTime.Kind | Should -Be 'Local'
                $call.Filter.StartTime.ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 6, 22, 10, 0, [DateTimeKind]::Utc))
            }
        }
        finally { Set-Item -Path 'function:global:Get-WinEvent' -Value { throw 'not available' } }
    }

    It 'logs one line for the script blocks that took too long to test, with how many (#344)' {
        $xml = "<Event><EventData><Data Name='ScriptBlockId'>b1</Data><Data Name='ScriptBlockText'>$('a' * 40)!</Data></EventData></Event>"
        $blocks = foreach ($i in 1..2) {
            $block = [pscustomobject]@{ Id = 4104; TimeCreated = [datetime]::UtcNow.AddMinutes(-5) }
            $block | Add-Member -MemberType ScriptMethod -Name ToXml -Value ({ $xml }.GetNewClosure())
            $block
        }
        Set-Item -Path 'function:global:Get-WinEvent' -Value ({
                param($FilterHashtable, $MaxEvents)
                if ($FilterHashtable.LogName -eq 'Microsoft-Windows-PowerShell/Operational') { return @($blocks | Select-Object -First $MaxEvents) }
                $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('none'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null)
                throw $e
            }.GetNewClosure())
        try {
            # A pattern that backtracks without end on that text, so each block times out.
            $facts = InModuleScope $module { & $script:GuestSecurityScanWork 0 '' @('^(a+)+$') 24 } | ConvertFrom-Json

            $skipped = @($facts.Notes | Where-Object { $_.Text -like '*took too long to test*' })
            $skipped.Count | Should -Be 1
            $skipped[0].Text | Should -BeLike '*2 script blocks*'
        }
        finally { Set-Item -Path 'function:global:Get-WinEvent' -Value { throw 'not available' } }
    }

    It 'reads no events, and no failure, from a log that is not there, such as Sysmon''s before it is installed (#290)' {
        Set-Item -Path 'function:global:Get-WinEvent' -Value {
            $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('no log'), 'NoMatchingLogsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null)
            throw $e
        }
        try {
            $facts = InModuleScope $module { & $script:GuestSecurityScanWork 0 } | ConvertFrom-Json

            @($facts.Checks.Sysmon.Events).Count | Should -Be 0
            @($facts.Checks.PowerShellScript.Events).Count | Should -Be 0
            @($facts.Notes | Where-Object { $_.Level -eq 'WARN' -and $_.Text -like '*read Sysmon *' }).Count | Should -Be 0
        }
        finally { Set-Item -Path 'function:global:Get-WinEvent' -Value { throw 'not available' } }
    }

    It 'reports the new crash files by folder and name, and does not follow a link out of the folder (#290)' {
        $windows = Join-Path $TestDrive 'Windows'
        $dump = New-Item -ItemType Directory -Path (Join-Path $windows 'Minidump') -Force
        Set-Content -LiteralPath (Join-Path $dump 'new.dmp') -Value 'x'
        $old = Join-Path $dump 'old.dmp'
        Set-Content -LiteralPath $old -Value 'x'
        (Get-Item -LiteralPath $old).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-30)
        $outside = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Outside') -Force
        Set-Content -LiteralPath (Join-Path $outside 'secret.dmp') -Value 'x'
        New-Item -ItemType Junction -Path (Join-Path $dump 'link') -Target $outside -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $dump 'link'))) { New-Item -ItemType SymbolicLink -Path (Join-Path $dump 'link') -Target $outside | Out-Null }
        $facts = InModuleScope $module -Parameters @{ Windows = $windows; Data = (Join-Path $TestDrive 'ProgramData') } { param($Windows, $Data) & $script:GuestSecurityScanWork 0 '' @() 24 $Windows $Data } | ConvertFrom-Json

        @($facts.Checks.CrashDump.Items | ForEach-Object { "$($_.Folder):$($_.Name)" }) | Should -Be @('Minidump:new.dmp')
    }

    It 'reads the firewall profiles from the active store' {
        Set-Item -Path 'function:global:Get-NetFirewallProfile' -Value { param($PolicyStore) if ($PolicyStore -ne 'ActiveStore') { throw 'wrong store' }; [pscustomobject]@{ Name = 'Public'; Enabled = 'False'; DefaultInboundAction = 'Block' } }

        $facts = InModuleScope $module { & $script:GuestSecurityScanWork 0 } | ConvertFrom-Json

        $facts.Checks.Firewall.Profiles[0].Name | Should -Be 'Public'
        $facts.Checks.Firewall.Profiles[0].Enabled | Should -BeFalse
    }
}

Describe 'The sign-in opener' {
    BeforeAll {
        $argument = InModuleScope $module { Get-SecurityFindingOpenerArgument }
        $command = [regex]::Match($argument, '-Command "(.*)"$').Groups[1].Value
    }

    BeforeEach {
        Mock Start-Process { }
        Mock Set-ItemProperty { }
        Mock New-Item { }
        Mock Test-Path { $true }
    }

    It 'is the task''s plain -Command, one line with no double quotes, so no file holds it and nothing is encoded' {
        $argument | Should -Not -BeLike '*-EncodedCommand*'
        $argument | Should -Not -Match ' -File '
        $command | Should -Not -BeNullOrEmpty
        $command | Should -Not -Match "[`"`r`n]"
        $command | Should -BeLike "*GetFolderPath('System')*'notepad.exe'*"
    }

    It 'opens the file in Notepad, by its full path, and records it, when a scan asked for it and it was not opened for that scan' {
        Mock Get-ItemPropertyValue { if ("$Path" -like 'HKLM:*') { '20261102-024000' } else { '20261101-024000' } }

        & ([scriptblock]::Create($command))

        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'SecurityFindingsOpened' -and $Value -eq '20261102-024000' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq [IO.Path]::Combine([Environment]::GetFolderPath('System'), 'notepad.exe') -and "$ArgumentList" -like '"*LazyVM Findings.txt"' }
    }

    It 'leaves it closed when <Case>' -ForEach @(
        @{ Case = 'it was opened for that scan already'; Alert = '20261102-024000'; Opened = '20261102-024000' }
        @{ Case = 'no scan asked for it'; Alert = $null; Opened = '20261101-024000' }
    ) {
        Mock Get-ItemPropertyValue { if ("$Path" -like 'HKLM:*') { $Alert } else { $Opened } }

        & ([scriptblock]::Create($command))

        Should -Invoke Start-Process -Times 0
        Should -Invoke Set-ItemProperty -Times 0
    }

    It 'reads a value that is not set yet, or its key, as none, under StrictMode too' {
        Mock Get-ItemPropertyValue { Write-Error 'Property SecurityFindingsAlert does not exist' }

        { Set-StrictMode -Version 3.0; & ([scriptblock]::Create($command)) } | Should -Not -Throw

        Should -Invoke Start-Process -Times 0
    }

    It 'reads the names the scan writes' {
        $names = InModuleScope $module { @($script:GuestMarkerKey, $script:GuestSecurityAlertValueName, $script:GuestSecurityFindingsFileName) }

        foreach ($name in $names) { $command | Should -BeLike "*'$name'*" }
    }
}

Describe 'The GuestSecurityScan setting' {
    It 'is on unless a VM turns it off' {
        $schema = InModuleScope $module { Get-SettingsSchema }

        $schema.properties['GuestSecurityScan']['type'] | Should -Be 'boolean'
        $schema.properties['GuestSecurityScan']['default'] | Should -BeTrue
    }

    It 'is on in the <Template> template' -ForEach @(@{ Template = 'Developer' }, @{ Template = 'PlainWindows' }) {
        $template = Get-Content -LiteralPath (Join-Path -Path $script:LazyVMModuleDir -ChildPath "Data\Templates\$Template.json") -Raw | ConvertFrom-Json

        $template.Settings.GuestSecurityScan | Should -BeTrue
    }
}
