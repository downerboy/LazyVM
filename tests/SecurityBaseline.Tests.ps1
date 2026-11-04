# SecurityBaseline.Tests.ps1
# The nightly security scan, part 2 (#290): the persistence checks against
# the known-good baseline recorded after the build, the approvals kept in
# <VM>\Config\SecurityBaseline.json, the commands that approve, revoke and
# list them, and the setting that says which severities alert. The guest is
# mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $recordedAt = [datetimeoffset]::new(2026, 11, 1, 2, 40, 0, [timespan]::FromHours(-8))
    $everySeverity = @('High', 'Medium', 'Low', 'Info')

    function New-PersistenceFact {
        <# What the persistence collector reports for a guest with one item in each area, as the host reads it back from JSON. #>
        $items = [ordered]@{
            ScheduledTask   = @(@{ Name = '\Microsoft\Windows\Defrag\ScheduledDefrag'; Fingerprint = 'aaaaaaaaaaaa'; Program = 'C:\Windows\system32\defrag.exe'; InUserFolder = $false })
            Service         = @(@{ Name = 'MySvc'; Fingerprint = 'bbbbbbbbbbbb'; Program = 'C:\Tools\svc.exe'; InUserFolder = $false })
            RunKey          = @(@{ Name = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\SecurityHealth'; Fingerprint = 'cccccccccccc'; Program = 'C:\Windows\system32\SecurityHealthSystray.exe'; InUserFolder = $false })
            StartupFolder   = @()
            WmiSubscription = @(@{ Name = 'SCM Event Log Filter to NTEventLogEventConsumer.SCM Event Log Consumer'; Fingerprint = 'dddddddddddd'; Program = ''; InUserFolder = $false })
            LocalUser       = @(@{ Name = 'dev'; Fingerprint = 'eeeeeeeeeeee'; Program = ''; InUserFolder = $false })
            Administrators  = @(@{ Name = 'DEVBOX\dev'; Fingerprint = 'ffffffffffff'; Program = ''; InUserFolder = $false })
        }
        return (ConvertTo-Json -InputObject $items -Depth 6 | ConvertFrom-Json -DateKind String)
    }

    function New-TestBaseline {
        <# The baseline of $Item, recorded at $recordedAt. #>
        param([Parameter(Mandatory)][object]$Item)
        return InModuleScope $module -Parameters @{ Item = $Item; RecordedAt = $recordedAt } { param($Item, $RecordedAt) New-PersistenceBaseline -Item $Item -RecordedAt $RecordedAt }
    }

    function ConvertTo-TestPersistenceFinding {
        param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline)
        return @(InModuleScope $module -Parameters @{ Item = $Item; Baseline = $Baseline } { param($Item, $Baseline) ConvertTo-PersistenceFinding -Item $Item -Baseline $Baseline })
    }

    function New-TestVM {
        <# The context of VM Alpha under $Root, with the scan on unless $Off. #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$Off,
            [string[]]$AlertSeverity = $everySeverity
        )

        $settings = @{
            VMName                         = 'Alpha'
            Root                           = $Root
            GuestAdminUser                 = 'dev'
            GuestSecurityScan              = -not $Off
            GuestSecurityScanAlertSeverity = $AlertSeverity
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

    function New-TestFinding {
        <# A finding as the scan keeps it. #>
        param(
            [string]$Id = 'Firewall:Public:Off',
            [string]$Severity = 'High',
            [string]$Status = 'New'
        )

        $record = @{ Id = $Id; Severity = $Severity; Title = "Title of $Id"; WhatWeFound = 'found C:\secret\path'; Where = @(); WhyItMatters = 'why'; HowToFix = 'fix'; FirstSeen = '2026-11-01T02:40:00.0000000-08:00'; Status = $Status }
        return InModuleScope $module -Parameters @{ Record = $record } { param($Record) [SecurityFinding]::FromObject($Record) }
    }

    function Save-TestFindingRecord {
        <# Keeps $Finding as the VM's last scan. #>
        param([Parameter(Mandatory)][object]$VM, [object[]]$Finding = @())
        InModuleScope $module -Parameters @{ VM = $VM; Finding = $Finding } {
            param($VM, $Finding)
            Save-SecurityFindingRecord -VM $VM -ScannedAt ([datetimeoffset]::Now) -Finding $Finding
        }
    }

    function Read-TestBaselineFile {
        param([Parameter(Mandatory)][object]$VM)
        return (Get-Content -LiteralPath $VM.Settings.SecurityBaselineFile -Raw | ConvertFrom-Json -DateKind String)
    }
}

Describe 'ConvertTo-PersistenceFinding' {
    It 'finds nothing when every item is in the baseline' {
        $facts = New-PersistenceFact

        @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline (New-TestBaseline -Item $facts)).Count | Should -Be 0
    }

    It 'reports an item that was not there when the baseline was recorded, by an Id made from its area, name and fingerprint' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.ScheduledTask += [pscustomobject]@{ Name = '\Updater'; Fingerprint = '123456789abc'; Program = 'C:\Tools\updater.exe'; InUserFolder = $false }

        $found = @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline)

        $found.Id | Should -Be @('ScheduledTask:\Updater:123456789abc')
        $found[0].Severity | Should -Be 'Medium'
        $found[0].Title | Should -Be 'New scheduled task: \Updater'
        $found[0].WhatWeFound | Should -BeLike '*\Updater was not there when LazyVM recorded the baseline*'
        $found[0].Where | Should -Be @('C:\Tools\updater.exe')
        $found[0].HowToFix | Should -BeLike '*Approve-LazyVMSecurityFinding*'
        $found[0].WhyItMatters | Should -Not -BeNullOrEmpty
    }

    It 'reports a service whose binary path changed as changed, with a new Id' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.Service[0].Fingerprint = '999999999999'
        $facts.Service[0].Program = 'C:\Users\dev\AppData\Local\Temp\svc.exe'
        $facts.Service[0].InUserFolder = $true

        $found = @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline)

        $found.Id | Should -Be @('Service:MySvc:999999999999')
        $found[0].Title | Should -Be 'Changed service: MySvc'
        $found[0].WhatWeFound | Should -BeLike '*MySvc changed since LazyVM recorded the baseline*folder*users can write*'
        $found[0].Severity | Should -Be 'High'
    }

    It 'rates a new <Area> item <Severity>' -ForEach @(
        @{ Area = 'WmiSubscription'; Severity = 'High' }
        @{ Area = 'Administrators'; Severity = 'High' }
        @{ Area = 'LocalUser'; Severity = 'Medium' }
        @{ Area = 'RunKey'; Severity = 'Medium' }
        @{ Area = 'StartupFolder'; Severity = 'Medium' }
    ) {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.$Area = @([pscustomobject]@{ Name = 'Added'; Fingerprint = '0123456789ab'; Program = ''; InUserFolder = $false })

        $found = @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline)

        $found.Id | Should -Be @("${Area}:Added:0123456789ab")
        $found[0].Severity | Should -Be $Severity
        $found[0].Where.Count | Should -Be 0
    }

    It 'does not report what was removed, which cannot start anything' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.Service = @()

        @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline).Count | Should -Be 0
    }

    It 'leaves out an area the guest could not read, or that has no baseline yet' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $baseline.Remove('RunKey')
        $facts = New-PersistenceFact
        $facts.Service = $null
        $facts.RunKey += [pscustomobject]@{ Name = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\x'; Fingerprint = '0123456789ab'; Program = ''; InUserFolder = $false }

        @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline).Count | Should -Be 0
    }
}

Describe 'New-PersistenceBaseline' {
    It 'records the Ids of each area the guest read, sorted, and leaves out one it could not' {
        $facts = New-PersistenceFact
        $facts.Service = $null
        $facts.LocalUser += [pscustomobject]@{ Name = 'admin'; Fingerprint = '000000000000'; Program = ''; InUserFolder = $false }

        $baseline = New-TestBaseline -Item $facts

        @($baseline.Keys) | Should -Be @('ScheduledTask', 'RunKey', 'StartupFolder', 'WmiSubscription', 'LocalUser', 'Administrators')
        $baseline.LocalUser.Items | Should -Be @('LocalUser:admin:000000000000', 'LocalUser:dev:eeeeeeeeeeee')
        $baseline.StartupFolder.Items.Count | Should -Be 0
        $baseline.ScheduledTask.RecordedAt | Should -Be $recordedAt
    }

    It 'records only the areas asked for' {
        $baseline = InModuleScope $module -Parameters @{ Item = (New-PersistenceFact); RecordedAt = $recordedAt } {
            param($Item, $RecordedAt) New-PersistenceBaseline -Item $Item -RecordedAt $RecordedAt -Area 'Service'
        }

        @($baseline.Keys) | Should -Be @('Service')
    }
}

Describe 'The persistence areas' {
    It 'each say what they are, why they matter and how to fix them' {
        $areas = InModuleScope $module { $script:PersistenceCheck }

        foreach ($area in $areas.Keys) {
            foreach ($field in 'Thing', 'Things', 'Severity', 'Why', 'Fix') { $areas[$area][$field] | Should -Not -BeNullOrEmpty -Because "$area $field" }
        }
    }
}

Describe 'The persistence collector' {
    BeforeAll {
        # Whatever this test runner has, every Windows command the collector
        # reads through fails here, as in a guest that cannot answer.
        $script:collectorCommands = @('Get-ScheduledTask', 'Get-CimInstance', 'Get-LocalUser', 'Get-LocalGroupMember')
        foreach ($name in $script:collectorCommands) { Set-Item -Path "function:global:$name" -Value { throw 'not available' } }

        function Invoke-TestCollector {
            return (InModuleScope $module { & $script:GuestPersistenceWork 'LazyVM-persistence-scan' 'dev' } | ConvertFrom-Json)
        }

        function New-TestServiceKey {
            <# A service's registry key, as Get-ChildItem gives it. #>
            param([string]$Name, [int]$Type, [string]$ImagePath, [string]$ObjectName = 'LocalSystem')
            $values = @{ Type = $Type; ImagePath = $ImagePath; ObjectName = $ObjectName }
            $key = [pscustomobject]@{ PSChildName = $Name; Values = $values }
            # GetValue(name, default, options), as RegistryKey has it.
            $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value { if ($this.Values.ContainsKey($args[0])) { $this.Values[$args[0]] } else { $args[1] } }
            # No Parameters subkey, so no ServiceDll.
            $key | Add-Member -MemberType ScriptMethod -Name OpenSubKey -Value { $null }
            return $key
        }
    }

    AfterAll {
        foreach ($name in $script:collectorCommands) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    It 'reads every area the host checks, in its order, and reports one it cannot read as a note, never failing' {
        # The services, from the registry, fail too, as on a Windows runner they would not.
        Mock -ModuleName $module Get-ChildItem -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' } { throw 'not available' }

        $facts = Invoke-TestCollector
        $areas = InModuleScope $module { @($script:PersistenceCheck.Keys) }

        @($facts.Items.PSObject.Properties.Name) | Should -Be $areas
        foreach ($area in $areas) {
            $facts.Items.$area | Should -BeNullOrEmpty -Because $area
            @($facts.Notes | Where-Object { $_.Level -eq 'WARN' -and $_.Text -like "*read $area *" }).Count | Should -Be 1 -Because $area
        }
    }

    It 'gives a task a fingerprint that changes with what it runs, never the command line itself, and leaves itself out' {
        $script:arguments = '-password Secret123'
        Set-Item -Path 'function:global:Get-ScheduledTask' -Value {
            @(
                [pscustomobject]@{ TaskPath = '\'; TaskName = 'Updater'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = ''; RunLevel = 'Highest' }; Actions = @([pscustomobject]@{ Execute = '"C:\Tools\updater.exe"'; Arguments = $script:arguments; WorkingDirectory = '' }) }
                [pscustomobject]@{ TaskPath = '\'; TaskName = 'LazyVM-persistence-scan'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = ''; RunLevel = 'Highest' }; Actions = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = ''; WorkingDirectory = '' }) }
            )
        }

        $first = Invoke-TestCollector
        $script:arguments = '-password Other456'
        $second = Invoke-TestCollector

        @($first.Items.ScheduledTask).Count | Should -Be 1
        $first.Items.ScheduledTask[0].Name | Should -Be '\Updater'
        $first.Items.ScheduledTask[0].Program | Should -Be 'C:\Tools\updater.exe'
        $first.Items.ScheduledTask[0].Fingerprint | Should -Match '^[0-9a-f]{12}$'
        $second.Items.ScheduledTask[0].Fingerprint | Should -Not -Be $first.Items.ScheduledTask[0].Fingerprint
        (ConvertTo-Json -InputObject $first -Depth 6) | Should -Not -BeLike '*Secret123*'
    }

    It 'gives a service a fingerprint that changes with its binary path, but not with a version number in a folder name' {
        $script:image = 'C:\Tools\svc.exe'
        Mock -ModuleName $module Get-ChildItem -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' } {
            @(
                New-TestServiceKey -Name 'MySvc' -Type 16 -ImagePath $script:image
                New-TestServiceKey -Name 'Disk' -Type 1 -ImagePath 'System32\drivers\disk.sys'
                New-TestServiceKey -Name 'CDPUserSvc_4f8e2' -Type 224 -ImagePath 'C:\Windows\system32\svchost.exe -k UnistackSvcGroup'
            )
        }

        $fingerprint = {
            $facts = Invoke-TestCollector
            @($facts.Items.Service).Name | Should -Be @('MySvc')
            $facts.Items.Service[0].Fingerprint
        }
        $first = & $fingerprint
        $script:image = 'C:\Tools\other.exe'
        $moved = & $fingerprint
        $script:image = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.25010.11-0\MsMpEng.exe'
        $oldVersion = & $fingerprint
        $script:image = 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.25020.1009-0\MsMpEng.exe'
        $newVersion = & $fingerprint

        $moved | Should -Not -Be $first
        $newVersion | Should -Be $oldVersion
    }
}

Describe 'Invoke-GuestSecurityScan with the persistence baseline and approvals' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        Mock -ModuleName $module Publish-GuestSecurityFinding { }
        $script:settingsCheck = [pscustomobject]@{ SMBv1 = [pscustomobject]@{ Enabled = $false } }
        $script:collectedAt = '2026-11-02T10:40:00.0000000Z'
        Mock -ModuleName $module Get-GuestSecurityFact { [pscustomobject]@{ CollectedAt = $script:collectedAt; Checks = $script:settingsCheck } }
        $script:persistence = New-PersistenceFact
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = $script:persistence } }
        $script:vm = New-TestVM -Root (New-TestRoot)

        function Invoke-TestScan {
            param([string]$At)
            if ($At) { $script:collectedAt = $At }
            InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }
        }

        function Get-KeptFinding {
            return @((Get-Content -LiteralPath $script:vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json).Findings)
        }

        function Add-TestTask {
            param([string]$Name = '\Updater', [string]$Fingerprint = '123456789abc')
            $script:persistence.ScheduledTask += [pscustomobject]@{ Name = $Name; Fingerprint = $Fingerprint; Program = 'C:\Tools\updater.exe'; InUserFolder = $false }
        }
    }

    It 'records the baseline of every area at the first scan of a VM that has none, reporting nothing, then reports what is added' {
        Invoke-TestScan

        $baseline = Read-TestBaselineFile -VM $script:vm
        @($baseline.Persistence.PSObject.Properties.Name) | Should -Be @('ScheduledTask', 'Service', 'RunKey', 'StartupFolder', 'WmiSubscription', 'LocalUser', 'Administrators')
        @(Get-KeptFinding).Count | Should -Be 0
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*recorded the baseline of scheduled tasks*' }

        Add-TestTask
        Invoke-TestScan -At '2026-11-03T10:40:00.0000000Z'

        $kept = @(Get-KeptFinding)
        $kept.Id | Should -Be @('ScheduledTask:\Updater:123456789abc')
        $kept[0].Status | Should -Be 'New'
        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 1 -Exactly -ParameterFilter { $AlertScanId -and $Text -like '*New scheduled task: \Updater*' }
    }

    It 'records an area the guest could not read at the first scan the next time it can' {
        $script:persistence.Service = $null
        Invoke-TestScan
        @((Read-TestBaselineFile -VM $script:vm).Persistence.PSObject.Properties.Name) | Should -Not -Contain 'Service'

        $script:persistence = New-PersistenceFact
        Invoke-TestScan -At '2026-11-03T10:40:00.0000000Z'

        @((Read-TestBaselineFile -VM $script:vm).Persistence.Service.Items) | Should -Be @('Service:MySvc:bbbbbbbbbbbb')
        @(Get-KeptFinding).Count | Should -Be 0
    }

    It 'keeps the persistence findings open, and still reports the settings, when the persistence check fails' {
        Invoke-TestScan
        Add-TestTask
        Invoke-TestScan -At '2026-11-03T10:40:00.0000000Z'
        Mock -ModuleName $module Get-GuestPersistenceFact { throw 'the task timed out' }
        $script:settingsCheck.SMBv1.Enabled = $true

        { Invoke-TestScan -At '2026-11-04T10:40:00.0000000Z' } | Should -Not -Throw

        $kept = @(Get-KeptFinding)
        ($kept | Where-Object Id -eq 'ScheduledTask:\Updater:123456789abc').Status | Should -Be 'Still open'
        ($kept | Where-Object Id -eq 'SMBv1:Server:On').Status | Should -Be 'New'
        Should -Invoke -ModuleName $module Write-LogError -ParameterFilter { $Context -like '*(non-fatal)*' }
    }

    Context 'approvals' {
        BeforeEach {
            Invoke-TestScan
            Add-TestTask
            Invoke-TestScan -At '2026-11-03T10:40:00.0000000Z'
            InModuleScope $module -Parameters @{ VM = $script:vm; Finding = @(Get-KeptFinding)[0] } {
                param($VM, $Finding)
                Add-SecurityApproval -VM $VM -Finding ([SecurityFinding]::FromObject($Finding)) -Reason 'my updater'
            }
        }

        It 'does not report an approved finding, does not call it resolved, and says how many it left out' {
            Invoke-TestScan -At '2026-11-04T10:40:00.0000000Z'

            @(Get-KeptFinding).Count | Should -Be 0
            Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*1 approved finding*Get-LazyVMSecurityFinding -Name Alpha -Approved*' }
            @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('ScheduledTask:\Updater:123456789abc')
        }

        It 'reports the item again, as new, once it changes, and ends the approval' {
            $script:persistence.ScheduledTask[-1].Fingerprint = 'cba987654321'

            Invoke-TestScan -At '2026-11-04T10:40:00.0000000Z'

            $kept = @(Get-KeptFinding)
            $kept.Id | Should -Be @('ScheduledTask:\Updater:cba987654321')
            $kept[0].Status | Should -Be 'New'
            # Still new against the baseline, which the approval did not change.
            $kept[0].Title | Should -Be 'New scheduled task: \Updater'
            @((Read-TestBaselineFile -VM $script:vm).Approvals).Count | Should -Be 0
            Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*approval of ScheduledTask:\Updater:123456789abc ended*' }
        }

        It 'keeps the approval while the guest cannot read its area' {
            $script:persistence.ScheduledTask = $null

            Invoke-TestScan -At '2026-11-04T10:40:00.0000000Z'

            @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('ScheduledTask:\Updater:123456789abc')
        }
    }
}

Describe 'The alert severity setting (GuestSecurityScanAlertSeverity)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        Mock -ModuleName $module Publish-GuestSecurityFinding { }
        # A guest whose only finding is VBS not running: Low.
        Mock -ModuleName $module Get-GuestSecurityFact { [pscustomobject]@{ CollectedAt = '2026-11-02T10:40:00Z'; Checks = [pscustomobject]@{ VBS = [pscustomobject]@{ Running = $false } } } }
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = $null } }
    }

    It 'opens the findings file for a new Low finding by default' {
        $vm = New-TestVM -Root (New-TestRoot)

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 1 -Exactly -ParameterFilter { $AlertScanId -match '^\d{8}-\d{6}$' }
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*Id: VBS:Status:NotRunning*' -and $Level -eq 'WARN' }
    }

    It 'still logs it and writes it to the file, without opening it, when only High and Medium alert' {
        $vm = New-TestVM -Root (New-TestRoot) -AlertSeverity 'High', 'Medium'

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        Should -Invoke -ModuleName $module Publish-GuestSecurityFinding -Times 1 -Exactly -ParameterFilter { $AlertScanId -eq '' -and $Text -like '*Id: VBS:Status:NotRunning*' }
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*Id: VBS:Status:NotRunning*' -and $Level -eq 'INFO' }
    }

    It 'reminds on the host of open findings of the severities that alert' {
        $findings = @((New-TestFinding -Severity 'High'), (New-TestFinding -Id 'VBS:Status:NotRunning' -Severity 'Low'), (New-TestFinding -Id 'AutoLogon:Winlogon:On' -Severity 'Info'))

        $all = InModuleScope $module -Parameters @{ Finding = $findings; Severity = $everySeverity } { param($Finding, $Severity) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -Severity $Severity }
        $highOnly = InModuleScope $module -Parameters @{ Finding = $findings } { param($Finding) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -Severity 'High' }
        $none = InModuleScope $module -Parameters @{ Finding = $findings } { param($Finding) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -Severity 'Medium' }

        $all | Should -Be '3 security finding(s) on Alpha need attention (1 High, 1 Low, 1 Info). See them with: Get-LazyVMSecurityFinding -Name Alpha'
        $highOnly | Should -Be '1 security finding(s) on Alpha need attention (1 High). See them with: Get-LazyVMSecurityFinding -Name Alpha'
        $none | Should -BeNullOrEmpty
    }

    It 'is a list of severities, every one of them by default' {
        $schema = InModuleScope $module { Get-SettingsSchema }
        $setting = $schema.properties['GuestSecurityScanAlertSeverity']

        $setting['type'] | Should -Be 'array'
        @($setting['default']) | Should -Be $everySeverity
        @($setting['items']['enum']) | Should -Be $everySeverity
    }

    It 'is left to the VM, not set by the <Template> template' -ForEach @(@{ Template = 'Developer' }, @{ Template = 'PlainWindows' }) {
        $template = Get-Content -LiteralPath (Join-Path -Path $script:LazyVMModuleDir -ChildPath "Data\Templates\$Template.json") -Raw | ConvertFrom-Json

        $template.Settings.PSObject.Properties.Name | Should -Not -Contain 'GuestSecurityScanAlertSeverity'
    }
}

Describe 'Approve-LazyVMSecurityFinding' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        $script:vm = New-TestVM -Root (New-TestRoot)
        Mock -ModuleName $module Initialize-CommandRun { $script:vm }
        Save-TestFindingRecord -VM $script:vm -Finding @(
            New-TestFinding -Id 'Service:MySvc:999999999999' -Severity 'Medium'
            New-TestFinding -Id 'AutoLogon:Winlogon:On' -Severity 'Info' -Status 'Still open'
            New-TestFinding -Id 'SMBv1:Server:On' -Status 'Resolved'
        )
    }

    It 'records the approval in Config\SecurityBaseline.json with the date and reason, and nothing of what was found' {
        $before = [datetimeoffset]::Now

        Approve-LazyVMSecurityFinding -Name Alpha -Id 'Service:MySvc:999999999999' -Reason 'my own service'

        $approval = @((Read-TestBaselineFile -VM $script:vm).Approvals)
        $approval.Count | Should -Be 1
        $approval[0].Id | Should -Be 'Service:MySvc:999999999999'
        $approval[0].Severity | Should -Be 'Medium'
        $approval[0].Title | Should -Be 'Title of Service:MySvc:999999999999'
        $approval[0].Reason | Should -Be 'my own service'
        [datetimeoffset]::Parse($approval[0].ApprovedOn) | Should -BeGreaterOrEqual $before.AddSeconds(-1)
        Get-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Raw | Should -Not -BeLike '*secret*'
    }

    It 'takes the findings from the pipeline, by their Name and Id' {
        Get-LazyVMSecurityFinding -Name Alpha | Where-Object Status -ne 'Resolved' | Approve-LazyVMSecurityFinding

        @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('Service:MySvc:999999999999', 'AutoLogon:Winlogon:On')
    }

    It 'leaves an approved finding out of Get-LazyVMSecurityFinding and the reminder' {
        Mock -ModuleName $module Test-Unattended { $false }
        Approve-LazyVMSecurityFinding -Name Alpha -Id 'Service:MySvc:999999999999'

        @(Get-LazyVMSecurityFinding -Name Alpha).Id | Should -Be @('AutoLogon:Winlogon:On', 'SMBv1:Server:On')
        $warned = @(InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Write-SecurityFindingReminder -VM $VM 3>&1 })
        "$($warned[0])" | Should -BeLike '1 security finding(s) on Alpha need attention (1 Info)*'
    }

    It 'writes nothing with -WhatIf' {
        Approve-LazyVMSecurityFinding -Name Alpha -Id 'Service:MySvc:999999999999' -WhatIf

        $script:vm.Settings.SecurityBaselineFile | Should -Not -Exist
    }

    It 'refuses <Case>, before asking, even with -WhatIf' -ForEach @(
        @{ Case = 'an Id the last scan did not find'; Id = 'Service:Other:000000000000'; Message = '*has no finding with the Id Service:Other:000000000000*' }
        @{ Case = 'a resolved finding'; Id = 'SMBv1:Server:On'; Message = '*is resolved*' }
    ) {
        { Approve-LazyVMSecurityFinding -Name Alpha -Id $Id -WhatIf } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses a finding that is already approved' {
        Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On'

        { Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On' } | Should -Throw -ExpectedMessage '*already approved*'
    }

    It 'refuses when no scan has run yet' {
        $script:vm = New-TestVM -Root (New-TestRoot)

        { Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On' } | Should -Throw -ExpectedMessage '*No security scan has run on Alpha yet*'
    }
}

Describe 'Revoke-LazyVMSecurityFinding and Get-LazyVMSecurityFinding -Approved' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        $script:vm = New-TestVM -Root (New-TestRoot)
        Mock -ModuleName $module Initialize-CommandRun { $script:vm }
        Save-TestFindingRecord -VM $script:vm -Finding @((New-TestFinding -Id 'Service:MySvc:999999999999' -Severity 'Medium'), (New-TestFinding -Id 'AutoLogon:Winlogon:On' -Severity 'Info'))
        Approve-LazyVMSecurityFinding -Name Alpha -Id 'Service:MySvc:999999999999' -Reason 'my own service'
        Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On'
    }

    It 'lists the approvals, with the VM''s name' {
        $approved = @(Get-LazyVMSecurityFinding -Name Alpha -Approved)

        $approved.Id | Should -Be @('Service:MySvc:999999999999', 'AutoLogon:Winlogon:On')
        $approved[0].PSObject.TypeNames[0] | Should -Be 'LazyVM.SecurityApproval'
        @($approved[0].PSObject.Properties.Name) | Should -Be @('Name', 'Id', 'Severity', 'Title', 'ApprovedOn', 'Reason')
        $approved[0].Name | Should -Be 'Alpha'
        $approved[0].ApprovedOn | Should -BeOfType [datetimeoffset]
        $approved[0].Reason | Should -Be 'my own service'
    }

    It 'revokes an approval, so the finding is listed again' {
        Revoke-LazyVMSecurityFinding -Name Alpha -Id 'Service:MySvc:999999999999'

        @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('AutoLogon:Winlogon:On')
        @(Get-LazyVMSecurityFinding -Name Alpha).Id | Should -Contain 'Service:MySvc:999999999999'
    }

    It 'revokes the approvals it is given from the pipeline' {
        Get-LazyVMSecurityFinding -Name Alpha -Approved | Revoke-LazyVMSecurityFinding

        @((Read-TestBaselineFile -VM $script:vm).Approvals).Count | Should -Be 0
    }

    It 'changes nothing with -WhatIf' {
        Revoke-LazyVMSecurityFinding -Name Alpha -Id 'Service:MySvc:999999999999' -WhatIf

        @((Read-TestBaselineFile -VM $script:vm).Approvals).Count | Should -Be 2
    }

    It 'refuses an Id that is not approved, before asking' {
        { Revoke-LazyVMSecurityFinding -Name Alpha -Id 'SMBv1:Server:On' -WhatIf } | Should -Throw -ExpectedMessage '*has no approved finding with the Id SMBv1:Server:On*'
    }

    It 'says so when nothing is approved' {
        Get-LazyVMSecurityFinding -Name Alpha -Approved | Revoke-LazyVMSecurityFinding

        @(Get-LazyVMSecurityFinding -Name Alpha -Approved).Count | Should -Be 0
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*No security findings are approved on Alpha*' }
    }
}

Describe 'Save-GuestPersistenceBaseline' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = (New-PersistenceFact) } }
        $script:vm = New-TestVM -Root (New-TestRoot)
    }

    It 'records every area after the build, with the findings opener in place first, keeping the approvals' {
        InModuleScope $module -Parameters @{ VM = $script:vm; Finding = (New-TestFinding -Id 'AutoLogon:Winlogon:On' -Severity 'Info') } {
            param($VM, $Finding)
            Add-SecurityApproval -VM $VM -Finding $Finding -Reason 'by design'
        }

        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }

        $baseline = Read-TestBaselineFile -VM $script:vm
        @($baseline.Persistence.Service.Items) | Should -Be @('Service:MySvc:bbbbbbbbbbbb')
        @($baseline.Approvals).Id | Should -Be @('AutoLogon:Winlogon:On')
        Should -Invoke -ModuleName $module Install-GuestSecurityFindingOpener -Times 1 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like 'Security baseline recorded: scheduled tasks: 1, services: 1, Run key entries: 1, startup folder items: 0,*' -and $Level -eq 'OK' }
    }

    It 'replaces an earlier baseline, such as the old VM''s at a rebuild' {
        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }
        Mock -ModuleName $module Get-GuestPersistenceFact { $facts = New-PersistenceFact; $facts.Service[0].Fingerprint = '111111111111'; [pscustomobject]@{ Items = $facts } }

        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }

        @((Read-TestBaselineFile -VM $script:vm).Persistence.Service.Items) | Should -Be @('Service:MySvc:111111111111')
    }

    It 'leaves the baseline for the next nightly scan to record, without failing, when the guest cannot be read' {
        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }
        Mock -ModuleName $module Get-GuestPersistenceFact { throw 'the guest stopped answering' }

        { InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM } } | Should -Not -Throw

        @((Read-TestBaselineFile -VM $script:vm).Persistence.PSObject.Properties).Count | Should -Be 0
        Should -Invoke -ModuleName $module Write-LogError -ParameterFilter { $Context -like '*(non-fatal)*next nightly scan*' }
    }

    It 'leaves the guest alone when GuestSecurityScan is off' {
        $vm = New-TestVM -Root (New-TestRoot) -Off

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestPersistenceFact -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'turned off in the settings \(GuestSecurityScan\)' }
    }
}
