# EventLogging.Tests.ps1
# The guest's event logs, audit policy and PowerShell logging, kept at the
# Microsoft security baseline for Windows 11 at every build and every night
# (#291). The rules that decide what to fix run on the host and are tested
# here on their own; the guest is mocked, nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $logon = '{0CCE9215-69AE-11D9-BED3-505054503030}'
    $processCreation = '{0CCE922B-69AE-11D9-BED3-505054503030}'
    $fileSystem = '{0CCE921D-69AE-11D9-BED3-505054503030}'

    function New-TestLogState {
        <# What Get-GuestLoggingState reports for the event logs: every log LazyVM sizes, at $Size, in $LogMode. #>
        param(
            [long]$Size = 1GB,
            [string]$LogMode = 'Circular'
        )

        $names = InModuleScope $module { @($script:GuestEventLogMinimumSize.Keys) }
        return @($names | ForEach-Object { [pscustomobject]@{ Name = $_; MaximumSizeInBytes = $Size; LogMode = $LogMode } })
    }

    function New-TestAuditState {
        <# What Get-GuestLoggingState reports for the audit policy: every subcategory of the baseline at $Setting (3 = success and failure). #>
        param([int]$Setting = 3)

        $audit = @{}
        foreach ($entry in (InModuleScope $module { $script:GuestAuditPolicy })) { $audit[$entry.Guid] = $Setting }
        return $audit
    }

    function New-TestPolicyValueState {
        <# What Get-GuestLoggingState reports for the policy values: each at $Value. #>
        param($Value = 1)

        $wanted = InModuleScope $module { $script:GuestLoggingPolicyValues }
        return @($wanted | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Name = $_.Name; Value = $Value } })
    }
}

Describe 'Get-EventLogSizeFix' {
    It 'finds nothing to fix when every log is at least its size and overwrites its oldest events' {
        $fixes = @(InModuleScope $module -Parameters @{ Logs = (New-TestLogState) } { param($Logs) Get-EventLogSizeFix -Log $Logs })

        $fixes.Count | Should -Be 0
    }

    It 'raises the <Name> log to <Size> MB, the Microsoft security baseline''s size or LazyVM''s own' -ForEach @(
        @{ Name = 'Application'; Size = 32 }
        @{ Name = 'Security'; Size = 192 }
        @{ Name = 'System'; Size = 32 }
        @{ Name = 'Windows PowerShell'; Size = 32 }
        @{ Name = 'Microsoft-Windows-PowerShell/Operational'; Size = 256 }
        @{ Name = 'PowerShellCore/Operational'; Size = 256 }
    ) {
        $fixes = @(InModuleScope $module -Parameters @{ Logs = (New-TestLogState -Size 1MB) } { param($Logs) Get-EventLogSizeFix -Log $Logs })

        $fix = @($fixes | Where-Object Name -eq $Name)
        $fix.Count | Should -Be 1
        $fix[0].MaximumSizeInBytes | Should -Be ($Size * 1MB)
    }

    It 'sizes the PowerShell Operational logs, Windows PowerShell''s and PowerShell 7''s, as Sysmon''s, from the one constant they all use' {
        $sizes = InModuleScope $module {
            @{
                Shared         = $script:GuestBusyEventLogSize
                PowerShell     = $script:GuestEventLogMinimumSize['Microsoft-Windows-PowerShell/Operational']
                PowerShellCore = $script:GuestEventLogMinimumSize['PowerShellCore/Operational']
            }
        }

        $sizes.Shared | Should -Be 256MB
        $sizes.PowerShell | Should -Be $sizes.Shared
        $sizes.PowerShellCore | Should -Be $sizes.Shared
    }

    It 'keeps a log someone made bigger at its size' {
        $fixes = @(InModuleScope $module -Parameters @{ Logs = (New-TestLogState -Size 2GB -LogMode 'Retain') } { param($Logs) Get-EventLogSizeFix -Log $Logs })

        @($fixes | Where-Object MaximumSizeInBytes -ne 2GB).Count | Should -Be 0
    }

    It 'makes a log that is <LogMode> overwrite its oldest events instead' -ForEach @(
        @{ LogMode = 'Retain' }
        @{ LogMode = 'AutoBackup' }
    ) {
        $fixes = @(InModuleScope $module -Parameters @{ Logs = (New-TestLogState -LogMode $LogMode) } { param($Logs) Get-EventLogSizeFix -Log $Logs })

        $fixes.Count | Should -Be (New-TestLogState).Count
        $fixes[0].Text | Should -Match 'overwrit'
    }

    It 'leaves alone a log it does not size, such as Sysmon''s, which Set-GuestSysmon looks after' {
        $logs = @(New-TestLogState) + [pscustomobject]@{ Name = 'Microsoft-Windows-Sysmon/Operational'; MaximumSizeInBytes = 1MB; LogMode = 'Retain' }

        $fixes = @(InModuleScope $module -Parameters @{ Logs = $logs } { param($Logs) Get-EventLogSizeFix -Log $Logs })

        $fixes.Count | Should -Be 0
    }
}

Describe 'Get-AuditPolicyFix' {
    It 'finds nothing to fix when every subcategory audits at least what the baseline asks' {
        $fixes = @(InModuleScope $module -Parameters @{ Audit = (New-TestAuditState) } { param($Audit) Get-AuditPolicyFix -Audit $Audit })

        $fixes.Count | Should -Be 0
    }

    It 'turns on process creation auditing (event 4688), as the baseline does' {
        $fixes = @(InModuleScope $module -Parameters @{ Audit = (New-TestAuditState -Setting 0) } { param($Audit) Get-AuditPolicyFix -Audit $Audit })

        $fix = @($fixes | Where-Object Guid -eq $processCreation)
        $fix.Count | Should -Be 1
        $fix[0].Success | Should -BeTrue
        $fix[0].Failure | Should -BeFalse
    }

    It 'turns on what is missing, Logon failures here, and reads the GUIDs whatever their case' {
        $audit = New-TestAuditState
        $audit.Remove($logon)
        $audit[$logon.ToLowerInvariant()] = 1

        $fixes = @(InModuleScope $module -Parameters @{ Audit = $audit } { param($Audit) Get-AuditPolicyFix -Audit $Audit })

        $fixes.Count | Should -Be 1
        $fixes[0].Guid | Should -Be $logon
        $fixes[0].Failure | Should -BeTrue
        $fixes[0].Text | Should -Match 'Logon'
    }

    It 'never turns off auditing someone added, such as File System' {
        $audit = New-TestAuditState
        $audit[$fileSystem] = 3

        $fixes = @(InModuleScope $module -Parameters @{ Audit = $audit } { param($Audit) Get-AuditPolicyFix -Audit $Audit })

        $fixes.Count | Should -Be 0
    }

    It 'takes a subcategory the guest did not report as not audited' {
        $audit = New-TestAuditState
        $audit.Remove($processCreation)

        $fixes = @(InModuleScope $module -Parameters @{ Audit = $audit } { param($Audit) Get-AuditPolicyFix -Audit $Audit })

        @($fixes | ForEach-Object Guid) | Should -Be @($processCreation)
    }
}

Describe 'Get-LoggingPolicyValueFix' {
    It 'finds nothing to fix when every value is set' {
        $fixes = @(InModuleScope $module -Parameters @{ Values = (New-TestPolicyValueState); Logs = (New-TestLogState) } { param($Values, $Logs) Get-LoggingPolicyValueFix -Value $Values -Log $Logs })

        $fixes.Count | Should -Be 0
    }

    It 'turns on <What>' -ForEach @(
        @{ What = 'the command line in process creation events'; Name = 'ProcessCreationIncludeCmdLine_Enabled' }
        @{ What = 'the audit subcategories over the old categories'; Name = 'SCENoApplyLegacyAuditPolicy' }
    ) {
        $fixes = @(InModuleScope $module -Parameters @{ Values = (New-TestPolicyValueState -Value $null); Logs = (New-TestLogState) } { param($Values, $Logs) Get-LoggingPolicyValueFix -Value $Values -Log $Logs })

        $fix = @($fixes | Where-Object Name -eq $Name)
        $fix.Count | Should -Be 1
        $fix[0].Value | Should -Be 1
    }

    It 'turns on script block logging for Windows PowerShell and for PowerShell 7, each under its own policy key (#297)' {
        $fixes = @(InModuleScope $module -Parameters @{ Values = (New-TestPolicyValueState -Value $null); Logs = (New-TestLogState) } { param($Values, $Logs) Get-LoggingPolicyValueFix -Value $Values -Log $Logs })

        $paths = @($fixes | Where-Object Name -eq 'EnableScriptBlockLogging' | ForEach-Object Path)
        $paths | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
        $paths | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ScriptBlockLogging'
        $paths.Count | Should -Be 2
    }

    It 'leaves PowerShell 7''s policy alone in a guest where its log is not there, because PowerShell 7 is not installed (#297)' {
        $logs = @(New-TestLogState | Where-Object Name -ne 'PowerShellCore/Operational')

        $fixes = @(InModuleScope $module -Parameters @{ Values = (New-TestPolicyValueState -Value $null); Logs = $logs } { param($Values, $Logs) Get-LoggingPolicyValueFix -Value $Values -Log $Logs })

        @($fixes | Where-Object Path -like '*PowerShellCore*').Count | Should -Be 0
        @($fixes | Where-Object Name -eq 'EnableScriptBlockLogging').Count | Should -Be 1
    }

    It 'sets a value someone changed back' {
        $values = New-TestPolicyValueState
        $values[0].Value = 0

        $fixes = @(InModuleScope $module -Parameters @{ Values = $values; Logs = (New-TestLogState) } { param($Values, $Logs) Get-LoggingPolicyValueFix -Value $Values -Log $Logs })

        $fixes.Count | Should -Be 1
        $fixes[0].Name | Should -Be $values[0].Name
    }

    It 'does not turn on module logging, which would write the parameters LazyVM passes, such as recovery passwords, to the log' {
        $wanted = InModuleScope $module { $script:GuestLoggingPolicyValues }

        @($wanted | Where-Object { $_.Path -match 'ModuleLogging' -or $_.Name -match 'ModuleLogging' }).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-AuditPolicyBackup' {
    It 'reads each subcategory''s setting by its GUID, in capitals, and skips the options' {
        $file = Join-Path -Path $TestDrive -ChildPath 'audit.csv'
        Set-Content -LiteralPath $file -Value @(
            'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value'
            'GUEST,System,Audit Logon,{0cce9215-69ae-11d9-bed3-505054503030},Success and Failure,,3'
            'GUEST,System,Audit Process Creation,{0cce922b-69ae-11d9-bed3-505054503030},No Auditing,,0'
            'GUEST,System,Option:CrashOnAuditFail,,Disabled,,0'
        )

        $audit = ConvertFrom-AuditPolicyBackup -Path $file

        $audit.Count | Should -Be 2
        $audit[$logon] | Should -Be 3
        $audit[$processCreation] | Should -Be 0
    }
}

Describe 'Set-GuestEventLogging' {
    BeforeAll {
        $state = [pscustomobject]@{ Logs = @(New-TestLogState -Size 1MB); Audit = (New-TestAuditState); Values = @(New-TestPolicyValueState) }
        $clean = [pscustomobject]@{ Logs = @(New-TestLogState); Audit = (New-TestAuditState); Values = @(New-TestPolicyValueState) }
    }

    BeforeEach {
        Mock -ModuleName $module Get-GuestStagingFolder { 'C:\Program Files\LazyVM\Staging' }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
    }

    It 'leaves the guest alone when GuestEventLogging is off' {
        Mock -ModuleName $module Invoke-GuestScript { }

        InModuleScope $module { Set-GuestEventLogging -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestEventLogging = $false })) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'turned off in the settings \(GuestEventLogging\)' }
    }

    It 'reads the guest''s logging, fixes what differs from LazyVM''s settings and logs each fix' {
        Mock -ModuleName $module Invoke-GuestScript { $state } -ParameterFilter { $Activity -eq 'event logging check' }
        Mock -ModuleName $module Invoke-GuestScript { } -ParameterFilter { $Activity -eq 'event logging' }

        InModuleScope $module { Set-GuestEventLogging -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestEventLogging = $true })) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $Activity -eq 'event logging' -and @($ArgumentList[0]).Count -eq $state.Logs.Count -and @($ArgumentList[1]).Count -eq 0 -and @($ArgumentList[2]).Count -eq 0
        }
        Should -Invoke -ModuleName $module Write-LogEntry -Times $state.Logs.Count -Exactly -ParameterFilter { $Message -like 'Event logging: *' -and $Level -eq 'OK' }
    }

    It 'has the guest back up its audit policy in the staging folder, which only administrators can change, not in the admin''s TEMP (#317)' {
        Mock -ModuleName $module Invoke-GuestScript { $clean } -ParameterFilter { $Activity -eq 'event logging check' }

        InModuleScope $module { Set-GuestEventLogging -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestEventLogging = $true })) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $Activity -eq 'event logging check' -and $ArgumentList[-1] -eq 'C:\Program Files\LazyVM\Staging'
        }
    }

    It 'changes nothing when the guest is already at LazyVM''s settings' {
        Mock -ModuleName $module Invoke-GuestScript { $clean } -ParameterFilter { $Activity -eq 'event logging check' }
        Mock -ModuleName $module Invoke-GuestScript { } -ParameterFilter { $Activity -eq 'event logging' }

        InModuleScope $module { Set-GuestEventLogging -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestEventLogging = $true })) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { $Activity -eq 'event logging' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'already' -and $Level -eq 'INFO' }
    }

    It 'logs a guest failure as non-fatal and carries on' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'auditpol failed in guest: access denied' }

        { InModuleScope $module { Set-GuestEventLogging -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestEventLogging = $true })) } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly -ParameterFilter { $Context -match 'non-fatal' }
    }

    It 'emits nothing' {
        Mock -ModuleName $module Invoke-GuestScript { $state } -ParameterFilter { $Activity -eq 'event logging check' }
        Mock -ModuleName $module Invoke-GuestScript { 'stray' } -ParameterFilter { $Activity -eq 'event logging' }

        $result = @(InModuleScope $module { Set-GuestEventLogging -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestEventLogging = $true })) })

        $result.Count | Should -Be 0
    }
}

Describe 'Get-GuestLoggingState' {
    It 'backs the audit policy up to a file of its own in $Folder, and removes it (#317)' {
        $folder = Join-Path $TestDrive 'Staging'
        $backups = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-GuestAuditPol { $backups.Add(("$($Argument[1])" -replace '^/file:', '')) }
        Mock ConvertFrom-AuditPolicyBackup { @{} }
        Mock Remove-Item { }
        Mock New-Object { [pscustomobject]@{ MaximumSizeInBytes = 1MB; LogMode = 'Circular' } }
        Mock Get-ItemProperty { }

        $null = Get-GuestLoggingState -LogName @('Security') -PolicyValue @([pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Test'; Name = 'Value' }) -Folder $folder

        $backups.Count | Should -Be 1
        Split-Path -Path $backups[0] -Parent | Should -Be $folder
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $backups[0] }
    }
}

Describe 'Get-GuestLoggingState and a log that is not there' {
    It 'reports the logs that are there and leaves out one that is not, such as PowerShell 7''s when it is not installed (#297)' {
        Mock Invoke-GuestAuditPol { }
        Mock ConvertFrom-AuditPolicyBackup { @{} }
        Mock Remove-Item { }
        Mock Get-ItemProperty { }
        Mock New-Object {
            if ($ArgumentList -eq 'PowerShellCore/Operational') {
                # What Windows PowerShell 5.1 throws for a channel that does not exist.
                throw [System.Management.Automation.MethodInvocationException]::new('The specified channel could not be found.', [System.IO.FileNotFoundException]::new('EventLogNotFoundException'))
            }
            [pscustomobject]@{ MaximumSizeInBytes = 1MB; LogMode = 'Circular' }
        }

        $state = Get-GuestLoggingState -LogName @('Security', 'PowerShellCore/Operational') -PolicyValue @([pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Test'; Name = 'Value' }) -Folder (Join-Path $TestDrive 'Staging')

        @($state.Logs | ForEach-Object Name) | Should -Be @('Security')
    }

    It 'still fails for any other error reading a log' {
        Mock Invoke-GuestAuditPol { }
        Mock ConvertFrom-AuditPolicyBackup { @{} }
        Mock Remove-Item { }
        Mock New-Object { throw [System.UnauthorizedAccessException]::new('Access is denied') }

        { Get-GuestLoggingState -LogName @('Security') -PolicyValue @([pscustomobject]@{ Path = 'HKLM:\SOFTWARE\Test'; Name = 'Value' }) -Folder (Join-Path $TestDrive 'Staging') } | Should -Throw '*Access is denied*'
    }
}

Describe 'Set-GuestEventLogMinimum' {
    It 'raises a smaller log to the size and makes it circular, and says it changed it (#298)' {
        Mock New-Object { [pscustomobject]@{ MaximumSizeInBytes = 1MB; LogMode = 'Circular' } }
        Mock Set-GuestEventLogSize { }

        $changed = Set-GuestEventLogMinimum -Name 'Microsoft-Windows-Sysmon/Operational' -MinimumSizeInBytes 256MB

        $changed | Should -BeTrue
        Should -Invoke Set-GuestEventLogSize -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft-Windows-Sysmon/Operational' -and $MaximumSizeInBytes -eq 256MB }
    }

    It 'keeps a log someone made bigger at its size, and makes it circular if it is not (#298)' {
        Mock New-Object { [pscustomobject]@{ MaximumSizeInBytes = 1GB; LogMode = 'Retain' } }
        Mock Set-GuestEventLogSize { }

        $changed = Set-GuestEventLogMinimum -Name 'Microsoft-Windows-Sysmon/Operational' -MinimumSizeInBytes 256MB

        $changed | Should -BeTrue
        Should -Invoke Set-GuestEventLogSize -Times 1 -Exactly -ParameterFilter { $MaximumSizeInBytes -eq 1GB }
    }

    It 'leaves a log that is big enough and circular alone, and says it did (#298)' {
        Mock New-Object { [pscustomobject]@{ MaximumSizeInBytes = 512MB; LogMode = 'Circular' } }
        Mock Set-GuestEventLogSize { }

        $changed = Set-GuestEventLogMinimum -Name 'Microsoft-Windows-Sysmon/Operational' -MinimumSizeInBytes 256MB

        $changed | Should -BeFalse
        Should -Invoke Set-GuestEventLogSize -Times 0 -Exactly
    }
}

Describe 'The GuestEventLogging setting' {
    It 'is on unless a VM turns it off' {
        $schema = InModuleScope $module { Get-SettingsSchema }

        $schema.properties['GuestEventLogging']['type'] | Should -Be 'boolean'
        $schema.properties['GuestEventLogging']['default'] | Should -BeTrue
    }
}
