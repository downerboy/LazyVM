# Sysmon.Tests.ps1
# The built-in Windows Sysmon in each VM (#236): the configuration LazyVM
# ships, and Set-GuestSysmon, which hands it to the guest at every build and
# every night. The guest is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    # A native path, because [System.IO.File] does not read PowerShell's backslashes on Linux.
    $configPath = (Resolve-Path -LiteralPath (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Sysmon\sysmonconfig.xml')).ProviderPath
}

Describe 'The Sysmon configuration LazyVM ships' {
    BeforeAll {
        $text = Get-Content -LiteralPath $configPath -Raw
    }

    It 'is a Sysmon configuration' {
        ([xml]$text).Sysmon.EventFiltering | Should -Not -BeNullOrEmpty
    }

    It 'credits SwiftOnSecurity''s sysmon-config, the commit it came from and its license' {
        $text | Should -Match 'https://github.com/SwiftOnSecurity/sysmon-config'
        $text | Should -Match '1836897f12fbd6a0a473665ef6abc34a6b497e31'
        $text | Should -Match 'Creative Commons Attribution 4.0'
    }

    It 'leaves out the build noise of <What>' -ForEach @(
        @{ What = 'Visual Studio and its MSBuild'; Rule = 'C:\Program Files\Microsoft Visual Studio\' }
        @{ What = 'the Visual Studio Installer'; Rule = 'C:\Program Files (x86)\Microsoft Visual Studio\' }
        @{ What = 'the .NET SDK''s MSBuild and compiler'; Rule = '"C:\Program Files\dotnet\dotnet.exe" "C:\Program Files\dotnet\sdk\' }
        @{ What = 'SQL Server'; Rule = 'C:\Program Files\Microsoft SQL Server' }
    ) {
        $excluded = @(([xml]$text).SelectNodes('//ProcessCreate[@onmatch="exclude"]/*') | ForEach-Object InnerText)

        $excluded | Should -Contain $Rule
    }
}

Describe 'Set-GuestSysmon' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Write-GuestNote { }
    }

    It 'leaves the guest alone when GuestSysmon is off' {
        Mock -ModuleName $module Invoke-GuestScript { }

        InModuleScope $module { Set-GuestSysmon -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSysmon = $false })) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'turned off in the settings \(GuestSysmon\)' }
    }

    It 'hands the guest the configuration LazyVM ships, its hash and a 256 MB event log, and logs what it reports' {
        Mock -ModuleName $module Invoke-GuestScript { @(@{ Level = 'OK'; Text = 'Sysmon installed' }) }
        $expectedText = [System.IO.File]::ReadAllText($configPath)
        $expectedHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

        InModuleScope $module { Set-GuestSysmon -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSysmon = $true })) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -ceq $expectedText -and $ArgumentList[1] -eq $expectedHash -and $ArgumentList[2] -eq 256MB
        }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { $Notes[0].Text -eq 'Sysmon installed' }
    }

    It 'logs a guest failure as non-fatal and carries on' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'Sysmon failed in guest: access denied' }

        { InModuleScope $module { Set-GuestSysmon -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSysmon = $true })) } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly -ParameterFilter { $Context -match 'non-fatal' }
    }

    It 'logs a configuration it cannot read as non-fatal and carries on' {
        Mock -ModuleName $module Invoke-GuestScript { }
        Mock -ModuleName $module Get-FileHash { throw 'The file is locked by another process' }

        { InModuleScope $module { Set-GuestSysmon -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSysmon = $true })) } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly -ParameterFilter { $Context -match 'non-fatal' }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
    }

    It 'emits nothing' {
        Mock -ModuleName $module Invoke-GuestScript { @(@{ Level = 'OK'; Text = 'Sysmon installed' }) }

        $result = @(InModuleScope $module { Set-GuestSysmon -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSysmon = $true })) })

        $result.Count | Should -Be 0
    }
}

Describe 'The GuestSysmon setting' {
    It 'is on unless a VM turns it off' {
        $schema = InModuleScope $module { Get-SettingsSchema }

        $schema.properties['GuestSysmon']['type'] | Should -Be 'boolean'
        $schema.properties['GuestSysmon']['default'] | Should -BeTrue
    }
}
