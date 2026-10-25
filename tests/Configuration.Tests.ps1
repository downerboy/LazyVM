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
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
}

Describe 'The settings schema' {
    It 'has a default and a description for every setting' {
        $schema = InModuleScope $module { Get-SettingsSchema }

        foreach ($name in @($schema.properties.Keys | Where-Object { $_ -ne '$schema' })) {
            $schema.properties[$name].Contains('default') | Should -BeTrue -Because "'$name' needs a default"
            $schema.properties[$name]['description'] | Should -Not -BeNullOrEmpty -Because "'$name' needs a description"
        }
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
    It 'creates a profile that points at the schema and sets nothing else' {
        $root = New-TestRoot

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Alpha'
        }

        $path | Should -Exist
        $vmProfile = Read-TestJson -Path $path
        @($vmProfile.Keys) | Should -Be @('$schema')
        $vmProfile['$schema'] | Should -Be '../../Shared/Config/LazyVM.Settings.schema.json'
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

    It 'with -From, copies the shared settings and the tooling list, but not the per-VM ones' {
        $root = New-TestRoot -Profiles @{
            Alpha = '{ "MemMaxGB": 32, "LogFile": "Logs\\Alpha-Old.log", "GuestComputerName": "ALPHA" }'
        }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/Tooling.json') -Value '{ "Version": 1 }'

        $path = InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            New-VMProfile -Root $Root -Name 'Beta' -From 'Alpha'
        }
        $vmProfile = Read-TestJson -Path $path

        $vmProfile.MemMaxGB | Should -Be 32
        $vmProfile.Keys | Should -Not -Contain 'LogFile'
        $vmProfile.Keys | Should -Not -Contain 'GuestComputerName'
        Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'Tooling.json' | Should -Exist
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
}

Describe 'Read-VMSetting' {
    It 'layers the defaults, the host settings and the VM profile, then names, roots and derives everything' {
        $root = New-TestRoot -HostSettings '{ "MemMaxGB": 12, "vCPU": 6 }' -Profiles @{
            Alpha = '{ "GuestComputerName": "ALPHA-PC", "vCPU": 2 }'
        }

        $result = InModuleScope $module -Parameters @{ Root = $root } { param($Root) Read-VMSetting -Root $Root }
        $settings = $result.Settings

        $result.VMName | Should -Be 'Alpha'
        $result.ChangedKeys | Should -Be @('MemMaxGB', 'vCPU')
        $result.ProfileKeys | Should -Be @('GuestComputerName', 'vCPU')
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
        $runtime.GuestSqlTempDir | Should -Be 'F:\Temp'
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
