# SecurityBaseline.Tests.ps1
# The nightly security scan, part 2 (#290, hardened in #334): the persistence checks against
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
    # Approve asks first (ConfirmImpact High); these tests answer for the user.
    $PSDefaultParameterValues['Approve-LazyVMSecurityFinding:Confirm'] = $false

    function New-PersistenceFact {
        <# What the persistence collector reports for a guest with one item in each area, as the host reads it back from JSON. #>
        $items = [ordered]@{
            ScheduledTask   = @(@{ Name = '\Microsoft\Windows\Defrag\ScheduledDefrag'; Fingerprint = 'aaaaaaaaaaaa'; Program = 'C:\Windows\system32\defrag.exe'; InUserFolder = $false })
            Service         = @(@{ Name = 'MySvc'; Fingerprint = 'bbbbbbbbbbbb'; Program = 'C:\Tools\svc.exe'; InUserFolder = $false })
            RunKey          = @(@{ Name = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\SecurityHealth'; Fingerprint = 'cccccccccccc'; Program = 'C:\Windows\system32\SecurityHealthSystray.exe'; InUserFolder = $false })
            UserRunKey      = @()
            StartupFolder   = @()
            UserStartupFolder = @()
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

    function Get-TestBaselineItem {
        <# The items the VM's baseline file knows for $Area, each as '<name>:<fingerprint>'. #>
        param([Parameter(Mandatory)][object]$VM, [Parameter(Mandatory)][string]$Area)
        $recorded = (Read-TestBaselineFile -VM $VM).Persistence.$Area
        return @(@($recorded.Items) | ForEach-Object { $item = $_; @($item.Fingerprints) | ForEach-Object { "$($item.Name):$_" } })
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
        $found[0].WhatWeFound | Should -BeLike '*MySvc changed since LazyVM recorded the baseline*points into a folder users can write to*'
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
        $facts.RunKey += [pscustomobject]@{ Name = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\x'; Fingerprint = '0123456789ab'; Program = ''; InUserFolder = $false }

        @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline).Count | Should -Be 0
    }
}

Describe 'New-PersistenceBaseline' {
    It 'records the fingerprint of each item of each area the guest read, and leaves out an area it could not, and an item it could not fingerprint' {
        $facts = New-PersistenceFact
        $facts.Service = $null
        $facts.LocalUser += [pscustomobject]@{ Name = 'admin'; Fingerprint = '000000000000'; Program = ''; InUserFolder = $false }
        $facts.LocalUser += [pscustomobject]@{ Name = 'hidden'; Fingerprint = 'unreadable'; Program = ''; InUserFolder = $false }

        $baseline = New-TestBaseline -Item $facts

        @($baseline.Keys) | Should -Be @('ScheduledTask', 'RunKey', 'UserRunKey', 'StartupFolder', 'UserStartupFolder', 'WmiSubscription', 'LocalUser', 'Administrators')
        @($baseline.LocalUser.Items.Keys | Sort-Object) | Should -Be @('admin', 'dev')
        $baseline.LocalUser.Items['admin'] | Should -Be @('000000000000')
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

        function New-TestRegistryKey {
            <# A registry key as Get-Item gives it: its values, and its subkeys by name. #>
            param([hashtable]$Value = @{}, [hashtable]$SubKey = @{})
            $key = [pscustomobject]@{ Values = $Value; SubKeys = $SubKey }
            # GetValue(name, default, options), as RegistryKey has it.
            $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value { if ($this.Values.ContainsKey($args[0])) { $this.Values[$args[0]] } else { $args[1] } }
            $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @($this.Values.Keys) }
            $key | Add-Member -MemberType ScriptMethod -Name GetSubKeyNames -Value { @($this.SubKeys.Keys) }
            # A subkey set to 'denied' cannot be opened, as one that denies SYSTEM.
            $key | Add-Member -MemberType ScriptMethod -Name OpenSubKey -Value { $found = $this.SubKeys[$args[0]]; if ($found -eq 'denied') { throw 'Requested registry access is not allowed.' }; $found }
            $key | Add-Member -MemberType ScriptMethod -Name Close -Value { }
            return $key
        }

        function Set-TestService {
            <# The services key the collector reads, with the services $Service (name -> key). #>
            param([hashtable]$Service)
            $script:services = New-TestRegistryKey -SubKey $Service
            Mock -ModuleName $module Get-Item -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' } { $script:services }
        }

        function New-TestService {
            param([int]$Type = 16, [string]$ImagePath, [hashtable]$Extra = @{})
            $values = @{ Type = $Type; ImagePath = $ImagePath; ObjectName = 'LocalSystem'; Start = 2 }
            foreach ($name in $Extra.Keys) { $values[$name] = $Extra[$name] }
            return New-TestRegistryKey -Value $values
        }

        function Set-TestTask {
            <# The scheduled tasks the collector reads: one, \Updater, that runs $Execute with $Arguments. #>
            param([string]$Execute = '"C:\Tools\updater.exe"', [string]$Arguments = '')
            $script:task = [pscustomobject]@{ TaskPath = '\'; TaskName = 'Updater'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = ''; RunLevel = 'Highest' }; Actions = @([pscustomobject]@{ Execute = $Execute; Arguments = $Arguments; WorkingDirectory = '' }) }
            Set-Item -Path 'function:global:Get-ScheduledTask' -Value { $script:task }
        }
    }

    AfterAll {
        foreach ($name in $script:collectorCommands) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        # No registry key is there, unless a test gives one.
        Mock -ModuleName $module Test-Path { $false }
        Mock -ModuleName $module Get-Item { throw 'not available' }
    }

    It 'reads every area the host checks, in its order, and reports one it cannot read as a note, never failing' {
        # The registry fails too, as on a Windows runner it would not.
        Mock -ModuleName $module Test-Path { $true }

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
        $first.Items.ScheduledTask[0].Fingerprint | Should -Match '^[0-9a-f]{64}$'
        $second.Items.ScheduledTask[0].Fingerprint | Should -Not -Be $first.Items.ScheduledTask[0].Fingerprint
        (ConvertTo-Json -InputObject $first -Depth 6) | Should -Not -BeLike '*Secret123*'
    }

    It 'gives a service a fingerprint that changes with its binary path, its start type and what it runs when it fails, but not with a version number in a folder name' {
        $fingerprint = {
            param([string]$Image, [hashtable]$Extra = @{})
            Set-TestService -Service @{
                MySvc            = New-TestService -ImagePath $Image -Extra $Extra
                Disk             = New-TestService -Type 1 -ImagePath 'System32\drivers\disk.sys'
                CDPUserSvc_4f8e2 = New-TestService -Type 224 -ImagePath 'C:\Windows\system32\svchost.exe -k UnistackSvcGroup'
            }
            $facts = Invoke-TestCollector
            @($facts.Items.Service).Name | Should -Be @('MySvc')
            $facts.Items.Service[0].Fingerprint
        }

        $first = & $fingerprint 'C:\Tools\svc.exe'
        & $fingerprint 'C:\Tools\other.exe' | Should -Not -Be $first
        & $fingerprint 'C:\Tools\svc.exe' @{ Start = 3 } | Should -Not -Be $first
        & $fingerprint 'C:\Tools\svc.exe' @{ FailureCommand = 'C:\Tools\evil.exe' } | Should -Not -Be $first
        & $fingerprint 'C:\Tools\svc.exe' @{ FailureActions = [byte[]](1, 2, 3) } | Should -Not -Be $first
        $first | Should -Match '^[0-9a-f]{64}$'
        $oldVersion = & $fingerprint 'C:\Program Files\Vendor\4.18.25010.11-0\svc.exe'
        & $fingerprint 'C:\Program Files\Vendor\4.18.25020.1009-0\svc.exe' | Should -Be $oldVersion
    }

    It 'reports a service it cannot read as unreadable, and still reads the others (SEC-003)' {
        Set-TestService -Service @{ MySvc = New-TestService -ImagePath 'C:\Tools\svc.exe'; Hidden = 'denied' }

        $facts = Invoke-TestCollector

        ($facts.Items.Service | Where-Object Name -eq 'Hidden').Fingerprint | Should -Be 'unreadable'
        ($facts.Items.Service | Where-Object Name -eq 'MySvc').Fingerprint | Should -Match '^[0-9a-f]{64}$'
        @($facts.Notes | Where-Object { $_.Text -like '*could not read the Service item Hidden*' }).Count | Should -Be 1
    }

    It 'reads the Run keys for all users even when the guest account cannot be found (SEC-003)' {
        $run = New-TestRegistryKey -Value @{ Updater = 'C:\Tools\updater.exe' }
        Mock -ModuleName $module Test-Path -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' } { $true }
        Mock -ModuleName $module Get-Item -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' } { $run }

        $facts = Invoke-TestCollector

        @($facts.Items.RunKey).Name | Should -Be @('HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\Updater')
        $facts.Items.UserRunKey | Should -BeNullOrEmpty
    }

    It 'takes <Case> as pointing into a folder users can write to (SEC-006)' -ForEach @(
        @{ Case = 'a program written with %APPDATA%'; Execute = '%APPDATA%\x.exe'; Arguments = '' }
        @{ Case = 'a script in %LOCALAPPDATA% given as an argument'; Execute = 'C:\Windows\System32\wscript.exe'; Arguments = '"%LOCALAPPDATA%\evil.vbs"' }
        @{ Case = 'a DLL on a network share given as an argument'; Execute = 'rundll32.exe'; Arguments = '\\server\share\evil.dll,Run' }
    ) {
        Set-TestTask -Execute $Execute -Arguments $Arguments

        (Invoke-TestCollector).Items.ScheduledTask[0].InUserFolder | Should -BeTrue
    }

    It 'leaves a version number in a folder users can write to in the fingerprint (SEC-005)' {
        Set-TestTask -Execute '%LOCALAPPDATA%\Vendor\1.2.3\app.exe'
        $old = (Invoke-TestCollector).Items.ScheduledTask[0].Fingerprint
        Set-TestTask -Execute '%LOCALAPPDATA%\Vendor\1.2.4\app.exe'

        (Invoke-TestCollector).Items.ScheduledTask[0].Fingerprint | Should -Not -Be $old
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
        @($baseline.Persistence.PSObject.Properties.Name) | Should -Be @('ScheduledTask', 'Service', 'RunKey', 'UserRunKey', 'StartupFolder', 'UserStartupFolder', 'WmiSubscription', 'LocalUser', 'Administrators')
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

        Get-TestBaselineItem -VM $script:vm -Area 'Service' | Should -Be @('MySvc:bbbbbbbbbbbb')
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

        $all = InModuleScope $module -Parameters @{ Finding = $findings; Severity = $everySeverity } { param($Finding, $Severity) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -AlertSeverity $Severity }
        $highOnly = InModuleScope $module -Parameters @{ Finding = $findings } { param($Finding) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -AlertSeverity 'High' }
        $none = InModuleScope $module -Parameters @{ Finding = $findings } { param($Finding) Get-SecurityFindingReminderMessage -Finding $Finding -VMName 'Alpha' -AlertSeverity 'Medium' }

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

    It 'refuses <Case>, before asking, even with -WhatIf, as an error that does not stop the pipeline' -ForEach @(
        @{ Case = 'an Id the last scan did not find'; Id = 'Service:Other:000000000000'; Message = '*has no finding with the Id Service:Other:000000000000*' }
        @{ Case = 'a resolved finding'; Id = 'SMBv1:Server:On'; Message = '*is resolved*' }
    ) {
        Approve-LazyVMSecurityFinding -Name Alpha -Id $Id -WhatIf -ErrorVariable problem -ErrorAction SilentlyContinue

        "$problem" | Should -BeLike $Message
        { Approve-LazyVMSecurityFinding -Name Alpha -Id $Id -WhatIf -ErrorAction Stop } | Should -Throw -ExpectedMessage $Message
    }

    It 'approves the rest of the pipeline after one it refuses' {
        @([pscustomobject]@{ Name = 'Alpha'; Id = 'Service:Other:000000000000' }, [pscustomobject]@{ Name = 'Alpha'; Id = 'AutoLogon:Winlogon:On' }) |
            Approve-LazyVMSecurityFinding -ErrorVariable problem -ErrorAction SilentlyContinue

        "$problem" | Should -BeLike '*has no finding with the Id Service:Other:000000000000*'
        @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('AutoLogon:Winlogon:On')
    }

    It 'refuses a finding that is already approved' {
        Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On'

        { Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On' -ErrorAction Stop } | Should -Throw -ExpectedMessage '*already approved*'
    }

    It 'refuses when no scan has run yet' {
        $script:vm = New-TestVM -Root (New-TestRoot)

        { Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On' -ErrorAction Stop } | Should -Throw -ExpectedMessage '*No security scan has run on Alpha yet*'
    }

    It 'asks first, since it is meant to be done one finding at a time' {
        $binding = (Get-Command -Name Approve-LazyVMSecurityFinding).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

        $binding.ConfirmImpact | Should -Be 'High'
    }

    It 'refuses, changing nothing, when the baseline cannot be read, and moves it aside' {
        New-Item -ItemType Directory -Path (Split-Path -Path $script:vm.Settings.SecurityBaselineFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Value 'not json'

        { Approve-LazyVMSecurityFinding -Name Alpha -Id 'AutoLogon:Winlogon:On' -ErrorAction Stop } | Should -Throw -ExpectedMessage '*could not be read*moved it aside*'

        "$($script:vm.Settings.SecurityBaselineFile).bad" | Should -Exist
        Get-Content -LiteralPath "$($script:vm.Settings.SecurityBaselineFile).bad" -Raw | Should -BeLike 'not json*'
        $script:vm.Settings.SecurityBaselineFile | Should -Not -Exist
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

    It 'refuses an Id that is not approved, before asking, and revokes the rest of the pipeline' {
        @([pscustomobject]@{ Name = 'Alpha'; Id = 'SMBv1:Server:On' }, [pscustomobject]@{ Name = 'Alpha'; Id = 'AutoLogon:Winlogon:On' }) |
            Revoke-LazyVMSecurityFinding -ErrorVariable problem -ErrorAction SilentlyContinue

        "$problem" | Should -BeLike '*has no approved finding with the Id SMBv1:Server:On*'
        @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('Service:MySvc:999999999999')
    }

    It 'has its own parameter set for -Approved' {
        $sets = (Get-Command -Name Get-LazyVMSecurityFinding).ParameterSets

        @($sets.Name | Sort-Object) | Should -Be @('Approved', 'Finding')
        ($sets | Where-Object Name -eq 'Approved').Parameters.Where({ $_.Name -eq 'Approved' }).IsMandatory | Should -BeTrue
    }

    It 'says so when nothing is approved' {
        Get-LazyVMSecurityFinding -Name Alpha -Approved | Revoke-LazyVMSecurityFinding

        @(Get-LazyVMSecurityFinding -Name Alpha -Approved).Count | Should -Be 0
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*No security findings are approved on Alpha*' }
    }
}


Describe 'Save-GuestPersistenceBaseline, after Build-LazyVM (#334)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        $script:persistence = New-PersistenceFact
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = $script:persistence } }
        $script:vm = New-TestVM -Root (New-TestRoot)

        function Save-TestBaseline {
            InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }
        }
    }

    It 'records every area at the first build, with the findings opener in place first, keeping the approvals' {
        InModuleScope $module -Parameters @{ VM = $script:vm; Finding = (New-TestFinding -Id 'AutoLogon:Winlogon:On' -Severity 'Info') } {
            param($VM, $Finding)
            Add-SecurityApproval -VM $VM -Finding $Finding -Reason 'by design'
        }

        Save-TestBaseline

        Get-TestBaselineItem -VM $script:vm -Area 'Service' | Should -Be @('MySvc:bbbbbbbbbbbb')
        @((Read-TestBaselineFile -VM $script:vm).Approvals).Id | Should -Be @('AutoLogon:Winlogon:On')
        Should -Invoke -ModuleName $module Install-GuestSecurityFindingOpener -Times 1 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like 'Security baseline recorded: scheduled tasks: 1, services: 1, Run key entries for all users: 1,*' -and $Level -eq 'OK' }
    }

    It 'never makes a change known-good when the build runs again: it only adds an area the baseline lacks' {
        $script:persistence.Service = $null
        Save-TestBaseline
        $script:persistence = New-PersistenceFact
        $script:persistence.ScheduledTask[0].Fingerprint = 'changed00000'

        Save-TestBaseline

        Get-TestBaselineItem -VM $script:vm -Area 'ScheduledTask' | Should -Be @('\Microsoft\Windows\Defrag\ScheduledDefrag:aaaaaaaaaaaa')
        Get-TestBaselineItem -VM $script:vm -Area 'Service' | Should -Be @('MySvc:bbbbbbbbbbbb')
    }

    It 'writes nothing, without failing, when the guest cannot be read' {
        Save-TestBaseline
        $before = Get-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Raw
        Mock -ModuleName $module Get-GuestPersistenceFact { throw 'the guest stopped answering' }

        { Save-TestBaseline } | Should -Not -Throw

        Get-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Raw | Should -Be $before
        Should -Invoke -ModuleName $module Write-LogError -ParameterFilter { $Context -like '*(non-fatal)*next nightly scan*' }
    }

    It 'never writes over a baseline it cannot read: moves it aside and says so' {
        New-Item -ItemType Directory -Path (Split-Path -Path $script:vm.Settings.SecurityBaselineFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Value '{ broken'

        { Save-TestBaseline } | Should -Not -Throw

        "$($script:vm.Settings.SecurityBaselineFile).bad" | Should -Exist
        $script:vm.Settings.SecurityBaselineFile | Should -Not -Exist
        Should -Invoke -ModuleName $module Write-LogError -ParameterFilter { $ErrorRecord.Exception.Message -like '*moved it aside*' }
    }

    It 'leaves the guest alone when GuestSecurityScan is off' {
        $script:vm = New-TestVM -Root (New-TestRoot) -Off

        Save-TestBaseline

        Should -Invoke -ModuleName $module Get-GuestPersistenceFact -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'turned off in the settings \(GuestSecurityScan\)' }
    }
}

Describe 'The baseline of a rebuilt VM (#334)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        $script:vm = New-TestVM -Root (New-TestRoot)
        $script:persistence = New-PersistenceFact
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = $script:persistence } }
        # The old VM's baseline: the defrag task, and a task the user had approved into it long ago.
        $script:persistence.ScheduledTask += [pscustomobject]@{ Name = '\Mine'; Fingerprint = 'mine00000000'; Program = ''; InUserFolder = $false }
        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-GuestPersistenceBaseline -VM $VM }
    }

    It 'joins the new VM, read before the restore, to the old baseline, so a restored item is known only if it was before' {
        # The new VM, before the restore: a newer Windows changed the defrag task, and \Mine is not there yet.
        $script:persistence = New-PersistenceFact
        $script:persistence.ScheduledTask[0].Fingerprint = 'newwindows00'
        $fresh = InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Get-RebuildPersistenceBaseline -VM $VM }

        InModuleScope $module -Parameters @{ VM = $script:vm; Baseline = $fresh } { param($VM, $Baseline) Save-RebuildPersistenceBaseline -VM $VM -Baseline $Baseline }

        Get-TestBaselineItem -VM $script:vm -Area 'ScheduledTask' | Should -Be @('\Microsoft\Windows\Defrag\ScheduledDefrag:newwindows00', '\Microsoft\Windows\Defrag\ScheduledDefrag:aaaaaaaaaaaa', '\Mine:mine00000000')
    }

    It 'keeps the old baseline when the new VM could not be read' {
        $before = Get-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Raw

        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Save-RebuildPersistenceBaseline -VM $VM -Baseline $null }

        Get-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Raw | Should -Be $before
    }
}

Describe 'Join-PersistenceBaseline' {
    It 'knows, for each name, the fingerprints of both, and keeps an area only the earlier has' {
        $earlier = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.Service[0].Fingerprint = 'new000000000'
        $facts.LocalUser = $null
        $baseline = New-TestBaseline -Item $facts

        $joined = InModuleScope $module -Parameters @{ Baseline = $baseline; Earlier = $earlier } { param($Baseline, $Earlier) Join-PersistenceBaseline -Baseline $Baseline -Earlier $Earlier }

        @($joined.Service.Items['MySvc'] | Sort-Object) | Should -Be @('bbbbbbbbbbbb', 'new000000000')
        $joined.LocalUser.Items['dev'] | Should -Be @('eeeeeeeeeeee')
    }
}

Describe 'Items the guest could not fingerprint, and areas it cannot read (#334)' {
    It 'always reports an item it could not read, even one whose name the baseline knows' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.Service[0].Fingerprint = 'unreadable'

        $found = @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline)

        $found.Id | Should -Be @('Service:MySvc:unreadable')
        $found[0].Title | Should -Be 'Unreadable service: MySvc'
        $found[0].WhatWeFound | Should -BeLike '*could not read*'
    }

    It 'reports a link in a startup folder' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.UserStartupFolder = @([pscustomobject]@{ Name = 'dev\evil.lnk'; Fingerprint = 'link'; Program = ''; InUserFolder = $false })

        $found = @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline)

        $found.Id | Should -Be @('UserStartupFolder:dev\evil.lnk:link')
        $found[0].Title | Should -Be 'Link in a startup folder: dev\evil.lnk'
    }

    It 'reports, as Medium, an area the guest could not read two scans running, and nothing for one night' {
        $twice = @(InModuleScope $module { Get-UnreadablePersistenceAreaFinding -Unchecked 'UserRunKey', 'Firewall' -PreviouslyUnchecked 'UserRunKey', 'Firewall' })
        $once = @(InModuleScope $module { Get-UnreadablePersistenceAreaFinding -Unchecked 'UserRunKey' -PreviouslyUnchecked @() })

        $twice.Id | Should -Be @('UnreadableArea:UserRunKey')
        $twice[0].Severity | Should -Be 'Medium'
        $once.Count | Should -Be 0
    }
}

Describe 'Guest text in persistence findings and notes (SEC-004)' {
    It 'writes out control and format characters as \u{XXXX}' {
        $text = InModuleScope $module { ConvertTo-PrintableText -Text "a`r`nb$([char]0x1B)[2Jc$([char]0x202E)d" }

        $text | Should -Be 'a\u{000D}\u{000A}b\u{001B}[2Jc\u{202E}d'
    }

    It 'makes the name and program printable before the Id and title are made from them' {
        $baseline = New-TestBaseline -Item (New-PersistenceFact)
        $facts = New-PersistenceFact
        $facts.ScheduledTask += [pscustomobject]@{ Name = "\Evil`r`nId: Fake"; Fingerprint = '123456789abc'; Program = "C:\x$([char]0x202E)exe.txt"; InUserFolder = $false }

        $found = @(ConvertTo-TestPersistenceFinding -Item $facts -Baseline $baseline)

        $found[0].Id | Should -Be 'ScheduledTask:\Evil\u{000D}\u{000A}Id: Fake:123456789abc'
        $found[0].Title | Should -Not -Match '[\r\n]'
        $found[0].Where | Should -Be @('C:\x\u{202E}exe.txt')
    }

    It 'makes what a guest script reports printable in the log' {
        Mock -ModuleName $module Write-LogEntry { }

        InModuleScope $module { Write-GuestNote -Notes @(@{ Level = 'WARN'; Text = "line`r`nINJECTED" }) }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  line\u{000D}\u{000A}INJECTED' }
    }
}

Describe 'Invoke-GuestSecurityScan with a baseline it cannot read (SEC-002)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Install-GuestSecurityFindingOpener { }
        Mock -ModuleName $module Publish-GuestSecurityFinding { }
        Mock -ModuleName $module Get-GuestSecurityFact { [pscustomobject]@{ CollectedAt = '2026-11-02T10:40:00Z'; Checks = [pscustomobject]@{ SMBv1 = [pscustomobject]@{ Enabled = $false } } } }
        $script:persistence = New-PersistenceFact
        Mock -ModuleName $module Get-GuestPersistenceFact { [pscustomobject]@{ Items = $script:persistence } }
        $script:vm = New-TestVM -Root (New-TestRoot)
        New-Item -ItemType Directory -Path (Split-Path -Path $script:vm.Settings.SecurityBaselineFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Value '{ broken'
    }

    It 'counts every persistence area as not read, and leaves the file as it is' {
        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        Get-Content -LiteralPath $script:vm.Settings.SecurityBaselineFile -Raw | Should -BeLike '{ broken*'
        $record = Get-Content -LiteralPath $script:vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json
        @($record.Unchecked) | Should -Contain 'ScheduledTask'
        @($record.Unchecked) | Should -Contain 'Administrators'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*security baseline*could not be read*' -and $Level -eq 'WARN' }
    }

    It 'reports the areas as unreadable from the second scan on' {
        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }
        InModuleScope $module -Parameters @{ VM = $script:vm } { param($VM) Invoke-GuestSecurityScan -VM $VM }

        $ids = @((Get-Content -LiteralPath $script:vm.Settings.SecurityFindingsFile -Raw | ConvertFrom-Json).Findings).Id
        $ids | Should -Contain 'UnreadableArea:ScheduledTask'
    }
}

Describe 'Update-SecurityBaseline' {
    It 'waits for another write to finish, and says so when it does not' {
        $vm = New-TestVM -Root (New-TestRoot)
        New-Item -ItemType Directory -Path (Split-Path -Path $vm.Settings.SecurityBaselineFile -Parent) -Force | Out-Null
        $held = [System.IO.File]::Open("$($vm.Settings.SecurityBaselineFile).lock", 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            {
                InModuleScope $module -Parameters @{ VM = $vm } {
                    param($VM)
                    $script:SecurityBaselineLockSeconds = 1
                    try { Update-SecurityBaseline -VM $VM -Change { } }
                    finally { $script:SecurityBaselineLockSeconds = 60 }
                }
            } | Should -Throw -ExpectedMessage '*being changed by something else*'
        }
        finally { $held.Dispose() }
        $vm.Settings.SecurityBaselineFile | Should -Not -Exist
    }
}
