# PerUser.Tests.ps1
# LazyVM installed per user (#284): its registry key is under HKCU, its
# folder is open to the installing user and SYSTEM only, and its scheduled
# tasks run as that user. While a machine-wide install from before is still
# there, nothing but Convert-LazyVMInstallation runs. Nothing here changes
# the host: the registry, ACL and Task Scheduler calls are mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
}

Describe 'Where LazyVM records its folder (#284)' {
    It 'is the current user''s registry, not the machine''s' {
        InModuleScope $module { $script:RootRegistryKey } | Should -Be 'HKCU:\SOFTWARE\LazyVM'
    }

    It 'still marks a provisioned guest under HKLM, inside the guest' {
        InModuleScope $module { $script:GuestMarkerKey } | Should -Be 'HKLM:\SOFTWARE\LazyVM'
    }
}

Describe 'A machine-wide install from before (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-LegacyRoot { 'C:\LazyVM' }
    }

    It 'stops every command that looks for the LazyVM folder, naming the migration' {
        { InModuleScope $module { Resolve-LazyVMRoot } } | Should -Throw -ExpectedMessage '*every user*C:\LazyVM*Convert-LazyVMInstallation*'
    }

    It 'stops a first build from setting up a new folder beside it' {
        Mock -ModuleName $module Get-RegisteredRoot { $null }
        Mock -ModuleName $module Get-DefaultRoot { throw 'must not choose a new folder' }

        { InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' } } | Should -Throw -ExpectedMessage '*Convert-LazyVMInstallation*'
    }

    It 'stops Set-LazyVMRoot' {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Set-RegisteredRoot { }

        { Set-LazyVMRoot -Path 'D:\DevVM' -Confirm:$false } | Should -Throw -ExpectedMessage '*Convert-LazyVMInstallation*'

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 0
    }

    It 'is not there once migrated' {
        Mock -ModuleName $module Get-LegacyRoot { $null }

        { InModuleScope $module { Assert-NoLegacyInstallation } } | Should -Not -Throw
    }
}
