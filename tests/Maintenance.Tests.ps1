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
        Mock -ModuleName $module Install-UserDisk { 'stray' }
        Mock -ModuleName $module Protect-GuestPersistentDisk { 'stray' }
        Mock -ModuleName $module Update-ToolingRecord { }
        Mock -ModuleName $module Update-GuestEnvironmentRecord { }
        Mock -ModuleName $module Update-GuestFirewallRecord { }
        Mock -ModuleName $module Update-GuestScheduledTaskRecord { }
        Mock -ModuleName $module Update-GuestSqlRecord { }
        Mock -ModuleName $module Update-GuestAppSettingRecord { }
        Mock -ModuleName $module Backup-GuestUserDatabase { 'stray' }
        Mock -ModuleName $module Stop-GuestGracefully { 'stray' }
        Mock -ModuleName $module Save-GuestState { 'stray' }
        Mock -ModuleName $module Test-GuestStateChanged { $false }
    }

    It 'returns only None when nothing is due' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        $result.Count | Should -Be 1
        "$($result[0])" | Should -Be 'None'
    }

    It 'checks and backs up the databases every day, and carries on when that fails (#133)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Backup-GuestUserDatabase { throw 'the guest stopped answering' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        "$($result[0])" | Should -Be 'None'
        Should -Invoke -ModuleName $module Backup-GuestUserDatabase -Times 1
    }

    It 'sets up the User disk every day, and carries on when that fails (#137)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Install-UserDisk { throw 'the guest stopped answering' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        "$($result[0])" | Should -Be 'None'
        Should -Invoke -ModuleName $module Install-UserDisk -Times 1
    }

    It 'turns BitLocker on for every persistent disk every day, and carries on when that fails (#175)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Protect-GuestPersistentDisk { throw 'the guest stopped answering' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        "$($result[0])" | Should -Be 'None'
        Should -Invoke -ModuleName $module Protect-GuestPersistentDisk -Times 1 -Exactly
    }

    It 'captures the state when it changed and nothing else is due (#20)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Test-GuestStateChanged { $true }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        "$($result[0])" | Should -Be 'None'
        Should -Invoke -ModuleName $module Save-GuestState -Times 1
    }

    It 'captures nothing when the state is unchanged and nothing else is due (#20)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }

        $null = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM }

        Should -Invoke -ModuleName $module Save-GuestState -Times 0
    }

    It 'carries on when the change check fails (#20)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Test-GuestStateChanged { throw 'the guest stopped answering' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

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

Describe 'Invoke-GuestRearm' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Success = $true; Reason = ''; Before = 2 } }
        Mock -ModuleName $module Restart-GuestAndWait { 'stray' }
    }

    It 'returns only $true when the rearm is accepted' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-GuestRearm -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeTrue
    }
}

Describe 'Invoke-Rebuild' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-Module { [pscustomobject]@{ Name = 'Hyper-V' } } -ParameterFilter { $ListAvailable -and $Name -eq 'Hyper-V' }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha' } }
        Mock -ModuleName $module Install-UserDisk { 'stray' }
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

    It 'retires nothing when the personal files cannot be put on the User disk (#137)' {
        Mock -ModuleName $module Install-UserDisk { throw 'robocopy failed' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Rebuild -VM $VM } } | Should -Throw -ExpectedMessage '*robocopy failed*'

        Should -Invoke -ModuleName $module Invoke-RetireCurrentVM -Times 0
    }

    It 'restores nothing and keeps the old OS disk when a persistent disk cannot be unlocked (#175)' {
        Mock -ModuleName $module Invoke-BuildPhase { throw 'The SQL data disk could not be unlocked with its stored recovery password.' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Rebuild -VM $VM })

        $result[0] | Should -BeFalse
        Should -Invoke -ModuleName $module Restore-GuestState -Times 0
        Should -Invoke -ModuleName $module Remove-RetiredVM -Times 0
    }
}
