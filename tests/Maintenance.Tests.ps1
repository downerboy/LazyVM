# Maintenance.Tests.ps1
# Invoke-Maintenance and Invoke-Rebuild each return exactly one result, so
# callers can use it as it is (#19). The helpers they call are mocked to
# write stray output, which must not reach the caller. Nothing here needs
# Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Classes defined in a module are only visible inside it.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; RebuildThresholdDays = 10 }) }
}

Describe 'Invoke-Maintenance' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha' } }
        Mock -ModuleName $module Open-GuestSession { $true }
        Mock -ModuleName $module Expand-GuestSystemDrive { 'stray' }
        Mock -ModuleName $module Update-ToolingRecord { }
        Mock -ModuleName $module Update-GuestEnvironmentRecord { }
        Mock -ModuleName $module Update-GuestFirewallRecord { }
        Mock -ModuleName $module Update-GuestScheduledTaskRecord { }
        Mock -ModuleName $module Update-GuestSqlRecord { }
        Mock -ModuleName $module Update-GuestAppSettingRecord { }
        Mock -ModuleName $module Stop-GuestGracefully { 'stray' }
        Mock -ModuleName $module Save-GuestState { 'stray' }
    }

    It 'returns only None when nothing is due' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        $result.Count | Should -Be 1
        "$($result[0])" | Should -Be 'None'
    }

    It 'returns only Rearmed after a rearm' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Grace'; DaysLeft = 5; RearmsLeft = 2 } }
        Mock -ModuleName $module Invoke-GuestRearm { $true }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        $result.Count | Should -Be 1
        "$($result[0])" | Should -Be 'Rearmed'
    }
}

Describe 'Invoke-Rebuild' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-Module { [pscustomobject]@{ Name = 'Hyper-V' } } -ParameterFilter { $ListAvailable -and $Name -eq 'Hyper-V' }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha' } }
        Mock -ModuleName $module Save-GuestState { [pscustomobject]@{ Databases = @() } }
        Mock -ModuleName $module Invoke-RetireCurrentVM { [pscustomobject]@{ RetiredOsPath = 'old.vhdx'; NewOsPath = 'new.vhdx' } }
        Mock -ModuleName $module Invoke-BuildPhase { 'stray' }
        Mock -ModuleName $module Restore-GuestState { $true }
        Mock -ModuleName $module Test-RebuiltVM { [pscustomobject]@{ Passed = $true; Failures = @() } }
        Mock -ModuleName $module Remove-RetiredVM { 'stray' }
    }

    It 'returns only $true when the rebuild passes its check' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Rebuild -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeTrue
    }
}
