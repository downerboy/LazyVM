# Configuration.Tests.ps1
# Settings: the schema and its defaults, reading and checking JSON settings
# files, the last-good safety net, choosing the root folder, resolving host
# paths, creating and selecting VM profiles, the VM context and the
# credential store.
#
# Most of these functions are internal to the module, so each test runs its
# body with InModuleScope, with test data passed in through -Parameters.
# Everything is built under $TestDrive; the registry is never touched.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function New-TestFile {
        <# A file under $TestDrive with the given text. #>
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
            [string]$Name = "$([guid]::NewGuid().ToString('N')).json"
        )

        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $path = Join-Path -Path $folder -ChildPath $Name
        Set-Content -LiteralPath $path -Value $Text -NoNewline
        return $path
    }

    function New-TestRoot {
        <#
          A root folder with one VM folder per entry in $Profiles (VM name ->
          the JSON of its <Name>\Config\VM.json), and optionally a host-wide
          settings file in Shared\Config.
        #>
        param(
            [hashtable]$Profiles = @{},
            [string]$HostSettings
        )

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $configDir = Join-Path -Path $root -ChildPath 'Shared/Config'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null

        foreach ($name in $Profiles.Keys) {
            $profileDir = Join-Path -Path (Join-Path -Path $root -ChildPath $name) -ChildPath 'Config'
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $profileDir -ChildPath 'VM.json') -Value $Profiles[$name]
        }
        if ($HostSettings) {
            Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.json') -Value $HostSettings
        }
        return $root
    }

    function Read-TestJson {
        param([Parameter(Mandatory)][string]$Path)
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    }

    # A small tooling list, as it appears in Tooling.json or VM.json's Tooling section.
    $toolingJson = '{ "Version": 1, "RecordedAt": "2026-10-08T19:30:00.0000000-07:00", "Products": [], "WingetPackages": [ { "Id": "Git.Git", "Source": "winget" } ], "Programs": [] }'

    function Get-TestWingetId {
        <# The winget ids in a profile's Tooling section. #>
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
        return @($Settings.Tooling.WingetPackages | ForEach-Object { $_.Id })
    }
}

Describe 'The settings schema' {
    It 'has a default (or a file holding it) and a description for every setting' {
        $schema = InModuleScope $module { Get-SettingsSchema }

        foreach ($name in @($schema.properties.Keys | Where-Object { $_ -ne '$schema' })) {
            ($schema.properties[$name].Contains('default') -or $schema.properties[$name].Contains('defaultFile')) | Should -BeTrue -Because "'$name' needs a default"
            $schema.properties[$name]['description'] | Should -Not -BeNullOrEmpty -Because "'$name' needs a description"
        }
    }

    It 'gives the Tooling setting the default list that ships with the module' {
        $defaults = InModuleScope $module { Get-DefaultSetting }
        $shipped = Read-TestJson -Path (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data/Tooling.Default.json')

        Get-TestWingetId -Settings $defaults | Should -Be @($shipped.WingetPackages | ForEach-Object { $_.Id })
        $defaults.Tooling.RecordedAt | Should -BeOfType ([string])
    }

    It 'rejects a Tooling section with a misspelled part' {
        $path = New-TestFile -Text '{ "Tooling": { "Version": 1, "Product": [] } }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'accepts a GuestEnvironment section with a mapped drive' {
        $path = New-TestFile -Text '{ "GuestEnvironment": { "MachineVariables": { "JAVA_HOME": "C:\\Java" }, "SecretVariables": [ { "Scope": "User", "Name": "GITHUB_TOKEN" } ], "MappedDrives": [ { "Letter": "Z:", "Path": "\\\\server\\share" } ] } }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'rejects a mapped drive in GuestEnvironment that is not a letter and a share' {
        $path = New-TestFile -Text '{ "GuestEnvironment": { "MappedDrives": [ { "Letter": "ZZ", "Path": "C:\\not-a-share" } ] } }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'accepts a GuestFirewallRules list' {
        $path = New-TestFile -Text '{ "GuestFirewallRules": [ { "DisplayName": "Dev API", "Direction": "Inbound", "Action": "Allow", "Protocol": "TCP", "LocalPort": [ "5000" ], "RemoteAddress": [ "Any" ], "Profile": "Any" } ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'accepts a GuestScheduledTasks list' {
        $path = New-TestFile -Text '{ "GuestScheduledTasks": [ { "Name": "Nightly build", "Xml": "<?xml version=\"1.0\"?><Task />" } ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'rejects a scheduled task whose definition is not XML' {
        $path = New-TestFile -Text '{ "GuestScheduledTasks": [ { "Name": "Nightly build", "Xml": "not xml" } ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'accepts a GuestSql record of instance settings and logins' {
        $path = New-TestFile -Text '{ "GuestSql": { "Configs": [ { "Name": "max server memory (MB)", "Value": 4096 } ], "Logins": [ { "Name": "app", "TypeDesc": "SQL_LOGIN", "IsDisabled": false, "DefaultDb": "master", "DefaultLang": "us_english", "SidHex": "0x1A2B", "HashHex": "0x0200FF", "PolicyChecked": true, "ExpirationChecked": false, "ServerRoles": [ "dbcreator" ] }, { "Name": "DEV\\sean", "TypeDesc": "WINDOWS_LOGIN", "IsDisabled": false, "DefaultDb": "master", "DefaultLang": "us_english", "SidHex": "0x0105", "HashHex": "", "PolicyChecked": false, "ExpirationChecked": false, "ServerRoles": [] } ] } }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'accepts SQL Agent operators, jobs and alerts in GuestSql' {
        $path = New-TestFile -Text '{ "GuestSql": { "Configs": [], "Logins": [], "Agent": { "Operators": [ { "Name": "Dev team", "Enabled": true, "EmailAddress": "dev@example.com", "Category": "[Uncategorized]" } ], "Jobs": [ { "Name": "Nightly ETL", "Enabled": true, "Description": "", "Category": "[Uncategorized (Local)]", "Owner": "DEV\\sean", "StartStepId": 1, "NotifyLevelEventLog": 2, "NotifyLevelEmail": 2, "NotifyEmailOperator": "Dev team", "DeleteLevel": 0, "Steps": [ { "Id": 1, "Name": "Load", "Subsystem": "TSQL", "Command": "EXEC dbo.Load", "Database": "Sales", "OnSuccessAction": 1, "OnSuccessStepId": 0, "OnFailAction": 2, "OnFailStepId": 0, "RetryAttempts": 0, "RetryInterval": 0, "OutputFile": "", "Flags": 0, "Proxy": "" } ], "Schedules": [ { "Name": "Nightly", "Enabled": true, "FreqType": 4, "FreqInterval": 1, "FreqSubdayType": 1, "FreqSubdayInterval": 0, "FreqRelativeInterval": 0, "FreqRecurrenceFactor": 0, "ActiveStartDate": 20261029, "ActiveEndDate": 99991231, "ActiveStartTime": 20000, "ActiveEndTime": 235959 } ] } ], "Alerts": [ { "Name": "Severity 17", "Enabled": true, "MessageId": 0, "Severity": 17, "DelayBetweenResponses": 60, "NotificationMessage": "", "IncludeEventDescription": 1, "Database": "", "EventDescriptionKeyword": "", "Job": "", "PerformanceCondition": "", "Category": "[Uncategorized]", "Notifications": [ { "Operator": "Dev team", "Method": 1 } ] } ] } } }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'rejects a SQL Agent job step without a command' {
        $path = New-TestFile -Text '{ "GuestSql": { "Configs": [], "Logins": [], "Agent": { "Operators": [], "Alerts": [], "Jobs": [ { "Name": "Nightly ETL", "Enabled": true, "Description": "", "Category": "", "Owner": "", "StartStepId": 1, "NotifyLevelEventLog": 2, "NotifyLevelEmail": 0, "NotifyEmailOperator": "", "DeleteLevel": 0, "Schedules": [], "Steps": [ { "Id": 1, "Name": "Load", "Subsystem": "TSQL", "Database": "Sales", "OnSuccessAction": 1, "OnSuccessStepId": 0, "OnFailAction": 2, "OnFailStepId": 0, "RetryAttempts": 0, "RetryInterval": 0, "OutputFile": "", "Flags": 0, "Proxy": "" } ] } ] } } }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'rejects a SQL login whose <Field> is not hexadecimal, since restore writes it into SQL as it is' -ForEach @(
        @{ Field = 'SidHex'; SidHex = '0x1A; DROP LOGIN x'; HashHex = '0x02' }
        @{ Field = 'HashHex'; SidHex = '0x1A'; HashHex = 'secret' }
    ) {
        $path = New-TestFile -Text ('{ "GuestSql": { "Configs": [], "Logins": [ { "Name": "app", "TypeDesc": "SQL_LOGIN", "IsDisabled": false, "DefaultDb": "master", "DefaultLang": "us_english", "SidHex": "' + $SidHex + '", "HashHex": "' + $HashHex + '", "PolicyChecked": true, "ExpirationChecked": false, "ServerRoles": [] } ] } }')

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'accepts a GuestAppSettings list' {
        $path = New-TestFile -Text '{ "GuestAppSettings": [ { "Name": "WinMerge", "RegistryKey": "HKCU\\Software\\WinMerge", "Values": [ { "Path": "Settings", "Name": "Font", "Kind": "String", "Data": "Consolas" }, { "Path": "", "Name": "Size", "Kind": "DWord", "Data": 12 } ], "SecretValues": [ { "Path": "", "Name": "Password" } ] } ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'rejects an application setting value of a kind the registry restore cannot write' {
        $path = New-TestFile -Text '{ "GuestAppSettings": [ { "Name": "WinMerge", "RegistryKey": "HKCU\\Software\\WinMerge", "Values": [ { "Path": "", "Name": "Font", "Kind": "Link", "Data": "x" } ], "SecretValues": [] } ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'rejects a firewall rule whose direction is neither Inbound nor Outbound' {
        $path = New-TestFile -Text '{ "GuestFirewallRules": [ { "DisplayName": "Dev API", "Direction": "Sideways", "Action": "Allow", "Protocol": "TCP", "LocalPort": [ "5000" ], "RemoteAddress": [ "Any" ], "Profile": "Any" } ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage '*1 problem*'
    }

    It 'accepts all its own defaults' {
        $defaults = InModuleScope $module { Get-DefaultSetting }
        $path = New-TestFile -Text (ConvertTo-Json -InputObject $defaults -Depth 20)

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Not -Throw
    }

    It 'lists the settings users change, not the ones LazyVM works out itself' {
        $defaults = InModuleScope $module { Get-DefaultSetting }

        $defaults.Keys | Should -Contain 'vCPU'
        $defaults.Keys | Should -Contain 'MaintenanceTime'
        foreach ($derived in 'Root', 'ScheduleTaskName', 'ResumeRegKey', 'GuestCredFile', 'GuestSqlDataDir', 'SeedDiskPath') {
            $defaults.Keys | Should -Not -Contain $derived
        }
    }

    It 'gives a fresh copy each time, so changing one cannot change the defaults' {
        InModuleScope $module {
            $first = Get-DefaultSetting
            $first.GuestProjectPaths[0] = 'changed'
            (Get-DefaultSetting).GuestProjectPaths[0] | Should -Not -Be 'changed'
        }
    }
}

Describe 'Read-SettingsFile' {
    It 'returns the values the file sets' {
        $path = New-TestFile -Text '{ "$schema": "./LazyVM.Settings.schema.json", "vCPU": 8, "UseDevDrive": false, "GuestTimeZone": "UTC" }'

        $values = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path }

        $values.Count | Should -Be 3
        $values.vCPU | Should -Be 8
        $values.UseDevDrive | Should -BeFalse
        $values.GuestTimeZone | Should -Be 'UTC'
    }

    It 'returns ordinary tables, looked up whatever the case' {
        $path = New-TestFile -Text '{ "InstallerBootstrappers": { "VisualStudio.18.Release": "https://example.com/vs.exe" } }'

        $values = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path }

        $values | Should -BeOfType [hashtable]
        $values['installerbootstrappers'] | Should -BeOfType [hashtable]
        $values.InstallerBootstrappers['visualstudio.18.release'] | Should -Be 'https://example.com/vs.exe'
    }

    It 'matches names whatever their case, and uses the schema''s spelling' {
        $path = New-TestFile -Text '{ "vcpu": 6, "MEMMAXGB": 32 }'

        $values = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path }

        @($values.Keys | Sort-Object) | Should -BeExactly @('MemMaxGB', 'vCPU')
    }

    It 'accepts a single value where a list belongs, as a one-item list' {
        $path = New-TestFile -Text '{ "ProjectExcludeDirs": "bin" }'

        $values = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path }

        , $values.ProjectExcludeDirs | Should -BeOfType [System.Collections.IList]
        $values.ProjectExcludeDirs | Should -Be @('bin')
    }

    It 'keeps a one-item list a list' {
        $path = New-TestFile -Text '{ "AppSettings": [ { "Name": "Git", "RegistryKey": "HKCU\\Software\\Git" } ] }'

        $values = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path }

        , $values.AppSettings | Should -BeOfType [System.Collections.IList]
        $values.AppSettings.Count | Should -Be 1
        $values.AppSettings[0].Name | Should -Be 'Git'
    }

    It 'treats an empty file as setting nothing' {
        $path = New-TestFile -Text ''

        $values = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path }

        $values.Count | Should -Be 0
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown setting'; Text = '{ "Bogus": 1 }'; Message = "*'Bogus' is not a setting*" }
        @{ Case = 'the wrong kind of value'; Text = '{ "vCPU": "lots" }'; Message = "*'vCPU' should be a whole number, but is text.*" }
        @{ Case = 'a number out of range'; Text = '{ "vCPU": 0 }'; Message = "*'vCPU'*" }
        @{ Case = 'text that does not fit its pattern'; Text = '{ "MaintenanceTime": "2am" }'; Message = "*'MaintenanceTime'*" }
        @{ Case = 'list items of the wrong kind'; Text = '{ "ProjectExcludeDirs": [ 1 ] }'; Message = "*'ProjectExcludeDirs, item 1' should be text, but is a whole number.*" }
        @{ Case = 'an unknown field inside a list item'; Text = '{ "AppSettings": [ { "Name": "A", "RegistryKey": "HKCU\\A", "Extra": 1 } ] }'; Message = "*'AppSettings, item 1, Extra' is not allowed here.*" }
        @{ Case = 'a host path that is neither relative nor full'; Text = '{ "DiskDir": "D:VMs" }'; Message = "*'DiskDir'*" }
        @{ Case = 'JSON that does not parse'; Text = '{ "vCPU": 4 "UseDevDrive": true }'; Message = '*is not valid JSON*' }
        @{ Case = 'a file that is not a table'; Text = '[ 1, 2 ]'; Message = '*must be a table of settings*' }
    ) {
        $path = New-TestFile -Text $Text

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } |
            Should -Throw -ExpectedMessage $Message
    }

    It 'reports every problem together' {
        $path = New-TestFile -Text '{ "vCPU": "lots", "Bogus": 1, "UseDevDrive": "yes" }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } |
            Should -Throw -ExpectedMessage '*has 3 problem(s), so none of it was used*'
    }

    It 'reports a problem inside a list together with a top-level one' {
        # PowerShell 7.6's Test-Json leaves out problems inside list items.
        $path = New-TestFile -Text '{ "vCPU": "lots", "ProjectExcludeDirs": [ "bin", 2 ] }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } |
            Should -Throw -ExpectedMessage "*has 2 problem(s)*'ProjectExcludeDirs, item 2' should be text*"
    }
}

Describe 'Import-SettingsFile' {
    It 'keeps a copy of a file that loads cleanly' {
        $path = New-TestFile -Text '{ "vCPU": 8 }' -Name 'VM.json'

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path } | Out-Null

        $lastGood = Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'VM.lastgood.json'
        $lastGood | Should -Exist
        Get-Content -LiteralPath $lastGood -Raw | Should -Be '{ "vCPU": 8 }'
    }

    It 'keeps no copy with -ReadOnly' {
        $path = New-TestFile -Text '{ "vCPU": 8 }' -Name 'VM.json'

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path -ReadOnly } | Out-Null

        Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'VM.lastgood.json' | Should -Not -Exist
    }

    It 'reports a broken file straight away when run by a person' {
        $path = New-TestFile -Text '{ "vCPU": 8 }' -Name 'VM.json'
        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path } | Out-Null
        Set-Content -LiteralPath $path -Value '{ "vCPU": "eight" }'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path } } |
            Should -Throw -ExpectedMessage "*'vCPU' should be a whole number*"
    }

    It 'uses the last good copy, with a warning, when unattended' {
        $path = New-TestFile -Text '{ "vCPU": 8 }' -Name 'VM.json'
        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path } | Out-Null
        Set-Content -LiteralPath $path -Value '{ "vCPU": "eight" }'

        $result = InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path -Unattended }

        $result.Values.vCPU | Should -Be 8
        $result.Warning | Should -BeLike '*last time it loaded cleanly*'
        $result.Warning | Should -BeLike "*'vCPU' should be a whole number*"
    }

    It 'does not replace the last good copy with a broken file' {
        $path = New-TestFile -Text '{ "vCPU": 8 }' -Name 'VM.json'
        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path } | Out-Null
        Set-Content -LiteralPath $path -Value 'not json'

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path -Unattended } | Out-Null

        $lastGood = Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'VM.lastgood.json'
        Get-Content -LiteralPath $lastGood -Raw | Should -Be '{ "vCPU": 8 }'
    }

    It 'still reports a broken file when unattended and there is no good copy' {
        $path = New-TestFile -Text '{ "vCPU": "eight" }' -Name 'VM.json'

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Import-SettingsFile -Path $Path -Unattended } } |
            Should -Throw -ExpectedMessage "*'vCPU'*"
    }
}

Describe 'Resolve-SettingsRoot' {
    It 'drops a trailing backslash' {
        InModuleScope $module { Resolve-SettingsRoot -Path 'D:\DevVM\' -Source 'a test' } | Should -Be 'D:\DevVM'
    }

    It "refuses '<Root>' as the root folder" -ForEach @(
        @{ Root = 'D:\' }
        @{ Root = '\\server\share\DevVM' }
        @{ Root = 'DevVM' }
        @{ Root = 'D:\Dev"VM' }
        @{ Root = '' }
    ) {
        { InModuleScope $module -Parameters @{ Root = $Root } { param($Root) Resolve-SettingsRoot -Path $Root -Source 'a test' } } |
            Should -Throw -ExpectedMessage '*must be a folder on a local drive*'
    }
}

Describe 'Resolve-LazyVMRoot' {
    It 'prefers -Root to the registered folder' {
        InModuleScope $module {
            Mock Get-RegisteredRoot { 'F:\Registered' }
            $root = Resolve-LazyVMRoot -Root 'E:\Given'
            $root.Path | Should -Be 'E:\Given'
            $root.Source | Should -Be 'the -Root parameter'
        }
    }

    It 'uses the registered folder when there is no -Root' {
        InModuleScope $module {
            Mock Get-RegisteredRoot { 'F:\Registered' }
            (Resolve-LazyVMRoot).Path | Should -Be 'F:\Registered'
        }
    }

    It 'says how to choose one when there is none' {
        InModuleScope $module {
            Mock Get-RegisteredRoot { $null }
            { Resolve-LazyVMRoot } | Should -Throw -ExpectedMessage '*Set-LazyVMRoot -Path*'
        }
    }
}

Describe 'Resolve-HostPathSetting' {
    It 'joins relative paths to the root and keeps full paths as written' {
        $settings = InModuleScope $module {
            $settings = @{}
            foreach ($name in $script:HostPathSettings) {
                $settings[$name] = "Folder\$name"
            }
            $settings['DiskDir'] = 'E:\VMs'
            $settings['ISOPath'] = '\\nas\iso\win11.iso'
            $settings['LogFile'] = '.\Logs\Alpha.log'

            Resolve-HostPathSetting -Settings $settings -Root 'D:\DevVM'
            $settings
        }

        $settings.CheckpointDir | Should -Be 'D:\DevVM\Folder\CheckpointDir'
        $settings.DiskDir | Should -Be 'E:\VMs'
        $settings.ISOPath | Should -Be '\\nas\iso\win11.iso'
        $settings.LogFile | Should -Be 'D:\DevVM\Logs\Alpha.log'
    }

    It "refuses '<Value>'" -ForEach @(
        @{ Value = '' }
        @{ Value = 'D:VMs' }
        @{ Value = '\VMs' }
    ) {
        {
            InModuleScope $module -Parameters @{ Value = $Value } {
                param($Value)
                $settings = @{}
                foreach ($name in $script:HostPathSettings) {
                    $settings[$name] = 'Folder'
                }
                $settings['DiskDir'] = $Value

                Resolve-HostPathSetting -Settings $settings -Root 'D:\DevVM'
            }
        } | Should -Throw -ExpectedMessage "*'DiskDir' must be a path inside the LazyVM folder*"
    }
}

Describe 'Add-DerivedSetting' {
    It 'works out the names and files LazyVM keeps for a VM' {
        # Under TestDrive, not D:\DevVM: Join-Path needs the drive to exist (#93).
        $root = Join-Path -Path $TestDrive -ChildPath 'DevVM'
        $settings = @{
            VMName       = 'Alpha'
            Root         = $root
            DiskDir      = "$root\Alpha\Disks"
            CredStoreDir = "$root\Shared\Credentials"
        }

        InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Add-DerivedSetting -Settings $Settings }

        $settings.VMRoot | Should -Be "$root\Alpha"
        $settings.OSDiskPath | Should -Be "$root\Alpha\Disks\Alpha-OS.vhdx"
        $settings.VMConfigDir | Should -Be "$root\Alpha\Virtual Machines"
        $settings.SeedDiskPath | Should -Be "$root\Alpha\Disks\Alpha-Seed.iso"
        $settings.CredKeyFile | Should -Be "$root\Shared\Credentials\.lazyvm.key"
        $settings.GuestCredFile | Should -Be "$root\Alpha\Credentials\guest.cred"
        $settings.CertCredFile | Should -Be "$root\Alpha\Credentials\certs.cred"
        $settings.EnvironmentCredFile | Should -Be "$root\Alpha\Credentials\environment.cred"
        $settings.AppSettingsCredFile | Should -Be "$root\Alpha\Credentials\appsettings.cred"
        $settings.BitLockerCredFile | Should -Be "$root\Alpha\Credentials\bitlocker.cred"
        $settings.ResumeRegKey | Should -Be 'HKLM:\SOFTWARE\LazyVM\Alpha'
        $settings.ResumeTaskName | Should -Be 'LazyVM-ResumeAfterReboot-Alpha'
        $settings.ScheduleTaskName | Should -Be 'LazyVM-Maintain-Alpha'
    }
}

Describe 'Test-VMName' {
    It "returns <Expected> for '<Name>'" -ForEach @(
        @{ Name = 'MsDevVM'; Expected = $true }
        @{ Name = 'Dev-2026'; Expected = $true }
        @{ Name = 'A'; Expected = $true }
        @{ Name = 'Exactly15Chars1'; Expected = $true }
        @{ Name = 'SixteenCharacter'; Expected = $false }
        @{ Name = '-Dev'; Expected = $false }
        @{ Name = 'Dev VM'; Expected = $false }
        @{ Name = 'Dev_VM'; Expected = $false }
        @{ Name = ''; Expected = $false }
        @{ Name = 'Shared'; Expected = $false }
        @{ Name = 'shared'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } {
            param($Name)
            Test-VMName -Name $Name
        } | Should -Be $Expected
    }
}

Describe 'Expand-VMToken' {
    It 'replaces {VM} in text settings and leaves the others alone' {
        $settings = @{
            LogFile  = 'Logs\{VM}.log'
            Computer = '{VM}'
            MemoryGB = 8
            Folders  = @('{VM}')
        }

        InModuleScope $module -Parameters @{ Settings = $settings } {
            param($Settings)
            Expand-VMToken -Settings $Settings -VMName 'Alpha'
        }

        $settings.LogFile | Should -Be 'Logs\Alpha.log'
        $settings.Computer | Should -Be 'Alpha'
        $settings.MemoryGB | Should -Be 8
        $settings.Folders | Should -Be @('{VM}')
    }
}

Describe 'Resolve-VMSelection' {
    It 'picks the only VM when none is named' {
        $root = New-TestRoot -Profiles @{ Alpha = '{}' }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Resolve-VMSelection -Root $Root
        } | Should -Be 'Alpha'
    }

    It 'returns the named VM with its folder''s spelling' {
        $root = New-TestRoot -Profiles @{ Alpha = '{}'; MsDevVM = '{}' }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Resolve-VMSelection -Root $Root -Requested 'msdevvm'
        } | Should -BeExactly 'MsDevVM'
    }

    It 'ignores a folder with no VM.json' {
        $root = New-TestRoot -Profiles @{ Alpha = '{}' }
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Stray/Config') -Force | Out-Null

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Resolve-VMSelection -Root $Root
        } | Should -Be 'Alpha'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a VM that does not exist'; Profiles = @{ Alpha = '{}' }; Requested = 'Beta'; Message = "*no VM named 'Beta' (VMs on this host: Alpha)*" }
        @{ Case = 'to run with no VMs'; Profiles = @{}; Requested = ''; Message = '*There are no VMs yet*' }
        @{ Case = 'to guess between several VMs'; Profiles = @{ Alpha = '{}'; Beta = '{}' }; Requested = ''; Message = '*several VMs (Alpha, Beta)*' }
    ) {
        $root = New-TestRoot -Profiles $Profiles

        {
            InModuleScope $module -Parameters @{ Root = $root; Requested = $Requested } {
                param($Root, $Requested)
                Resolve-VMSelection -Root $Root -Requested $Requested
            }
        } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'Initialize-ConfigFolder' {
    It 'adds the schema for the editor and a settings file to open' {
        $configDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))

        InModuleScope $module -Parameters @{ ConfigDir = $configDir } { param($ConfigDir) Initialize-ConfigFolder -ConfigDir $ConfigDir }

        Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.schema.json' | Should -Exist
        # The template schema refers to the settings schema beside it (#250).
        Join-Path -Path $configDir -ChildPath 'LazyVM.Template.schema.json' | Should -Exist
        $settings = Read-TestJson -Path (Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.json')
        $settings['$schema'] | Should -Be './LazyVM.Settings.schema.json'
    }

    It 'brings an old schema copy up to date but never touches the settings file' {
        $configDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $configDir | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.schema.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.json') -Value '{ "vCPU": 8 }'

        InModuleScope $module -Parameters @{ ConfigDir = $configDir } { param($ConfigDir) Initialize-ConfigFolder -ConfigDir $ConfigDir }

        (Read-TestJson -Path (Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.schema.json')).title | Should -Be 'LazyVM settings'
        (Get-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'LazyVM.Settings.json') -Raw).Trim() | Should -Be '{ "vCPU": 8 }'
    }
}

Describe 'New-VMProfile' {
    It 'creates a profile that points at the schema and holds every setting from the shared template, as written' {
        $root = New-TestRoot -HostSettings '{ "MemMaxGB": 24 }'

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Alpha'
        }

        $path | Should -Exist
        $vmProfile = Read-TestJson -Path $path
        $vmProfile['$schema'] | Should -Be '../../Shared/Config/LazyVM.Settings.schema.json'
        $settingNames = InModuleScope $module { @((Get-DefaultSetting).Keys) }
        foreach ($name in $settingNames) { $vmProfile.Keys | Should -Contain $name }
        $vmProfile.MemMaxGB | Should -Be 24
        $vmProfile.LogFile | Should -Be '{VM}\Logs\{VM}.log'
    }

    It 'never writes a password or other secret into the profile' {
        $root = New-TestRoot

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Alpha'
        }

        @((Read-TestJson -Path $path).Keys | Where-Object { $_ -match 'Password|Secret|Token' }) | Should -BeNullOrEmpty
    }

    It 'sets the maintenance time an hour after the latest one in use, wrapping at midnight' {
        $root = New-TestRoot -Profiles @{
            Alpha = '{ "MaintenanceTime": "02:00" }'
            Beta  = '{ "MaintenanceTime": "23:30" }'
        }

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Gamma'
        }

        (Read-TestJson -Path $path).MaintenanceTime | Should -Be '00:30'
    }

    It 'counts a VM with no maintenance time of its own as using the default' {
        $root = New-TestRoot -Profiles @{ Alpha = '{}' }

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Beta'
        }

        $default = InModuleScope $module { (Get-DefaultSetting).MaintenanceTime }
        $expected = [datetime]::ParseExact($default, 'HH:mm', $null).AddHours(1).ToString('HH:mm')
        (Read-TestJson -Path $path).MaintenanceTime | Should -Be $expected
    }

    It 'keeps the new profile as the first version in History' {
        $root = New-TestRoot

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Alpha'
        }

        $history = @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json')
        $history.Count | Should -Be 1
        Get-Content -LiteralPath $history[0].FullName -Raw | Should -Be (Get-Content -LiteralPath $path -Raw)
    }

    It 'with -From, copies the source VM''s settings and tooling list, and takes the per-VM ones from the shared template' {
        $root = New-TestRoot -Profiles @{
            Alpha = '{ "MemMaxGB": 32, "LogFile": "Logs\\Alpha-Old.log", "GuestComputerName": "ALPHA",
                       "SQLDiskGuid": "{11111111-2222-3333-4444-555555555555}", "SQLDiskScsiLocation": 1,
                       "DevDriveGuid": "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}", "DevDriveScsiLocation": 2,
                       "UserDiskGuid": "{BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE}", "UserDiskScsiLocation": 3,
                       "Tooling":' + $toolingJson + ' }'
        }

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Beta' -From 'Alpha'
        }
        $vmProfile = Read-TestJson -Path $path

        $vmProfile.MemMaxGB | Should -Be 32
        $vmProfile.LogFile | Should -Be '{VM}\Logs\{VM}.log'
        $vmProfile.GuestComputerName | Should -Be '{VM}'
        # The source VM's disks are not the new VM's: it records its own.
        foreach ($identity in 'SQLDiskGuid', 'SQLDiskScsiLocation', 'DevDriveGuid', 'DevDriveScsiLocation', 'UserDiskGuid', 'UserDiskScsiLocation') {
            $vmProfile.Keys | Should -Contain $identity
            $vmProfile[$identity] | Should -BeNullOrEmpty -Because "-From must not copy $identity"
        }
        Get-TestWingetId -Settings $vmProfile | Should -Be @('Git.Git')
        Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'Tooling.json' | Should -Not -Exist
    }

    It 'with -From, first folds an older source VM''s Tooling.json into its VM.json' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "MemMaxGB": 32 }' }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/Tooling.json') -Value $toolingJson

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @() }
            New-VMProfile -Root $Root -Name 'Beta' -From 'Alpha'
        }

        Get-TestWingetId -Settings (Read-TestJson -Path $path) | Should -Be @('Git.Git')
        Get-TestWingetId -Settings (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')) | Should -Be @('Git.Git')
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an invalid name'; Name = 'Not Valid'; From = ''; Message = "*'Not Valid' cannot be used as a VM name*" }
        @{ Case = 'a name already in use'; Name = 'Alpha'; From = ''; Message = "*'Alpha' already exists*" }
        @{ Case = 'copying a VM that does not exist'; Name = 'Beta'; From = 'Nope'; Message = "*no VM named 'Nope' to copy*" }
    ) {
        $root = New-TestRoot -Profiles @{ Alpha = '{}' }

        {
            InModuleScope $module -Parameters @{ Root = $root; Name = $Name; From = $From } {
                param($Root, $Name, $From)
                New-VMProfile -Root $Root -Name $Name -From $From
            }
        } | Should -Throw -ExpectedMessage $Message
    }

    It 'with -ConfigTemplate, applies the config template''s settings over the shared template, and never its Name' {
        $root = New-TestRoot -HostSettings ('{ "MemMaxGB": 24, "Tooling":' + $toolingJson + ' }')

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Alpha' -ConfigTemplate 'PlainWindows'
        }
        $vmProfile = Read-TestJson -Path $path

        $vmProfile.MemMaxGB | Should -Be 24
        $vmProfile.InstallVisualStudio | Should -BeFalse
        $vmProfile.InstallSqlServer | Should -BeFalse
        Get-TestWingetId -Settings $vmProfile | Should -BeNullOrEmpty
        # Name and Settings are the template's own fields, not settings.
        $vmProfile.Keys | Should -Not -Contain 'Name'
        $vmProfile.Keys | Should -Not -Contain 'Settings'
    }

    It 'refuses a config template that does not exist, naming the ones there are' {
        $root = New-TestRoot

        {
            InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                New-VMProfile -Root $Root -Name 'Alpha' -ConfigTemplate 'Nope'
            }
        } | Should -Throw -ExpectedMessage "*no config template named 'Nope'*Developer, PlainWindows*"
    }
}

Describe 'Config templates' {
    BeforeAll {
        function New-UserTemplate {
            <# A file in <Root>\Shared\Templates with the given text. #>
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$FileName,
                [Parameter(Mandatory)][string]$Text
            )

            $folder = Join-Path -Path $Root -ChildPath 'Shared/Templates'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath $FileName) -Value $Text
        }
    }

    It 'are named by their Name field, not their file name, built-in and in Shared\Templates alike' {
        $root = New-TestRoot
        New-UserTemplate -Root $root -FileName 'whatever.json' -Text '{ "Name": "WebDev", "Settings": { "vCPU": 6 } }'

        $names = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Get-VMTemplateName -Root $Root }
        $settings = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMTemplate -Root $Root -Name 'webdev' }

        $names | Should -Be @('Developer', 'PlainWindows', 'WebDev')
        $settings.vCPU | Should -Be 6
        $settings.Keys | Should -Not -Contain 'Name'
    }

    It 'are only the built-in ones when there is no LazyVM folder yet' {
        InModuleScope $module { Get-VMTemplateName -Root '' } | Should -Be @('Developer', 'PlainWindows')
    }

    It 'leave out a file that cannot be read, and say why when a template is not found' {
        $root = New-TestRoot
        New-UserTemplate -Root $root -FileName 'Broken.json' -Text '{ "Name": "Broken", "Settings": { "vCPU": "many" } }'

        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Get-VMTemplateName -Root $Root } | Should -Not -Contain 'Broken'
        {
            InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMTemplate -Root $Root -Name 'Broken' }
        } | Should -Throw -ExpectedMessage "*no config template named 'Broken'*could not be read*Broken.json*vCPU*"
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a setting outside Settings'; Text = '{ "Name": "Mine", "vCPU": 6, "Settings": {} }'; Message = "*'vCPU'*Settings*" }
        @{ Case = 'a file with no Name'; Text = '{ "Settings": {} }'; Message = '*needs a Name*' }
        @{ Case = 'a name that is not a single word'; Text = '{ "Name": "My template", "Settings": {} }'; Message = "*'My template'*" }
        @{ Case = 'a file with no Settings'; Text = '{ "Name": "Mine" }'; Message = '*needs a Settings table*' }
    ) {
        $path = New-TestFile -Text $Text

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-VMTemplateFile -Path $Path } } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuse a name two templates share, naming both files' {
        $root = New-TestRoot
        New-UserTemplate -Root $root -FileName 'One.json' -Text '{ "Name": "Twin", "Settings": {} }'
        New-UserTemplate -Root $root -FileName 'Two.json' -Text '{ "Name": "Twin", "Settings": {} }'

        {
            InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMTemplate -Root $Root -Name 'Twin' }
        } | Should -Throw -ExpectedMessage '*Twin*One.json*Two.json*'
    }

    It 'use the same name rule in the module and the template schema' {
        $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '../src/LazyVM/Data/LazyVM.Template.schema.json'
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable

        $schema.properties.Name.pattern | Should -Be (InModuleScope $module { $script:TemplateNamePattern })
    }
}

Describe 'The built-in config templates' {
    BeforeDiscovery {
        $templateDir = Join-Path -Path $PSScriptRoot -ChildPath '../src/LazyVM/Data/Templates'
        $templateFiles = @(Get-ChildItem -LiteralPath $templateDir -Filter '*.json' -File | ForEach-Object { $_.FullName })
    }

    It 'are Developer and PlainWindows' {
        InModuleScope $module { Get-VMTemplateName -Root '' } | Should -Be @('Developer', 'PlainWindows')
    }

    It '<_> matches the template schema, loads cleanly and sets no setting that must differ between VMs' -ForEach $templateFiles {
        # Test-Json on Windows does not follow the template schema's file
        # reference to the settings schema, so the test puts it in place.
        $dataDir = Join-Path -Path $PSScriptRoot -ChildPath '../src/LazyVM/Data'
        $templateSchema = Get-Content -LiteralPath (Join-Path -Path $dataDir -ChildPath 'LazyVM.Template.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $settingsSchema = Get-Content -LiteralPath (Join-Path -Path $dataDir -ChildPath 'LazyVM.Settings.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $templateSchema.properties.Settings['$ref'] | Should -Be 'LazyVM.Settings.schema.json'
        $templateSchema['definitions'] = $settingsSchema['definitions']
        foreach ($key in 'definitions', '$id', '$schema') { $settingsSchema.Remove($key) }
        $templateSchema.properties['Settings'] = $settingsSchema

        Test-Json -Json (Get-Content -LiteralPath $_ -Raw) -Schema (ConvertTo-Json -InputObject $templateSchema -Depth 50) | Should -BeTrue

        $template = InModuleScope $module -Parameters @{ Path = $_ } { param($Path) Read-VMTemplateFile -Path $Path }
        $perVM = InModuleScope $module { Get-PerVMSettingName }
        @($template.Settings.Keys | Where-Object { $perVM -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'Developer changes nothing: the defaults are the full developer set-up' {
        $values = InModuleScope $module { Read-VMTemplate -Root '' -Name 'Developer' }
        $defaults = InModuleScope $module { Get-DefaultSetting }

        $values.Count | Should -Be 0
        foreach ($setting in 'InstallVisualStudio', 'InstallSqlServer', 'UseDevDrive', 'GuestDeveloperMode') {
            $defaults[$setting] | Should -BeTrue -Because "Developer relies on $setting being on by default"
        }
        @($defaults.Tooling.Products) | Should -Not -BeNullOrEmpty
    }

    It 'PlainWindows has no Visual Studio, no SQL Server or SQL drive, no Dev Drive, no Developer Mode and no tooling' {
        $values = InModuleScope $module { Read-VMTemplate -Root '' -Name 'PlainWindows' }

        $values.InstallVisualStudio | Should -BeFalse
        $values.InstallSqlServer | Should -BeFalse
        $values.UseDevDrive | Should -BeFalse
        $values.GuestDeveloperMode | Should -BeFalse
        @($values.Tooling.Products) | Should -BeNullOrEmpty
        @($values.Tooling.WingetPackages) | Should -BeNullOrEmpty
        @($values.Tooling.Programs) | Should -BeNullOrEmpty
    }
}

Describe 'Export-VMTemplate (#250)' {
    BeforeAll {
        $sourceJson = '{ "MemMaxGB": 32, "LogFile": "Logs\\Alpha-Old.log", "GuestComputerName": "ALPHA",
                         "SQLDiskGuid": "{11111111-2222-3333-4444-555555555555}", "SQLDiskScsiLocation": 1,
                         "Tooling":' + $toolingJson + ' }'
    }

    It 'saves the VM''s settings and tooling list, without the per-VM ones, as a config template in Shared\Templates' {
        $root = New-TestRoot -Profiles @{ Alpha = $sourceJson }

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Export-VMTemplate -Root $Root -Name 'Alpha' -TemplateName 'WebDev'
        }
        $template = Read-TestJson -Path $path

        $path | Should -Be (Join-Path -Path $root -ChildPath 'Shared/Templates/WebDev.json')
        $template['$schema'] | Should -Be '../Config/LazyVM.Template.schema.json'
        $template.Name | Should -Be 'WebDev'
        $template.Settings.MemMaxGB | Should -Be 32
        Get-TestWingetId -Settings $template.Settings | Should -Be @('Git.Git')
        $perVM = InModuleScope $module { Get-PerVMSettingName }
        @($template.Settings.Keys | Where-Object { $perVM -contains $_ }) | Should -BeNullOrEmpty
        Join-Path -Path $root -ChildPath 'Shared/Config/LazyVM.Template.schema.json' | Should -Exist
    }

    It 'makes a template that new VMs are built from, without its Name' {
        $root = New-TestRoot -Profiles @{ Alpha = $sourceJson }

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $null = Export-VMTemplate -Root $Root -Name 'Alpha' -TemplateName 'WebDev'
            New-VMProfile -Root $Root -Name 'Beta' -ConfigTemplate 'WebDev'
        }
        $vmProfile = Read-TestJson -Path $path

        $vmProfile.MemMaxGB | Should -Be 32
        $vmProfile.GuestComputerName | Should -Be '{VM}'
        $vmProfile.SQLDiskGuid | Should -BeNullOrEmpty
        $vmProfile.Keys | Should -Not -Contain 'Name'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'the name of a built-in template'; TemplateName = 'developer'; Message = "*already a config template named 'developer'*" }
        @{ Case = 'the name of one of the user''s templates'; TemplateName = 'Mine'; Message = "*already a config template named 'Mine'*" }
        @{ Case = 'a name that is not a single word'; TemplateName = 'My template'; Message = "*'My template' cannot be used as a config template name*" }
    ) {
        $root = New-TestRoot -Profiles @{ Alpha = $sourceJson }
        $folder = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Shared/Templates') -Force
        Set-Content -LiteralPath (Join-Path -Path $folder.FullName -ChildPath 'other.json') -Value '{ "Name": "Mine", "Settings": {} }'

        {
            InModuleScope $module -Parameters @{ Root = $root; TemplateName = $TemplateName } {
                param($Root, $TemplateName)
                Export-VMTemplate -Root $Root -Name 'Alpha' -TemplateName $TemplateName
            }
        } | Should -Throw -ExpectedMessage $Message
    }

    It 'never writes over a file of the same name' {
        $root = New-TestRoot -Profiles @{ Alpha = $sourceJson }
        $folder = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Shared/Templates') -Force
        Set-Content -LiteralPath (Join-Path -Path $folder.FullName -ChildPath 'WebDev.json') -Value 'not json'

        {
            InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                Export-VMTemplate -Root $Root -Name 'Alpha' -TemplateName 'WebDev'
            }
        } | Should -Throw -ExpectedMessage '*WebDev.json already exists*'
        (Get-Content -LiteralPath (Join-Path -Path $folder.FullName -ChildPath 'WebDev.json') -Raw).Trim() | Should -Be 'not json'
    }
}

Describe 'Read-VMSetting' {
    It 'takes what the VM profile lacks from the shared template, then names, roots and derives everything' {
        $root = New-TestRoot -HostSettings '{ "MemMaxGB": 12, "vCPU": 6 }' -Profiles @{
            Alpha = '{ "GuestComputerName": "ALPHA-PC", "vCPU": 2 }'
        }

        $result = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root }
        $settings = $result.Settings

        $result.VMName | Should -Be 'Alpha'
        $result.MissingKeys | Should -Contain 'MemMaxGB'
        $result.MissingKeys | Should -Not -Contain 'vCPU'
        $result.MissingKeys | Should -Not -Contain 'GuestComputerName'
        $settings.MemMaxGB | Should -Be 12
        $settings.vCPU | Should -Be 2
        $settings.GuestComputerName | Should -Be 'ALPHA-PC'
        $settings.ScheduleTaskName | Should -Be 'LazyVM-Maintain-Alpha'
        $settings.LogFile | Should -Be "$root\Alpha\Logs\Alpha.log"
        $settings.VMRoot | Should -Be "$root\Alpha"
        $settings.ProfileDir | Should -Be "$root\Alpha\Config"
        $settings.ConfigDir | Should -Be "$root\Shared\Config"
        $settings.ISOPath | Should -Be "$root\Shared\ISO\Win11Ent_Eval.iso"
        $settings.SQLDiskPath | Should -Be "$root\Alpha\Disks\Alpha-SQL.vhdx"
        $settings.DevDrivePath | Should -Be "$root\Alpha\Disks\Alpha-DevDrive.vhdx"
        $settings.UserDiskPath | Should -Be "$root\Alpha\Disks\Alpha-User.vhdx"
        $result.Sources.MemMaxGB | Should -Be 'LazyVM.Settings.json'
        $result.Sources.vCPU | Should -Be 'Alpha\Config\VM.json'
        $result.Sources.UseDevDrive | Should -Be 'Default'
    }

    It 'reports a bad setting in the VM profile' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "Bogus": 1 }' }

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root } } |
            Should -Throw -ExpectedMessage "*'Bogus' is not a setting*"
    }

    It 'passes on the warning when an unattended run falls back to a last good copy' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }
        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root } | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json') -Value '{ "vCPU": "two" }'

        $result = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root -Unattended }

        $result.Settings.vCPU | Should -Be 2
        $result.Warnings.Count | Should -Be 1
    }
}

Describe 'ConvertTo-ComparableJson' {
    It 'gives the same text for tables whatever their key order' {
        InModuleScope $module {
            $first = @{ Name = 'WinMerge'; RegistryKey = 'HKCU\Software\Thingamahiggins\WinMerge' }
            $second = [ordered]@{ RegistryKey = 'HKCU\Software\Thingamahiggins\WinMerge'; Name = 'WinMerge' }
            ConvertTo-ComparableJson @($first) | Should -Be (ConvertTo-ComparableJson @($second))
            ConvertTo-ComparableJson 4 | Should -Not -Be (ConvertTo-ComparableJson 8)
        }
    }
}

Describe 'Update-VMProfile' {
    BeforeAll {
        function Get-HistoryFile {
            param([string]$Root)
            @(Get-ChildItem -LiteralPath (Join-Path -Path $Root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json' -ErrorAction SilentlyContinue)
        }
    }

    It 'writes the change, keeps the version it wrote in History and returns what changed' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4, "MemMaxGB": 16 }' }

        $changed = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @() }
            Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ vcpu = 8; MemMaxGB = 16 } -Reason 'a test'
        }

        $changed | Should -Be @('vCPU')
        $path = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json'
        $vmProfile = Read-TestJson -Path $path
        $vmProfile.vCPU | Should -Be 8
        $vmProfile.MemMaxGB | Should -Be 16
        $vmProfile['$schema'] | Should -Be '../../Shared/Config/LazyVM.Settings.schema.json'
        $history = @(Get-HistoryFile -Root $root)
        $history.Count | Should -Be 1
        Get-Content -LiteralPath $history[0].FullName -Raw | Should -Be (Get-Content -LiteralPath $path -Raw)
    }

    It 'names the version it keeps after the date and time it is given' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @() }
            $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ vCPU = 8 } -Reason 'a test' -Stamp '20261028-120000'
        }

        (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/History/VM-20261028-120000.json')).vCPU | Should -Be 8
    }

    It 'keeps the newest 3 versions, and any older one a tooling checkpoint still needs' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 5 }' }
        $historyDir = Join-Path -Path $root -ChildPath 'Alpha/Config/History'
        New-Item -ItemType Directory -Path (Join-Path -Path $historyDir -ChildPath 'Daily') -Force | Out-Null
        foreach ($n in 1..5) { Set-Content -LiteralPath (Join-Path -Path $historyDir -ChildPath "VM-20260101-00000$n.json") -Value "{ `"vCPU`": $n }" }
        Set-Content -LiteralPath (Join-Path -Path $historyDir -ChildPath 'Daily/Tooling-20260101.json') -Value '{}'

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @('20260101-000001') }
            $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ vCPU = 6 } -Reason 'a test' -Stamp '20260102-000000'
        }

        @(Get-HistoryFile -Root $root | ForEach-Object { $_.Name } | Sort-Object) |
            Should -Be @('VM-20260101-000001.json', 'VM-20260101-000004.json', 'VM-20260101-000005.json', 'VM-20260102-000000.json')
        Join-Path -Path $historyDir -ChildPath 'Daily/Tooling-20260101.json' | Should -Exist
    }

    It 'removes nothing from History when it cannot tell which versions the checkpoints need' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 5 }' }
        $historyDir = Join-Path -Path $root -ChildPath 'Alpha/Config/History'
        New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
        foreach ($n in 1..5) { Set-Content -LiteralPath (Join-Path -Path $historyDir -ChildPath "VM-20260101-00000$n.json") -Value "{ `"vCPU`": $n }" }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { $null }
            $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ vCPU = 6 } -Reason 'a test'
        }

        @(Get-HistoryFile -Root $root).Count | Should -Be 6
    }

    It 'writes nothing when no value differs' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $path = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json'
        $before = Get-Content -LiteralPath $path -Raw

        $changed = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ vCPU = 4 } -Reason 'a test'
        }

        $changed | Should -BeNullOrEmpty
        Get-Content -LiteralPath $path -Raw | Should -Be $before
        Get-HistoryFile -Root $root | Should -BeNullOrEmpty
    }

    It 'refuses <Case> and leaves the file as it was' -ForEach @(
        @{ Case = 'a setting that does not exist'; Change = @{ Bogus = 1 }; Message = "*'Bogus' is not a setting*" }
        @{ Case = 'a value the schema rejects'; Change = @{ vCPU = 'eight' }; Message = '*left as it was*' }
    ) {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $path = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json'
        $before = Get-Content -LiteralPath $path -Raw

        {
            InModuleScope $module -Parameters @{ Root = $root; Change = $Change } {
                param($Root, $Change)
                Mock Write-LogEntry {}
                Update-VMProfile -Root $Root -Name 'Alpha' -Change $Change -Reason 'a test'
            }
        } | Should -Throw -ExpectedMessage $Message

        Get-Content -LiteralPath $path -Raw | Should -Be $before
        Get-HistoryFile -Root $root | Should -BeNullOrEmpty
    }
}

Describe 'Sync-VMProfile' {
    BeforeAll {
        function Invoke-Sync {
            param([string]$Root)
            InModuleScope $module -Parameters @{ Root = $Root } {
                param($Root)
                Mock Write-LogEntry {}
                Mock Test-Unattended { $false }
                Mock Get-ToolingCheckpointStamp { , @() }
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Sync-VMProfile -VM $vm
            }
        }
    }

    It 'fills in every setting a profile lacks from the shared template, keeping its own values' {
        $root = New-TestRoot -HostSettings '{ "MemMaxGB": 24 }' -Profiles @{ Alpha = '{ "vCPU": 2 }' }

        Invoke-Sync -Root $root

        $vmProfile = Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')
        $vmProfile.vCPU | Should -Be 2
        $vmProfile.MemMaxGB | Should -Be 24
        $vmProfile.LogFile | Should -Be '{VM}\Logs\{VM}.log'
        $result = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root }
        $result.MissingKeys | Should -BeNullOrEmpty
    }

    It 'is no longer affected by the shared template once complete' {
        $root = New-TestRoot -HostSettings '{ "MemMaxGB": 24 }' -Profiles @{ Alpha = '{}' }
        Invoke-Sync -Root $root
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Shared/Config/LazyVM.Settings.json') -Value '{ "MemMaxGB": 48 }'

        $result = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root }

        $result.Settings.MemMaxGB | Should -Be 24
    }

    It 'keeps a copy of the profile as VM.Template.json once, and never changes it afterwards' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }
        $template = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.Template.json'

        Invoke-Sync -Root $root
        (Read-TestJson -Path $template).vCPU | Should -Be 2

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @() }
            $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ vCPU = 8 } -Reason 'a test'
        }
        Invoke-Sync -Root $root

        (Read-TestJson -Path $template).vCPU | Should -Be 2
        (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')).vCPU | Should -Be 8
    }

    It 'fills in the shared template''s tooling list for a VM that has none' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }

        Invoke-Sync -Root $root

        $default = InModuleScope $module { (Get-DefaultSetting).Tooling }
        Get-TestWingetId -Settings (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')) |
            Should -Be @($default.WingetPackages | ForEach-Object { $_.Id })
    }

    It 'never writes over a profile that cannot be read' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }
        $path = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json'
        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root } | Out-Null
        Set-Content -LiteralPath $path -Value '{ "vCPU": "two" }'

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Test-Unattended { $true }
            $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha' -Unattended).Settings)
            Sync-VMProfile -VM $vm
            Should -Invoke Write-LogEntry -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*cannot be read*' }
        }

        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be '{ "vCPU": "two" }'
    }
}

Describe 'Move-ToolingIntoProfile (#130)' {
    BeforeAll {
        function Invoke-Move {
            param([string]$Root)
            InModuleScope $module -Parameters @{ Root = $Root } {
                param($Root)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                Move-ToolingIntoProfile -Root $Root -Name 'Alpha'
            }
        }
    }

    BeforeEach {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }
        $configDir = Join-Path -Path $root -ChildPath 'Alpha/Config'
    }

    It 'folds Tooling.json into VM.json, and deletes it once VM.json reads back the same list' {
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'Tooling.json') -Value $toolingJson

        $moved = Invoke-Move -Root $root

        $moved | Should -BeTrue
        $vmProfile = Read-TestJson -Path (Join-Path -Path $configDir -ChildPath 'VM.json')
        $vmProfile.vCPU | Should -Be 2
        Get-TestWingetId -Settings $vmProfile | Should -Be @('Git.Git')
        $vmProfile.Tooling.RecordedAt | Should -Be '2026-10-08T19:30:00.0000000-07:00'
        Join-Path -Path $configDir -ChildPath 'Tooling.json' | Should -Not -Exist
    }

    It 'folds Tooling.Template.json into VM.Template.json, and deletes it' {
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.Template.json') -Value '{ "vCPU": 2 }'
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'Tooling.Template.json') -Value $toolingJson

        $null = Invoke-Move -Root $root

        Get-TestWingetId -Settings (Read-TestJson -Path (Join-Path -Path $configDir -ChildPath 'VM.Template.json')) | Should -Be @('Git.Git')
        Join-Path -Path $configDir -ChildPath 'Tooling.Template.json' | Should -Not -Exist
    }

    It 'keeps Tooling.Template.json while there is no VM.Template.json to fold it into' {
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'Tooling.Template.json') -Value $toolingJson

        $null = Invoke-Move -Root $root

        Join-Path -Path $configDir -ChildPath 'Tooling.Template.json' | Should -Exist
    }

    It 'makes each recorded tooling version a VM.json version under the same date and time, for its restore point' {
        New-Item -ItemType Directory -Path (Join-Path -Path $configDir -ChildPath 'History') | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'History/Tooling-20261008-193000.json') -Value $toolingJson

        $null = Invoke-Move -Root $root

        $version = Read-TestJson -Path (Join-Path -Path $configDir -ChildPath 'History/VM-20261008-193000.json')
        $version.vCPU | Should -Be 2
        Get-TestWingetId -Settings $version | Should -Be @('Git.Git')
        Join-Path -Path $configDir -ChildPath 'History/Tooling-20261008-193000.json' | Should -Not -Exist
    }

    It 'changes nothing for a VM with no Tooling.json' {
        $path = Join-Path -Path $configDir -ChildPath 'VM.json'
        $before = Get-Content -LiteralPath $path -Raw

        $moved = Invoke-Move -Root $root

        $moved | Should -BeFalse
        Get-Content -LiteralPath $path -Raw | Should -Be $before
    }

    It 'keeps Tooling.json, and warns, when VM.json already holds a different list' {
        $path = Join-Path -Path $configDir -ChildPath 'VM.json'
        Set-Content -LiteralPath $path -Value '{ "vCPU": 2, "Tooling": { "Version": 1, "Products": [], "WingetPackages": [], "Programs": [] } }'
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'Tooling.json') -Value $toolingJson

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @() }
            $null = Move-ToolingIntoProfile -Root $Root -Name 'Alpha'
            Should -Invoke Write-LogEntry -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*Tooling.json*' }
        }

        Join-Path -Path $configDir -ChildPath 'Tooling.json' | Should -Exist
        Get-TestWingetId -Settings (Read-TestJson -Path $path) | Should -BeNullOrEmpty
    }
}

Describe 'VMContext' {
    BeforeAll {
        $settings = @{
            VMName               = 'Alpha'
            SwitchName           = 'Default Switch'
            ISOPath              = 'D:\DevVM\ISO\win.iso'
            DevDriveLetter       = 'W'
            GuestAdminUser       = 'sean'
            GuestDataDriveLetter = 'e'
            SqlDataFolder        = 'Data'
            SqlLogFolder         = 'Log'
            SqlTempFolder        = 'Temp'
            SqlBackupFolder      = 'Backup'
        }
    }

    It 'starts the run-time values from the settings' {
        $runtime = InModuleScope $module -Parameters @{ Settings = $settings } {
            param($Settings)
            [VMContext]::new($Settings).Runtime
        }

        $runtime.SwitchName | Should -Be 'Default Switch'
        $runtime.ISOPath | Should -Be 'D:\DevVM\ISO\win.iso'
        $runtime.GuestAdminUser | Should -Be 'sean'
        $runtime.GuestDataDriveLetter | Should -Be 'E'
        $runtime.GuestSqlDataDir | Should -Be 'E:\Data'
        $runtime.GuestSqlBackupDir | Should -Be 'E:\Backup'
        $runtime.SqlServer | Should -Be 'localhost'
    }

    It 'keeps its own read-only copy of the settings' {
        InModuleScope $module -Parameters @{ Settings = $settings.Clone() } {
            param($Settings)
            $vm = [VMContext]::new($Settings)
            $Settings.VMName = 'Changed'

            $vm.Name | Should -Be 'Alpha'
            $vm.Settings.VMName | Should -Be 'Alpha'
            $vm.Settings['vmname'] | Should -Be 'Alpha'
            { $vm.Settings['VMName'] = 'Beta' } | Should -Throw
        }
    }

    It 'refuses a setting that does not exist, rather than giving nothing' {
        InModuleScope $module -Parameters @{ Settings = $settings } {
            param($Settings)
            $vm = [VMContext]::new($Settings)
            { $vm.Settings.NoSuchSetting } | Should -Throw
        }
    }

    It 'moves the SQL folders to the letter the data disk actually got' {
        $runtime = InModuleScope $module -Parameters @{ Settings = $settings } {
            param($Settings)
            $vm = [VMContext]::new($Settings)
            $vm.SetDataDriveLetter('f')
            $vm.Runtime
        }

        $runtime.GuestDataDriveLetter | Should -Be 'F'
        $runtime.GuestSqlDataDir | Should -Be 'F:\Data'
        $runtime.GuestSqlLogDir | Should -Be 'F:\Log'
    }

    It "connects SQL work to '<Server>' for the instance '<Instance>'" -ForEach @(
        @{ Instance = 'MSSQLSERVER'; Server = 'localhost' }
        @{ Instance = 'DEV'; Server = 'localhost\DEV' }
    ) {
        InModuleScope $module -Parameters @{ Settings = $settings; Instance = $Instance } {
            param($Settings, $Instance)
            $vm = [VMContext]::new($Settings)
            $vm.SetSqlInstance($Instance)
            $vm.Runtime.SqlServer
        } | Should -Be $Server
    }
}

Describe 'Initialize-CommandRun' {
    It 'returns the context of the VM named, and leaves another VM''s settings alone' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }'; Beta = '{ "vCPU": 6 }' }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Resolve-LazyVMRoot { [pscustomobject]@{ Path = $Root; Source = 'a test' } }.GetNewClosure()
            Mock Start-Log {}
            Mock Write-LogEntry {}
            Mock Sync-GuestUserFromStore {}

            $alpha = Initialize-CommandRun -Title 'A test' -Name 'Alpha'
            $beta = Initialize-CommandRun -Title 'A test' -Name 'Beta'

            $alpha | Should -BeOfType ([VMContext])
            $alpha.Name | Should -Be 'Alpha'
            $alpha.Settings.vCPU | Should -Be 2
            $beta.Settings.vCPU | Should -Be 6
            $alpha.Settings.LogFile | Should -Be "$Root\Alpha\Logs\Alpha.log"
            Should -Invoke Start-Log -Times 1 -ParameterFilter { $Path -like '*\Logs\Alpha.log' }
        }
    }

    It 'folds an older VM''s Tooling.json into VM.json before the run uses it' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/Tooling.json') -Value $toolingJson

        $wingetIds = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Resolve-LazyVMRoot { [pscustomobject]@{ Path = $Root; Source = 'a test' } }.GetNewClosure()
            Mock Start-Log {}
            Mock Write-LogEntry {}
            Mock Sync-GuestUserFromStore {}
            Mock Get-ToolingCheckpointStamp { , @() }

            $vm = Initialize-CommandRun -Title 'A test' -Name 'Alpha'
            $vm.Settings.ProfileDir | Should -Be "$Root\Alpha\Config"
            @($vm.Settings.Tooling.WingetPackages | ForEach-Object { $_.Id })
        }

        $wingetIds | Should -Be @('Git.Git')
        Join-Path -Path $root -ChildPath 'Alpha/Config/Tooling.json' | Should -Not -Exist
    }

    It 'with -RecordHardware, records what Hyper-V says before the run uses the settings' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }

        $vCPU = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $rootFolder = [pscustomobject]@{ Path = $Root; Source = 'a test' }
            Mock Resolve-LazyVMRoot { $rootFolder }.GetNewClosure()
            Mock Start-Log {}
            Mock Write-LogEntry {}
            Mock Sync-GuestUserFromStore {}
            Mock Get-ToolingCheckpointStamp { , @() }
            Mock Get-VMHardware { [pscustomobject]@{ ProcessorCount = 6; DynamicMemoryEnabled = $true; StartupBytes = 8GB; MinimumBytes = 2GB; MaximumBytes = 16GB; SwitchNames = @('Default Switch'); DiskBytes = @{} } }

            (Initialize-CommandRun -Title 'A test' -Name 'Alpha' -RecordHardware).Settings.vCPU
        }

        $vCPU | Should -Be 6
        (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')).vCPU | Should -Be 6
    }

    It 'without -RecordHardware, does not ask Hyper-V' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 2 }' }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $rootFolder = [pscustomobject]@{ Path = $Root; Source = 'a test' }
            Mock Resolve-LazyVMRoot { $rootFolder }.GetNewClosure()
            Mock Start-Log {}
            Mock Write-LogEntry {}
            Mock Sync-GuestUserFromStore {}
            Mock Save-VMHardware { $true }

            $null = Initialize-CommandRun -Title 'A test' -Name 'Alpha'

            Should -Invoke Save-VMHardware -Times 0
        }
    }
}

Describe 'Get-HardwareChange (#6)' {
    BeforeAll {
        function New-TestHardware {
            <# What Hyper-V reports for a VM configured exactly as the default settings say. #>
            [pscustomobject]@{
                ProcessorCount       = 4
                DynamicMemoryEnabled = $true
                StartupBytes         = 8GB
                MinimumBytes         = 2GB
                MaximumBytes         = 16GB
                SwitchNames          = @('Default Switch')
                DiskBytes            = @{ OSDiskSizeGB = 120GB; SQLDiskSizeGB = 100GB; DevDriveSizeGB = 250GB }
            }
        }
        $settings = @{ vCPU = 4; MemStartGB = 8; MemMinGB = 2; MemMaxGB = 16; OSDiskSizeGB = 120; SQLDiskSizeGB = 100; DevDriveSizeGB = 250; SwitchName = 'Default Switch'; NatSwitchName = 'LazyVM-NAT' }
    }

    It 'finds nothing when Hyper-V matches the settings' {
        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = (New-TestHardware) } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'reports each changed processor, memory and disk setting with its old and new value' {
        $hardware = New-TestHardware
        $hardware.ProcessorCount = 8
        $hardware.MaximumBytes = 24GB
        $hardware.DiskBytes.OSDiskSizeGB = 200GB

        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = $hardware } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        $changes | ForEach-Object { "$($_.Setting) $($_.Old)->$($_.New) $($_.Recordable)" } |
            Should -Be @('vCPU 4->8 True', 'MemMaxGB 16->24 True', 'OSDiskSizeGB 120->200 True')
    }

    It 'ignores minimum and maximum memory while dynamic memory is off' {
        $hardware = New-TestHardware
        $hardware.DynamicMemoryEnabled = $false
        $hardware.MinimumBytes = 512MB
        $hardware.MaximumBytes = 1TB

        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = $hardware } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'marks a size that is not a whole number of GB as not recordable' {
        $hardware = New-TestHardware
        $hardware.StartupBytes = 6GB + 512MB

        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = $hardware } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        $changes.Setting | Should -Be 'MemStartGB'
        $changes.New | Should -Be 6.5
        $changes.Recordable | Should -BeFalse
    }

    It 'leaves a disk alone when it does not exist' {
        $hardware = New-TestHardware
        $hardware.DiskBytes = @{ OSDiskSizeGB = 120GB }

        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = $hardware } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'reports the switch the VM was moved to' {
        $hardware = New-TestHardware
        $hardware.SwitchNames = @('External')

        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = $hardware } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        "$($changes.Setting) $($changes.Old)->$($changes.New)" | Should -Be 'SwitchName Default Switch->External'
    }

    It 'leaves the switch alone when the VM is on the NAT fallback, has no adapter or has several' -TestCases @(
        @{ Switches = @('LazyVM-NAT') }
        @{ Switches = @() }
        @{ Switches = @('External', 'Internal') }
    ) {
        param($Switches)
        $hardware = New-TestHardware
        $hardware.SwitchNames = $Switches

        $changes = InModuleScope $module -Parameters @{ Settings = $settings; Hardware = $hardware } {
            param($Settings, $Hardware)
            @(Get-HardwareChange -Settings $Settings -Hardware $Hardware)
        }

        $changes | Should -BeNullOrEmpty
    }
}

Describe 'Save-VMHardware (#6)' {
    BeforeAll {
        function Invoke-TestSave {
            <# Runs Save-VMHardware for Alpha under $Root, with Hyper-V reporting $Hardware. #>
            param([string]$Root, [AllowNull()][object]$Hardware)

            InModuleScope $module -Parameters @{ Root = $Root; Hardware = $Hardware } {
                param($Root, $Hardware)
                Mock Write-LogEntry {}
                Mock Write-LogError {}
                Mock Get-ToolingCheckpointStamp { , @() }
                $reported = $Hardware
                Mock Get-VMHardware { $reported }.GetNewClosure()
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Save-VMHardware -VM $vm
            }
        }
        $profileJson = '{ "vCPU": 4, "MemStartGB": 8, "MemMinGB": 2, "MemMaxGB": 16, "OSDiskSizeGB": 120, "SwitchName": "Default Switch" }'
        function New-TestHardware {
            param([int]$ProcessorCount = 4, [long]$OSDiskBytes = 120GB)
            [pscustomobject]@{ ProcessorCount = $ProcessorCount; DynamicMemoryEnabled = $true; StartupBytes = 8GB; MinimumBytes = 2GB; MaximumBytes = 16GB; SwitchNames = @('Default Switch'); DiskBytes = @{ OSDiskSizeGB = $OSDiskBytes } }
        }
    }

    It 'records a change made in Hyper-V in VM.json and says so' {
        $root = New-TestRoot -Profiles @{ Alpha = $profileJson }

        $saved = Invoke-TestSave -Root $root -Hardware (New-TestHardware -ProcessorCount 8 -OSDiskBytes 160GB)

        $saved | Should -BeTrue
        $vmProfile = Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')
        $vmProfile.vCPU | Should -Be 8
        $vmProfile.OSDiskSizeGB | Should -Be 160
    }

    It 'writes nothing when Hyper-V matches VM.json' {
        $root = New-TestRoot -Profiles @{ Alpha = $profileJson }

        $saved = Invoke-TestSave -Root $root -Hardware (New-TestHardware)

        $saved | Should -BeFalse
        Join-Path -Path $root -ChildPath 'Alpha/Config/History' | Should -Not -Exist
    }

    It 'writes nothing when the VM does not exist in Hyper-V' {
        $root = New-TestRoot -Profiles @{ Alpha = $profileJson }

        $saved = Invoke-TestSave -Root $root -Hardware $null

        $saved | Should -BeFalse
        Join-Path -Path $root -ChildPath 'Alpha/Config/History' | Should -Not -Exist
    }

    It 'leaves VM.json as it was, without failing, when the schema refuses a value' {
        $root = New-TestRoot -Profiles @{ Alpha = $profileJson }
        $path = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json'
        $before = Get-Content -LiteralPath $path -Raw

        $saved = Invoke-TestSave -Root $root -Hardware (New-TestHardware -ProcessorCount 8 -OSDiskBytes 32GB)

        $saved | Should -BeFalse
        Get-Content -LiteralPath $path -Raw | Should -Be $before
    }
}

Describe 'Test-SecretVariableName (#131)' {
    It 'treats <Name> as secret' -ForEach @(
        @{ Name = 'GITHUB_TOKEN' }, @{ Name = 'OPENAI_API_KEY' }, @{ Name = 'DB_PASSWORD' }, @{ Name = 'AZURE_CLIENT_SECRET' }
        @{ Name = 'ADO_PAT' }, @{ Name = 'Sql_ConnectionString' }, @{ Name = 'MyApiKey' }, @{ Name = 'NUGET_CREDENTIALS' }
        @{ Name = 'AccessKey' }, @{ Name = 'PrivateKey' }, @{ Name = 'EncryptionKey' }, @{ Name = 'Passphrase' }, @{ Name = 'UserPwd' }, @{ Name = 'GitPat' }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } { param($Name) Test-SecretVariableName -Name $Name } | Should -BeTrue
    }

    It 'does not treat <Name> as secret' -ForEach @(
        @{ Name = 'JAVA_HOME' }, @{ Name = 'PATHEXT' }, @{ Name = 'KEYBOARD_LAYOUT' }, @{ Name = 'DOTNET_ROOT' }, @{ Name = 'MONKEY' }
        @{ Name = 'KeyboardLayout' }, @{ Name = 'RecentPaths' }, @{ Name = 'FilePattern' }, @{ Name = 'Keys' }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } { param($Name) Test-SecretVariableName -Name $Name } | Should -BeFalse
    }
}

Describe 'ConvertTo-GuestEnvironmentRecord (#131)' {
    BeforeAll {
        function Invoke-TestConvert {
            param([Parameter(Mandatory)][hashtable]$Snapshot)
            InModuleScope $module -Parameters @{ Snapshot = $Snapshot } {
                param($Snapshot)
                ConvertTo-GuestEnvironmentRecord -Snapshot $Snapshot
            }
        }
        function New-TestSnapshot {
            @{
                Machine      = @{ JAVA_HOME = 'C:\Java'; GITHUB_TOKEN = 'ghp_secret'; ComSpec = 'C:\Windows\system32\cmd.exe'; NUMBER_OF_PROCESSORS = '4' }
                User         = @{ EDITOR = 'code'; OPENAI_API_KEY = 'sk-secret'; TEMP = 'C:\Users\x\Temp' }
                MachinePath  = @('C:\Windows\system32', 'C:\Tools')
                UserPath     = @('C:\Users\x\bin')
                Hosts        = @('127.0.0.1 api.local')
                MappedDrives = @([pscustomobject]@{ Letter = 'Z:'; Path = '\\server\share' })
            }
        }
    }

    It 'keeps the variables a user set, leaving out those Windows sets itself' {
        $result = Invoke-TestConvert -Snapshot (New-TestSnapshot)

        @($result.Record.MachineVariables.Keys) | Should -Be @('JAVA_HOME')
        @($result.Record.UserVariables.Keys) | Should -Be @('EDITOR')
    }

    It 'lists a secret variable by name only, and returns its value apart' {
        $result = Invoke-TestConvert -Snapshot (New-TestSnapshot)

        $result.Record.SecretVariables | ForEach-Object { "$($_.Scope)\$($_.Name)" } | Should -Be @('Machine\GITHUB_TOKEN', 'User\OPENAI_API_KEY')
        $result.Secrets['Machine\GITHUB_TOKEN'] | Should -Be 'ghp_secret'
        $result.Secrets['User\OPENAI_API_KEY'] | Should -Be 'sk-secret'
        ConvertTo-Json -InputObject $result.Record -Depth 10 | Should -Not -Match 'ghp_secret|sk-secret'
    }

    It 'keeps PATH, the hosts entries and the mapped drives as they are' {
        $result = Invoke-TestConvert -Snapshot (New-TestSnapshot)

        $result.Record.MachinePath | Should -Be @('C:\Windows\system32', 'C:\Tools')
        $result.Record.UserPath | Should -Be @('C:\Users\x\bin')
        $result.Record.Hosts | Should -Be @('127.0.0.1 api.local')
        "$($result.Record.MappedDrives[0].Letter) $($result.Record.MappedDrives[0].Path)" | Should -Be 'Z: \\server\share'
    }
}

Describe 'Update-GuestEnvironmentRecord (#131)' {
    BeforeAll {
        function Invoke-TestRecord {
            <# Records Alpha's guest environment under $Root, with the guest reporting $Snapshot. Returns whether anything changed. #>
            param([string]$Root, [hashtable]$Snapshot)

            InModuleScope $module -Parameters @{ Root = $Root; Snapshot = $Snapshot } {
                param($Root, $Snapshot)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                $reported = $Snapshot
                Mock Get-GuestEnvironmentSnapshot { $reported }.GetNewClosure()
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Update-GuestEnvironmentRecord -VM $vm
            }
        }
        function New-TestEnvironmentRoot {
            <# A root with Alpha and a credential key, as a VM LazyVM built has. #>
            $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
            $keyDir = Join-Path -Path $root -ChildPath 'Shared/Credentials'
            New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
            $key = [byte[]]::new(32)
            [Security.Cryptography.RandomNumberGenerator]::Fill($key)
            [IO.File]::WriteAllBytes((Join-Path -Path $keyDir -ChildPath '.lazyvm.key'), $key)
            return $root
        }
        function New-TestSnapshot {
            param([hashtable]$Machine = @{ JAVA_HOME = 'C:\Java'; GITHUB_TOKEN = 'ghp_secret' })
            @{ Machine = $Machine; User = @{}; MachinePath = @('C:\Tools'); UserPath = @(); Hosts = @(); MappedDrives = @() }
        }
        function Read-TestSecret {
            param([string]$Root)
            InModuleScope $module -Parameters @{ Root = $Root } {
                param($Root)
                Read-GuestEnvironmentSecret -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        }
    }

    It 'writes the environment into VM.json and the secret values into the encrypted store' {
        $root = New-TestEnvironmentRoot

        $changed = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed | Should -BeTrue
        $path = Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json'
        (Read-TestJson -Path $path).GuestEnvironment.MachineVariables.JAVA_HOME | Should -Be 'C:\Java'
        Get-Content -LiteralPath $path -Raw | Should -Not -Match 'ghp_secret'
        Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Credentials/environment.cred') -Raw | Should -Not -Match 'ghp_secret'
        (Read-TestSecret -Root $root)['Machine\GITHUB_TOKEN'] | Should -Be 'ghp_secret'
    }

    It 'writes nothing the second time, when nothing changed' {
        $root = New-TestEnvironmentRoot
        $null = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json').Count | Should -Be 1
    }

    It 'records a variable that was removed, and its secret value with it' {
        $root = New-TestEnvironmentRoot
        $null = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot -Machine @{ JAVA_HOME = 'C:\Java' })

        $changed | Should -BeTrue
        (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')).GuestEnvironment.SecretVariables | Should -BeNullOrEmpty
        (Read-TestSecret -Root $root).Count | Should -Be 0
    }
}

Describe 'Get-GuestEnvironmentRestore (#131)' {
    It 'returns nothing for a VM whose environment was never recorded, so an older capture is used' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Get-GuestEnvironmentRestore -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
        } | Should -BeNullOrEmpty
    }

    It 'returns what VM.json holds now, not what the run started with' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $restore = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Get-ToolingCheckpointStamp { , @() }
            $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
            $record = @{ MachineVariables = @{ JAVA_HOME = 'C:\Java' }; UserVariables = @{}; SecretVariables = @(); MachinePath = @(); UserPath = @(); Hosts = @(); MappedDrives = @() }
            $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestEnvironment = $record } -Reason 'a test'
            Get-GuestEnvironmentRestore -VM $vm
        }

        $restore.Record.MachineVariables.JAVA_HOME | Should -Be 'C:\Java'
        $restore.Secrets.Count | Should -Be 0
    }
}

Describe 'ConvertTo-GuestFirewallRecord (#131)' {
    BeforeAll {
        function Invoke-TestConvert {
            param([object[]]$Snapshot)
            InModuleScope $module -Parameters @{ Snapshot = $Snapshot } {
                param($Snapshot)
                ConvertTo-GuestFirewallRecord -Snapshot $Snapshot
            }
        }
    }

    It 'keeps each rule, sorted by name, with its ports and addresses as lists' {
        $snapshot = @(
            [pscustomobject]@{ DisplayName = 'Web'; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = @('80', '443'); RemoteAddress = 'Any'; Profile = 'Any' }
            [pscustomobject]@{ DisplayName = 'Api'; Direction = 'Outbound'; Action = 'Block'; Protocol = 'UDP'; LocalPort = '5000'; RemoteAddress = @('10.0.0.0/8'); Profile = 'Domain, Private' }
        )

        $record = @(Invoke-TestConvert -Snapshot $snapshot)

        $record.DisplayName | Should -Be @('Api', 'Web')
        "$($record[0].Direction) $($record[0].Action) $($record[0].Protocol) $($record[0].Profile)" | Should -Be 'Outbound Block UDP Domain, Private'
        @($record[0].LocalPort, $record[1].LocalPort, $record[1].RemoteAddress | ForEach-Object { $_.GetType().IsArray }) | Should -Be @($true, $true, $true)
        $record[0].LocalPort -join ',' | Should -Be '5000'
        $record[1].LocalPort -join ',' | Should -Be '80,443'
        $record[1].RemoteAddress -join ',' | Should -Be 'Any'
    }

    It 'returns an empty list when the guest has no rules of its own' {
        $record = @(Invoke-TestConvert -Snapshot @())

        $record.Count | Should -Be 0
    }
}

Describe 'Update-GuestFirewallRecord (#131)' {
    BeforeAll {
        function Invoke-TestRecord {
            <# Records Alpha's firewall rules under $Root, with the guest reporting $Snapshot. Returns whether anything changed. #>
            param([string]$Root, [object[]]$Snapshot)

            InModuleScope $module -Parameters @{ Root = $Root; Snapshot = $Snapshot } {
                param($Root, $Snapshot)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                $reported = $Snapshot
                Mock Get-GuestFirewallSnapshot { $reported }.GetNewClosure()
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Update-GuestFirewallRecord -VM $vm
            }
        }
        function New-TestRule {
            param([string]$Name = 'Dev API')
            [pscustomobject]@{ DisplayName = $Name; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = @('5000'); RemoteAddress = @('Any'); Profile = 'Any' }
        }
    }

    It 'writes the rules into VM.json' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $changed = Invoke-TestRecord -Root $root -Snapshot @(New-TestRule)

        $changed | Should -BeTrue
        (Read-TestJson -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')).GuestFirewallRules[0].DisplayName | Should -Be 'Dev API'
    }

    It 'writes nothing the second time, when nothing changed' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Snapshot @(New-TestRule)

        $changed = Invoke-TestRecord -Root $root -Snapshot @(New-TestRule)

        $changed | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json').Count | Should -Be 1
    }

    It 'records a rule that was removed as an empty list, not as never recorded' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Snapshot @(New-TestRule)

        $changed = Invoke-TestRecord -Root $root -Snapshot @()

        $changed | Should -BeTrue
        $text = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json') -Raw
        $text | Should -Match '"GuestFirewallRules":\s*\[\s*\]'
    }
}

Describe 'Get-GuestFirewallRestore (#131)' {
    BeforeAll {
        function Invoke-TestRestore {
            <# What a restore of Alpha under $Root would put back, after VM.json records $Rules (unless it is $null). #>
            param([string]$Root, [object[]]$Rules)

            InModuleScope $module -Parameters @{ Root = $Root; Rules = $Rules } {
                param($Root, $Rules)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                if ($null -ne $Rules) { $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestFirewallRules = $Rules } -Reason 'a test' }
                Get-GuestFirewallRestore -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        }
    }

    It 'returns nothing for a VM whose rules were never recorded, so an older capture is used' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        Invoke-TestRestore -Root $root -Rules $null | Should -BeNullOrEmpty
    }

    It 'returns an empty list, not nothing, when the guest was recorded with no rules' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $restore = Invoke-TestRestore -Root $root -Rules @()

        $restore | Should -Not -BeNullOrEmpty
        @($restore.Rules).Count | Should -Be 0
    }

    It 'returns the rules VM.json holds now' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $rule = [ordered]@{ DisplayName = 'Dev API'; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = @('5000'); RemoteAddress = @('Any'); Profile = 'Any' }

        $restore = Invoke-TestRestore -Root $root -Rules @($rule)

        @($restore.Rules).DisplayName | Should -Be @('Dev API')
    }
}

Describe 'ConvertTo-GuestScheduledTaskRecord (#131)' {
    It 'keeps each task by name and XML, sorted by name' {
        $tasks = @(
            [pscustomobject]@{ Name = 'Sync'; Xml = '<Task>sync</Task>' }
            [pscustomobject]@{ Name = 'Backup'; Xml = '<Task>backup</Task>' }
        )

        $record = @(InModuleScope $module -Parameters @{ Tasks = $tasks } { param($Tasks) ConvertTo-GuestScheduledTaskRecord -Task $Tasks })

        $record.Name | Should -Be @('Backup', 'Sync')
        $record[0].Xml | Should -Be '<Task>backup</Task>'
    }
}

Describe 'Update-GuestScheduledTaskRecord (#131)' {
    BeforeAll {
        function Invoke-TestRecord {
            <# Records Alpha's scheduled tasks under $Root, with the guest exporting $Tasks and failing on $Failed. Returns whether anything changed. #>
            param([string]$Root, [object[]]$Tasks, [string[]]$Failed = @())

            InModuleScope $module -Parameters @{ Root = $Root; Tasks = $Tasks; Failed = $Failed } {
                param($Root, $Tasks, $Failed)
                Mock Write-LogEntry {}
                Mock Write-GuestNote {}
                Mock Get-ToolingCheckpointStamp { , @() }
                $reported = [pscustomobject]@{ Tasks = @($Tasks); Failed = @($Failed); Notes = @() }
                Mock Get-GuestScheduledTaskSnapshot { $reported }.GetNewClosure()
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Update-GuestScheduledTaskRecord -VM $vm
            }
        }
        function New-TestTask {
            param([string]$Name = 'Nightly build', [string]$Xml = '<?xml version="1.0"?><Task>build</Task>')
            [pscustomobject]@{ Name = $Name; Xml = $Xml }
        }
        function Get-TestRecordedTask {
            param([string]$Root)
            @((Read-TestJson -Path (Join-Path -Path $Root -ChildPath 'Alpha/Config/VM.json')).GuestScheduledTasks)
        }
    }

    It 'writes the tasks into VM.json' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $changed = Invoke-TestRecord -Root $root -Tasks @(New-TestTask)

        $changed | Should -BeTrue
        (Get-TestRecordedTask -Root $root).Name | Should -Be @('Nightly build')
    }

    It 'writes nothing the second time, when nothing changed' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Tasks @(New-TestTask)

        $changed = Invoke-TestRecord -Root $root -Tasks @(New-TestTask)

        $changed | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json').Count | Should -Be 1
    }

    It 'records a task that was removed' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Tasks @((New-TestTask), (New-TestTask -Name 'Sync'))

        $changed = Invoke-TestRecord -Root $root -Tasks @(New-TestTask -Name 'Sync')

        $changed | Should -BeTrue
        (Get-TestRecordedTask -Root $root).Name | Should -Be @('Sync')
    }

    It 'keeps what it had for a task that could not be exported this time' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Tasks @(New-TestTask)

        $changed = Invoke-TestRecord -Root $root -Tasks @() -Failed @('Nightly build')

        $changed | Should -BeFalse
        (Get-TestRecordedTask -Root $root).Xml | Should -Be @('<?xml version="1.0"?><Task>build</Task>')
    }
}

Describe 'Get-GuestScheduledTaskRestore (#131)' {
    BeforeAll {
        function Invoke-TestRestore {
            <# What a restore of Alpha under $Root would put back, after VM.json records $Tasks (unless it is $null). #>
            param([string]$Root, [object[]]$Tasks)

            InModuleScope $module -Parameters @{ Root = $Root; Tasks = $Tasks } {
                param($Root, $Tasks)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                if ($null -ne $Tasks) { $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestScheduledTasks = $Tasks } -Reason 'a test' }
                Get-GuestScheduledTaskRestore -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        }
    }

    It 'returns nothing for a VM whose tasks were never recorded, so an older capture is used' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        Invoke-TestRestore -Root $root -Tasks $null | Should -BeNullOrEmpty
    }

    It 'returns an empty list, not nothing, when the guest was recorded with no tasks' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $restore = Invoke-TestRestore -Root $root -Tasks @()

        $restore | Should -Not -BeNullOrEmpty
        @($restore.Tasks).Count | Should -Be 0
    }

    It 'returns the tasks VM.json holds now' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $restore = Invoke-TestRestore -Root $root -Tasks @([ordered]@{ Name = 'Nightly build'; Xml = '<Task />' })

        @($restore.Tasks).Name | Should -Be @('Nightly build')
    }
}

Describe 'ConvertTo-GuestAppSettingRecord (#131)' {
    BeforeAll {
        function Invoke-TestConvert {
            param([object[]]$Key)
            InModuleScope $module -Parameters @{ Key = $Key } {
                param($Key)
                ConvertTo-GuestAppSettingRecord -Key $Key
            }
        }
        function New-TestKey {
            [pscustomobject]@{
                Name        = 'WinMerge'
                RegistryKey = 'HKCU\Software\WinMerge'
                Values      = @(
                    [pscustomobject]@{ Path = 'Settings'; Name = 'Font'; Kind = 'String'; Data = 'Consolas' }
                    [pscustomobject]@{ Path = ''; Name = 'SyncPassword'; Kind = 'String'; Data = 'hunter2' }
                    [pscustomobject]@{ Path = ''; Name = 'Size'; Kind = 'DWord'; Data = 12 }
                )
            }
        }
    }

    It 'keeps each value by path and name, sorted' {
        $result = Invoke-TestConvert -Key @(New-TestKey)

        @($result.Record).Name | Should -Be @('WinMerge')
        $result.Record[0].Values | ForEach-Object { "$($_.Path)\$($_.Name)=$($_.Data)" } | Should -Be @('\Size=12', 'Settings\Font=Consolas')
    }

    It 'lists a secret value by name only, and returns its data apart' {
        $result = Invoke-TestConvert -Key @(New-TestKey)

        $result.Record[0].SecretValues | ForEach-Object { "$($_.Path)\$($_.Name)" } | Should -Be @('\SyncPassword')
        $result.Secrets['WinMerge\\SyncPassword'].Data | Should -Be 'hunter2'
        $result.Secrets['WinMerge\\SyncPassword'].Kind | Should -Be 'String'
        ConvertTo-Json -InputObject $result.Record -Depth 10 | Should -Not -Match 'hunter2'
    }
}

Describe 'Update-GuestAppSettingRecord (#131)' {
    BeforeAll {
        function Invoke-TestRecord {
            <# Records Alpha's application settings under $Root, with the guest reading $Keys and failing on $Failed. Returns whether anything changed. #>
            param([string]$Root, [object[]]$Keys, [string[]]$Failed = @())

            InModuleScope $module -Parameters @{ Root = $Root; Keys = $Keys; Failed = $Failed } {
                param($Root, $Keys, $Failed)
                Mock Write-LogEntry {}
                Mock Write-GuestNote {}
                Mock Get-ToolingCheckpointStamp { , @() }
                $reported = [pscustomobject]@{ Keys = @($Keys); Failed = @($Failed); Notes = @() }
                Mock Get-GuestAppSettingSnapshot { $reported }.GetNewClosure()
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Update-GuestAppSettingRecord -VM $vm
            }
        }
        function New-TestAppSettingRoot {
            <# A root with Alpha and a credential key, as a VM LazyVM built has. #>
            $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
            $keyDir = Join-Path -Path $root -ChildPath 'Shared/Credentials'
            New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
            $key = [byte[]]::new(32)
            [Security.Cryptography.RandomNumberGenerator]::Fill($key)
            [IO.File]::WriteAllBytes((Join-Path -Path $keyDir -ChildPath '.lazyvm.key'), $key)
            return $root
        }
        function New-TestKey {
            param([string]$Name = 'WinMerge', [string]$Font = 'Consolas', [switch]$WithSecret)
            $values = @([pscustomobject]@{ Path = ''; Name = 'Font'; Kind = 'String'; Data = $Font })
            if ($WithSecret) { $values += [pscustomobject]@{ Path = ''; Name = 'SyncPassword'; Kind = 'String'; Data = 'hunter2' } }
            [pscustomobject]@{ Name = $Name; RegistryKey = "HKCU\Software\Thingamahoochie\$Name"; Values = $values }
        }
        function Get-TestRecordedKey {
            param([string]$Root)
            @((Read-TestJson -Path (Join-Path -Path $Root -ChildPath 'Alpha/Config/VM.json')).GuestAppSettings)
        }
        function Read-TestSecret {
            param([string]$Root)
            InModuleScope $module -Parameters @{ Root = $Root } {
                param($Root)
                Read-GuestAppSettingSecret -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        }
    }

    It 'writes the values into VM.json and the secret ones into the encrypted store' {
        $root = New-TestAppSettingRoot

        $changed = Invoke-TestRecord -Root $root -Keys @(New-TestKey -WithSecret)

        $changed | Should -BeTrue
        (Get-TestRecordedKey -Root $root).Values.Data | Should -Be @('Consolas')
        Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json') -Raw | Should -Not -Match 'hunter2'
        Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Credentials/appsettings.cred') -Raw | Should -Not -Match 'hunter2'
        (Read-TestSecret -Root $root)['WinMerge\\SyncPassword'].Data | Should -Be 'hunter2'
    }

    It 'writes nothing the second time, when nothing changed' {
        $root = New-TestAppSettingRoot
        $null = Invoke-TestRecord -Root $root -Keys @(New-TestKey -WithSecret)

        $changed = Invoke-TestRecord -Root $root -Keys @(New-TestKey -WithSecret)

        $changed | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json').Count | Should -Be 1
    }

    It 'records a key that is gone, and its secret values with it' {
        $root = New-TestAppSettingRoot
        $null = Invoke-TestRecord -Root $root -Keys @(New-TestKey -WithSecret)

        $changed = Invoke-TestRecord -Root $root -Keys @()

        $changed | Should -BeTrue
        $text = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json') -Raw
        $text | Should -Match '"GuestAppSettings":\s*\[\s*\]'
        (Read-TestSecret -Root $root).Count | Should -Be 0
    }

    It 'keeps what it had for a key that could not be read this time, secrets included' {
        $root = New-TestAppSettingRoot
        $null = Invoke-TestRecord -Root $root -Keys @(New-TestKey -WithSecret)

        $changed = Invoke-TestRecord -Root $root -Keys @() -Failed @('WinMerge')

        $changed | Should -BeFalse
        (Get-TestRecordedKey -Root $root).Values.Data | Should -Be @('Consolas')
        (Read-TestSecret -Root $root)['WinMerge\\SyncPassword'].Data | Should -Be 'hunter2'
    }
}

Describe 'Get-GuestAppSettingRestore (#131)' {
    BeforeAll {
        function Invoke-TestRestore {
            <# What a restore of Alpha under $Root would put back, after VM.json records $Keys (unless it is $null). #>
            param([string]$Root, [object[]]$Keys)

            InModuleScope $module -Parameters @{ Root = $Root; Keys = $Keys } {
                param($Root, $Keys)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                if ($null -ne $Keys) { $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestAppSettings = $Keys } -Reason 'a test' }
                Get-GuestAppSettingRestore -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        }
    }

    It 'returns nothing for a VM whose settings were never recorded, so an older capture is used' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        Invoke-TestRestore -Root $root -Keys $null | Should -BeNullOrEmpty
    }

    It 'returns an empty list, not nothing, when the guest was recorded with no settings' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $restore = Invoke-TestRestore -Root $root -Keys @()

        $restore | Should -Not -BeNullOrEmpty
        @($restore.Keys).Count | Should -Be 0
        $restore.Secrets.Count | Should -Be 0
    }

    It 'returns the keys VM.json holds now' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $key = [ordered]@{ Name = 'WinMerge'; RegistryKey = 'HKCU\Software\Thingamahoochie\WinMerge'; Values = @([ordered]@{ Path = ''; Name = 'Font'; Kind = 'String'; Data = 'Consolas' }); SecretValues = @() }

        $restore = Invoke-TestRestore -Root $root -Keys @($key)

        @($restore.Keys).Name | Should -Be @('WinMerge')
    }

    It 'leaves out a recorded key that AppSettings does not list, so a guest cannot plant other keys' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $listed = [ordered]@{ Name = 'WinMerge'; RegistryKey = 'HKCU\software\thingamahoochie\winmerge'; Values = @(); SecretValues = @() }
        $planted = [ordered]@{ Name = 'Run'; RegistryKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Values = @([ordered]@{ Path = ''; Name = 'x'; Kind = 'String'; Data = 'evil.exe' }); SecretValues = @() }

        $restore = Invoke-TestRestore -Root $root -Keys @($listed, $planted)

        @($restore.Keys).Name | Should -Be @('WinMerge')
    }
}

Describe 'ConvertTo-GuestSqlRecord (#131)' {
    It 'keeps instance settings and logins sorted by name, with whole-number values and sorted roles' {
        $snapshot = [pscustomobject]@{
            Configs = @(
                [pscustomobject]@{ Name = 'remote access'; Value = '1' }
                [pscustomobject]@{ Name = 'max server memory (MB)'; Value = '4096' }
            )
            Logins  = @(
                [pscustomobject]@{ Name = 'app'; TypeDesc = 'SQL_LOGIN'; IsDisabled = $false; DefaultDb = 'master'; DefaultLang = 'us_english'; SidHex = '0x1A'; HashHex = '0x02'; PolicyChecked = $true; ExpirationChecked = $false; ServerRoles = @('sysadmin', 'dbcreator') }
                [pscustomobject]@{ Name = 'DEV\sean'; TypeDesc = 'WINDOWS_LOGIN'; IsDisabled = $false; DefaultDb = 'master'; DefaultLang = 'us_english'; SidHex = '0x0105'; HashHex = $null; PolicyChecked = $false; ExpirationChecked = $false; ServerRoles = 'sysadmin' }
            )
            Databases = @()
        }

        $record = InModuleScope $module -Parameters @{ Snapshot = $snapshot } { param($Snapshot) ConvertTo-GuestSqlRecord -Snapshot $Snapshot }

        @($record.Configs).Name | Should -Be @('max server memory (MB)', 'remote access')
        $record.Configs[0].Value | Should -BeOfType [long]
        @($record.Logins).Name | Should -Be @('app', 'DEV\sean')
        $record.Logins[0].ServerRoles | Should -Be @('dbcreator', 'sysadmin')
        $record.Logins[1].ServerRoles.GetType().IsArray | Should -BeTrue
        $record.Logins[1].HashHex | Should -Be ''
    }

    It 'keeps the user databases sorted by name, each with its files in file order, so a rebuild can attach them (#132)' {
        $snapshot = [pscustomobject]@{
            Configs   = @()
            Logins    = @()
            Databases = @(
                [pscustomobject]@{ Name = 'Sales'; Files = @('S:\SQLData\Sales.mdf', 'S:\SQLLog\Sales_log.ldf') }
                [pscustomobject]@{ Name = 'Hr'; Files = 'S:\SQLData\Hr.mdf' }
            )
        }

        $record = InModuleScope $module -Parameters @{ Snapshot = $snapshot } { param($Snapshot) ConvertTo-GuestSqlRecord -Snapshot $Snapshot }

        @($record.Databases).Name | Should -Be @('Hr', 'Sales')
        $record.Databases[1].Files | Should -Be @('S:\SQLData\Sales.mdf', 'S:\SQLLog\Sales_log.ldf')
        $record.Databases[0].Files.GetType().IsArray | Should -BeTrue
    }
}

Describe 'ConvertTo-GuestSqlAgentRecord (#131)' {
    It 'keeps operators, jobs and alerts sorted by name, steps in step order, and numbers as whole numbers' {
        $snapshot = [pscustomobject]@{
            Operators = @(
                [pscustomobject]@{ Name = 'Ops'; Enabled = $true; EmailAddress = $null; Category = '[Uncategorized]' }
                [pscustomobject]@{ Name = 'Dev team'; Enabled = $false; EmailAddress = 'dev@example.com'; Category = '[Uncategorized]' }
            )
            Jobs      = @(
                [pscustomobject]@{
                    Name = 'Nightly ETL'; Enabled = $true; Description = $null; Category = '[Uncategorized (Local)]'; Owner = 'DEV\sean'
                    StartStepId = '1'; NotifyLevelEventLog = '2'; NotifyLevelEmail = '0'; NotifyEmailOperator = $null; DeleteLevel = '0'
                    Steps = @(
                        [pscustomobject]@{ Id = '2'; Name = 'Report'; Subsystem = 'TSQL'; Command = 'EXEC dbo.Report'; Database = 'Sales'; OnSuccessAction = '1'; OnSuccessStepId = '0'; OnFailAction = '2'; OnFailStepId = '0'; RetryAttempts = '0'; RetryInterval = '0'; OutputFile = $null; Flags = '0'; Proxy = $null }
                        [pscustomobject]@{ Id = '1'; Name = 'Load'; Subsystem = 'TSQL'; Command = 'EXEC dbo.Load'; Database = 'Sales'; OnSuccessAction = '3'; OnSuccessStepId = '0'; OnFailAction = '2'; OnFailStepId = '0'; RetryAttempts = '1'; RetryInterval = '5'; OutputFile = $null; Flags = '0'; Proxy = $null }
                    )
                    Schedules = @([pscustomobject]@{ Name = 'Nightly'; Enabled = $true; FreqType = '4'; FreqInterval = '1'; FreqSubdayType = '1'; FreqSubdayInterval = '0'; FreqRelativeInterval = '0'; FreqRecurrenceFactor = '0'; ActiveStartDate = '20261029'; ActiveEndDate = '99991231'; ActiveStartTime = '20000'; ActiveEndTime = '235959' })
                }
            )
            Alerts    = @(
                [pscustomobject]@{ Name = 'Severity 17'; Enabled = $true; MessageId = '0'; Severity = '17'; DelayBetweenResponses = '60'; NotificationMessage = $null; IncludeEventDescription = '1'; Database = $null; EventDescriptionKeyword = $null; Job = $null; PerformanceCondition = $null; Category = '[Uncategorized]'
                    Notifications = @([pscustomobject]@{ Operator = 'Ops'; Method = '1' }, [pscustomobject]@{ Operator = 'Dev team'; Method = '1' })
                }
            )
        }

        $record = InModuleScope $module -Parameters @{ Snapshot = $snapshot } { param($Snapshot) ConvertTo-GuestSqlAgentRecord -Snapshot $Snapshot }

        @($record.Operators).Name | Should -Be @('Dev team', 'Ops')
        $record.Operators[1].EmailAddress | Should -Be ''
        @($record.Jobs[0].Steps).Name | Should -Be @('Load', 'Report')
        $record.Jobs[0].Steps[0].RetryInterval | Should -BeOfType [int]
        $record.Jobs[0].Schedules[0].ActiveStartTime | Should -Be 20000
        $record.Jobs[0].Description | Should -Be ''
        @($record.Alerts[0].Notifications).Operator | Should -Be @('Dev team', 'Ops')
    }

    It 'returns empty lists when the instance has no Agent objects of its own' {
        $record = InModuleScope $module { ConvertTo-GuestSqlAgentRecord -Snapshot ([pscustomobject]@{ Operators = @(); Jobs = @(); Alerts = @() }) }

        foreach ($list in $record.Operators, $record.Jobs, $record.Alerts) { @($list).Count | Should -Be 0 }
    }
}

Describe 'Update-GuestSqlRecord (#131)' {
    BeforeAll {
        function Invoke-TestRecord {
            <#
              Records Alpha's SQL logins and settings under $Root, with the
              guest reporting $Snapshot, or having no SQL Server when
              -NoInstance. Returns whether anything changed.
            #>
            param([string]$Root, [object]$Snapshot, [switch]$NoInstance)

            InModuleScope $module -Parameters @{ Root = $Root; Snapshot = $Snapshot; NoInstance = [bool]$NoInstance } {
                param($Root, $Snapshot, $NoInstance)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                $instance = if ($NoInstance) { $null } else { [pscustomobject]@{ Instance = 'MSSQLSERVER' } }
                Mock Connect-GuestSqlInstance { $instance }.GetNewClosure()
                $reported = $Snapshot
                Mock Get-GuestSqlSnapshot { $reported }.GetNewClosure()
                $agent = [pscustomobject]@{ Operators = @([pscustomobject]@{ Name = 'Dev team'; Enabled = $true; EmailAddress = 'dev@example.com'; Category = '[Uncategorized]' }); Jobs = @(); Alerts = @() }
                Mock Get-GuestSqlAgentSnapshot { $agent }.GetNewClosure()
                $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)
                Update-GuestSqlRecord -VM $vm
            }
        }
        function New-TestSnapshot {
            param([string[]]$Login = @('app'))
            [pscustomobject]@{
                Configs   = @([pscustomobject]@{ Name = 'max server memory (MB)'; Value = '4096' })
                Logins    = @($Login | ForEach-Object {
                        [pscustomobject]@{ Name = $_; TypeDesc = 'SQL_LOGIN'; IsDisabled = $false; DefaultDb = 'master'; DefaultLang = 'us_english'; SidHex = '0x1A'; HashHex = '0x02'; PolicyChecked = $true; ExpirationChecked = $false; ServerRoles = @() }
                    })
                Databases = @([pscustomobject]@{ Name = 'Sales'; Files = @('S:\SQLData\Sales.mdf', 'S:\SQLLog\Sales_log.ldf') })
            }
        }
        function Get-TestRecordedSql {
            param([string]$Root)
            (Read-TestJson -Path (Join-Path -Path $Root -ChildPath 'Alpha/Config/VM.json')).GuestSql
        }
    }

    It 'writes the logins and instance settings into VM.json' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $changed = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed | Should -BeTrue
        $recorded = Get-TestRecordedSql -Root $root
        @($recorded.Logins).Name | Should -Be @('app')
        $recorded.Logins[0].HashHex | Should -Be '0x02'
        $recorded.Configs[0].Value | Should -Be 4096
        @($recorded.Agent.Operators).Name | Should -Be @('Dev team')
        $recorded.Databases[0].Files | Should -Be @('S:\SQLData\Sales.mdf', 'S:\SQLLog\Sales_log.ldf')
    }

    It 'writes nothing the second time, when nothing changed' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/History') -Filter 'VM-*.json').Count | Should -Be 1
    }

    It 'records a login that was removed' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot -Login 'app', 'report')

        $changed = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot -Login 'report')

        $changed | Should -BeTrue
        @((Get-TestRecordedSql -Root $root).Logins).Name | Should -Be @('report')
    }

    It 'keeps what it had when the guest has no SQL Server, so a failed install cannot erase the logins' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $null = Invoke-TestRecord -Root $root -Snapshot (New-TestSnapshot)

        $changed = Invoke-TestRecord -Root $root -NoInstance

        $changed | Should -BeFalse
        @((Get-TestRecordedSql -Root $root).Logins).Name | Should -Be @('app')
    }
}

Describe 'Get-GuestSqlRestore (#131)' {
    BeforeAll {
        function Invoke-TestRestore {
            <# What a restore of Alpha under $Root would put back, after VM.json records $Sql (unless it is $null). #>
            param([string]$Root, [object]$Sql)

            InModuleScope $module -Parameters @{ Root = $Root; Sql = $Sql } {
                param($Root, $Sql)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @() }
                if ($null -ne $Sql) { $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestSql = $Sql } -Reason 'a test' }
                Get-GuestSqlRestore -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        }
    }

    It 'returns nothing for a VM whose SQL state was never recorded, so an older capture is used' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        Invoke-TestRestore -Root $root -Sql $null | Should -BeNullOrEmpty
    }

    It 'returns the recorded logins and instance settings' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $login = [ordered]@{ Name = 'app'; TypeDesc = 'SQL_LOGIN'; IsDisabled = $false; DefaultDb = 'master'; DefaultLang = 'us_english'; SidHex = '0x1A'; HashHex = '0x02'; PolicyChecked = $true; ExpirationChecked = $false; ServerRoles = @() }

        $restore = Invoke-TestRestore -Root $root -Sql ([ordered]@{ Configs = @(); Logins = @($login) })

        @($restore.Logins).Name | Should -Be @('app')
        @($restore.Configs).Count | Should -Be 0
    }

    It 'returns the recorded databases and their files (#132)' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $database = [ordered]@{ Name = 'Sales'; Files = @('S:\SQLData\Sales.mdf', 'S:\SQLLog\Sales_log.ldf') }

        $restore = Invoke-TestRestore -Root $root -Sql ([ordered]@{ Configs = @(); Logins = @(); Databases = @($database) })

        @($restore.Databases).Name | Should -Be @('Sales')
        $restore.Databases[0].Files | Should -Be @('S:\SQLData\Sales.mdf', 'S:\SQLLog\Sales_log.ldf')
    }
}

Describe 'Restore-GuestSqlState attaching databases (#132)' {
    BeforeEach {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $script:restored = @()
    }

    It 'attaches the recorded databases and restores from backup only those it could not attach' {
        $restored = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            Mock Write-LogEntry {}
            Mock Write-GuestNote {}
            Mock Get-ToolingCheckpointStamp { , @() }
            Mock Connect-GuestSqlInstance { [pscustomobject]@{ Instance = 'MSSQLSERVER' } }
            Mock Restore-GuestSqlLogin {}
            Mock Restore-GuestSqlAgent {}
            Mock Invoke-GuestScript { [pscustomobject]@{ Attached = ($ArgumentList[1] -eq 'Sales'); Notes = @() } } -ParameterFilter { $Activity -like 'attaching*' }
            $script:restoredNames = @()
            Mock Invoke-GuestScript { $script:restoredNames += $ArgumentList[1] } -ParameterFilter { $Activity -like 'restoring*' }
            $databases = @(
                [ordered]@{ Name = 'Hr'; Files = @('S:\SQLData\Hr.mdf') }
                [ordered]@{ Name = 'Sales'; Files = @('S:\SQLData\Sales.mdf') }
            )
            $recorded = [ordered]@{ Configs = @(); Logins = @(); Databases = $databases }
            $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestSql = $recorded } -Reason 'a test'
            $manifest = [CaptureManifest]::new()
            $manifest.Sql = [pscustomobject]@{ NotMigrated = @(); Databases = @('Hr', 'Sales', 'Old') | ForEach-Object { [pscustomobject]@{ Name = $_; BackupFile = "S:\SQLBackup\$_.bak"; Recovery = 'SIMPLE'; CompatLevel = 170 } } }

            Restore-GuestSqlState -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)) -Manifest $manifest
            $script:restoredNames
        }

        $restored | Should -Be @('Hr', 'Old')
    }
}

Describe 'Restore-GuestSqlState (#131)' {
    BeforeAll {
        function Invoke-TestRestore {
            <#
              Restores Alpha's SQL state under $Root from a capture whose Sql is
              $CapturedSql, after VM.json records $RecordedSql (unless it is
              $null). Returns the logins handed to Restore-GuestSqlLogin, or
              with -AgentOnly the Agent handed to Restore-GuestSqlAgent;
              $null when it was not called.
            #>
            param([string]$Root, [object]$CapturedSql, [object]$RecordedSql, [switch]$AgentOnly)

            InModuleScope $module -Parameters @{ Root = $Root; CapturedSql = $CapturedSql; RecordedSql = $RecordedSql; AgentOnly = [bool]$AgentOnly } {
                param($Root, $CapturedSql, $RecordedSql, $AgentOnly)
                Mock Write-LogEntry {}
                Mock Write-GuestNote {}
                Mock Get-ToolingCheckpointStamp { , @() }
                Mock Connect-GuestSqlInstance { [pscustomobject]@{ Instance = 'MSSQLSERVER' } }
                Mock Invoke-GuestScript {}
                $script:handedLogins = $null
                Mock Restore-GuestSqlLogin { $script:handedLogins = @($Logins) }
                $script:handedAgent = $null
                Mock Restore-GuestSqlAgent { $script:handedAgent = $Agent }
                if ($null -ne $RecordedSql) { $null = Update-VMProfile -Root $Root -Name 'Alpha' -Change @{ GuestSql = $RecordedSql } -Reason 'a test' }
                $manifest = [CaptureManifest]::new()
                $manifest.Sql = $CapturedSql
                Restore-GuestSqlState -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)) -Manifest $manifest
                if ($AgentOnly) { $script:handedAgent } else { , $script:handedLogins }
            }
        }
        function New-TestLogin {
            param([string]$Name)
            [ordered]@{ Name = $Name; TypeDesc = 'SQL_LOGIN'; IsDisabled = $false; DefaultDb = 'master'; DefaultLang = 'us_english'; SidHex = '0x1A'; HashHex = '0x02'; PolicyChecked = $true; ExpirationChecked = $false; ServerRoles = @() }
        }
    }

    It 'restores the logins VM.json records rather than the ones in the capture' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $captured = [pscustomobject]@{ Databases = @(); Logins = @([pscustomobject](New-TestLogin -Name 'old')); Configs = @(); NotMigrated = @() }

        $logins = Invoke-TestRestore -Root $root -CapturedSql $captured -RecordedSql ([ordered]@{ Configs = @(); Logins = @(New-TestLogin -Name 'recorded') })

        @($logins).Name | Should -Be @('recorded')
    }

    It 'restores the logins in the capture for a VM recorded before #131' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $captured = [pscustomobject]@{ Databases = @(); Logins = @([pscustomobject](New-TestLogin -Name 'old')); Configs = @(); NotMigrated = @() }

        $logins = Invoke-TestRestore -Root $root -CapturedSql $captured -RecordedSql $null

        @($logins).Name | Should -Be @('old')
    }

    It 'restores the recorded logins even when the capture has no SQL state' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $logins = Invoke-TestRestore -Root $root -CapturedSql $null -RecordedSql ([ordered]@{ Configs = @(); Logins = @(New-TestLogin -Name 'recorded') })

        @($logins).Name | Should -Be @('recorded')
    }

    It 'recreates the SQL Agent objects VM.json records' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }
        $agent = [ordered]@{ Operators = @([ordered]@{ Name = 'Dev team'; Enabled = $true; EmailAddress = 'dev@example.com'; Category = '[Uncategorized]' }); Jobs = @(); Alerts = @() }

        $handed = Invoke-TestRestore -Root $root -CapturedSql $null -RecordedSql ([ordered]@{ Configs = @(); Logins = @(); Agent = $agent }) -AgentOnly

        @($handed.Operators).Name | Should -Be @('Dev team')
    }

    It 'recreates no SQL Agent objects for a VM recorded before they were' {
        $root = New-TestRoot -Profiles @{ Alpha = '{ "vCPU": 4 }' }

        $handed = Invoke-TestRestore -Root $root -CapturedSql $null -RecordedSql ([ordered]@{ Configs = @(); Logins = @(New-TestLogin -Name 'recorded') }) -AgentOnly

        $handed | Should -BeNullOrEmpty
        Should -Invoke Restore-GuestSqlAgent -ModuleName $module -Times 0
    }
}

Describe 'The credential store' {
    BeforeAll {
        function New-TestKey {
            param([Parameter(Mandatory)][string]$Path)
            $key = [byte[]]::new(32)
            [Security.Cryptography.RandomNumberGenerator]::Fill($key)
            New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
            [IO.File]::WriteAllBytes($Path, $key)
        }
    }

    It 'reads back what it stored' {
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-TestKey -Path "$folder/.lazyvm.key"

        $password = InModuleScope $module -Parameters @{ Folder = $folder } {
            param($Folder)
            Save-StoredCredential -KeyPath "$Folder/.lazyvm.key" -Path "$Folder/Alpha/guest.cred" -UserName 'sean' -Password (New-RandomPassword)
            $stored = Get-StoredCredential -KeyPath "$Folder/.lazyvm.key" -Path "$Folder/Alpha/guest.cred"
            $stored.UserName | Should -Be 'sean'
            $stored.GetNetworkCredential().Password
        }

        $password.Length | Should -Be 24
    }

    It 'returns nothing when no credential is stored' {
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))

        InModuleScope $module -Parameters @{ Folder = $folder } {
            param($Folder)
            Get-StoredCredential -KeyPath "$Folder/.lazyvm.key" -Path "$Folder/Alpha/guest.cred"
        } | Should -BeNullOrEmpty
    }

    It 'refuses <Case>, rather than treating it as not stored' -ForEach @(
        @{ Case = 'a credential whose key is missing'; KeyBytes = 0; Message = '*its key*is missing*' }
        @{ Case = 'a damaged key'; KeyBytes = 5; Message = '*is damaged (5 bytes instead of 32)*' }
    ) {
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$folder/Alpha" -Force | Out-Null
        Set-Content -LiteralPath "$folder/Alpha/guest.cred" -Value '{ "UserName": "sean", "Password": "x" }'
        if ($KeyBytes) { [IO.File]::WriteAllBytes("$folder/.lazyvm.key", [byte[]]::new($KeyBytes)) }

        {
            InModuleScope $module -Parameters @{ Folder = $folder } {
                param($Folder)
                Get-StoredCredential -KeyPath "$Folder/.lazyvm.key" -Path "$Folder/Alpha/guest.cred"
            }
        } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'New-RandomPassword' {
    It 'always has an upper-case letter, a lower-case letter, a digit and a symbol' {
        $passwords = InModuleScope $module {
            1..50 | ForEach-Object { ConvertTo-PlainText -Secure (New-RandomPassword -Length 8) }
        }

        foreach ($password in $passwords) {
            $password.Length | Should -Be 8
            $password | Should -MatchExactly '[A-Z]'
            $password | Should -MatchExactly '[a-z]'
            $password | Should -Match '[0-9]'
            $password | Should -Match '[^A-Za-z0-9]'
        }
    }
}

Describe 'Write-TextFileAtomic' {
    It 'creates the folder and the file' {
        $path = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid().ToString('N'))/sub/file.json"

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Write-TextFileAtomic -Path $Path -Text 'one' }

        Get-Content -LiteralPath $path -Raw | Should -Be 'one'
    }

    It 'replaces an existing file and leaves no temporary file behind' {
        $path = New-TestFile -Text 'old'

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Write-TextFileAtomic -Path $Path -Text 'new' }

        Get-Content -LiteralPath $path -Raw | Should -Be 'new'
        @(Get-ChildItem -LiteralPath (Split-Path -Path $path -Parent) -Force).Count | Should -Be 1
    }
}
