# GuestOSDisk.Tests.ps1
# Expanding C: (Expand-GuestSystemDrive) runs in every build and every
# maintenance run, so it must report what the guest did and must never stop
# either one. The guest itself is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'Massokissed.LazyVM'
}

Describe 'Expand-GuestSystemDrive' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
    }

    It 'logs each note the guest reports at its level' {
        Mock -ModuleName $module Invoke-GuestScript {
            @('OK|removed the recovery partition after C:', 'OK|C: extended from 120 GB to 200 GB')
        }

        InModuleScope $module { Expand-GuestSystemDrive }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*recovery partition*' -and $Level -eq 'OK' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*extended from 120 GB to 200 GB' -and $Level -eq 'OK' }
    }

    It 'logs nothing when C: already fills the disk' {
        Mock -ModuleName $module Invoke-GuestScript { @() }

        InModuleScope $module { Expand-GuestSystemDrive }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -Exactly
    }

    It 'logs a failure instead of throwing, so the run carries on' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'C: drive expansion failed in guest' }

        { InModuleScope $module { Expand-GuestSystemDrive } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }
}
