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
    $buildComplete = InModuleScope $module { [BuildOutcome]::Complete }
    $buildWithProblems = InModuleScope $module { [BuildOutcome]::CompleteWithProblems }
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
        Mock -ModuleName $module Backup-UserDisk { 'stray' }
        Mock -ModuleName $module Update-ToolingRecord { }
        Mock -ModuleName $module Update-GuestEnvironmentRecord { }
        Mock -ModuleName $module Update-GuestFirewallRecord { }
        Mock -ModuleName $module Update-GuestScheduledTaskRecord { }
        Mock -ModuleName $module Update-GuestSqlRecord { }
        Mock -ModuleName $module Update-GuestAppSettingRecord { }
        Mock -ModuleName $module Backup-GuestUserDatabase { 'stray' }
        Mock -ModuleName $module Start-GuestStoreAppUpdate { 'stray' }
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

    It 'backs up the User disk every day, and carries on when that fails (#139)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Backup-UserDisk { throw 'the external disk was unplugged' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        "$($result[0])" | Should -Be 'None'
        Should -Invoke -ModuleName $module Backup-UserDisk -Times 1 -Exactly
    }

    It 'asks the Store to update its apps every day, and carries on when that fails (#233)' {
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = 50; RearmsLeft = 3 } }
        Mock -ModuleName $module Start-GuestStoreAppUpdate { throw 'the guest stopped answering' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Maintenance -VM $VM })

        "$($result[0])" | Should -Be 'None'
        Should -Invoke -ModuleName $module Start-GuestStoreAppUpdate -Times 1 -Exactly
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

Describe 'Start-GuestStoreAppUpdate (#233)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-GuestScript { throw 'the WMI bridge needs SYSTEM, not the guest account' }
    }

    It 'asks the Store to scan for app updates from a task running as SYSTEM' {
        Mock -ModuleName $module Invoke-GuestTask { '0' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Start-GuestStoreAppUpdate -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -like '*store-app-update' -and -not $AsGuestUser -and "$Work" -match 'UpdateScanMethod'
        }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' }
    }

    It 'warns, with the code, when the Store refuses the scan' {
        Mock -ModuleName $module Invoke-GuestTask { '5' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Start-GuestStoreAppUpdate -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -match '\b5\b' }
    }

    It 'warns, without failing, when the guest has no Store app management' {
        Mock -ModuleName $module Invoke-GuestTask { 'unavailable' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Start-GuestStoreAppUpdate -VM $VM } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'not available' }
    }

    It 'emits nothing' {
        Mock -ModuleName $module Invoke-GuestTask { '0' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Start-GuestStoreAppUpdate -VM $VM })

        $result.Count | Should -Be 0
    }
}

Describe 'Get-MaintenancePreview (#18)' {
    BeforeEach {
        Mock -ModuleName $module Open-GuestSession { $false }
    }

    It 'says the VM would be built when it does not exist' {
        Mock -ModuleName $module Get-VM { }

        $text = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-MaintenancePreview -VM $VM }

        $text | Should -BeLike 'Build*'
    }

    It 'starts nothing when the VM is off, and says the evaluation was not read' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Off' } }

        $text = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-MaintenancePreview -VM $VM }

        $text | Should -BeLike '*Off*not read*'
        Should -Invoke -ModuleName $module Open-GuestSession -Times 0
    }

    It 'says <Expected> with <DaysLeft> day(s) and <RearmsLeft> rearm(s) left' -ForEach @(
        @{ DaysLeft = 50; RearmsLeft = 3; Expected = '*no rearm or rebuild*' }
        @{ DaysLeft = -1; RearmsLeft = 3; Expected = '*no evaluation countdown*' }
        @{ DaysLeft = 5; RearmsLeft = 2; Expected = '*rearm Windows*' }
        @{ DaysLeft = 5; RearmsLeft = 0; Expected = '*rebuild the VM*' }
    ) {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Get-GuestLicenseStatus { [pscustomobject]@{ Status = 'Licensed'; DaysLeft = $DaysLeft; RearmsLeft = $RearmsLeft } }.GetNewClosure()

        $text = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-MaintenancePreview -VM $VM }

        $text | Should -BeLike $Expected
    }
}

Describe 'Remove-VMCheckpointTree' {
    It 'deletes each root checkpoint with its children, so no checkpoint is deleted twice (#194)' {
        Mock -ModuleName $module Get-VMSnapshot {
            [pscustomobject]@{ Name = 'Tooling 20261030-030041'; ParentSnapshotName = $null }
            [pscustomobject]@{ Name = 'Tooling 20261030-223746'; ParentSnapshotName = 'Tooling 20261030-030041' }
        }
        Mock -ModuleName $module Remove-VMSnapshot { }

        InModuleScope $module { Remove-VMCheckpointTree -VMName 'testvm' }

        Should -Invoke -ModuleName $module Remove-VMSnapshot -Times 1 -Exactly -ParameterFilter {
            $VMName -eq 'testvm' -and @($Name).Count -eq 1 -and $Name[0] -eq 'Tooling 20261030-030041' -and $IncludeAllChildSnapshots
        }
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
        Mock -ModuleName $module Invoke-BuildPhase { $buildComplete }
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

    It 'keeps the old OS disk and reports failure when the build finished with problems (#232)' {
        Mock -ModuleName $module Invoke-BuildPhase { $buildWithProblems }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Invoke-Rebuild -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeFalse
        Should -Invoke -ModuleName $module Restore-GuestState -Times 1 -Exactly
        Should -Invoke -ModuleName $module Remove-RetiredVM -Times 0
    }
}

Describe 'Invoke-Rebuild verification' {
    # The real checks run here, with only the guest and Hyper-V stood in for.
    BeforeAll {
        $noDevDriveVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; UseDevDrive = $false }) }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-Module { [pscustomobject]@{ Name = 'Hyper-V' } } -ParameterFilter { $ListAvailable -and $Name -eq 'Hyper-V' }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Install-UserDisk { }
        Mock -ModuleName $module Invoke-RetireCurrentVM { [pscustomobject]@{ RetiredOsPath = 'old.vhdx'; NewOsPath = 'new.vhdx' } }
        Mock -ModuleName $module Invoke-BuildPhase { $buildComplete }
        Mock -ModuleName $module Restore-GuestState { $true }
        Mock -ModuleName $module Remove-RetiredVM { }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('admin', [securestring]::new()) }
        Mock -ModuleName $module Connect-Guest { }
        Mock -ModuleName $module Get-GuestInstallerProduct { }
        Mock -ModuleName $module Get-BuildTooling { [pscustomobject]@{ Products = @() } }
        Mock -ModuleName $module Connect-GuestSqlInstance { [pscustomobject]@{ Instance = 'MSSQLSERVER'; Edition = 'Developer Edition' } }
        Mock -ModuleName $module Invoke-GuestScript { $true }
    }

    It 'reports a good rebuild as clean when the capture has no user databases (#208)' {
        Mock -ModuleName $module Save-GuestState { [pscustomobject]@{ Databases = @() } }

        $result = @(InModuleScope $module -Parameters @{ VM = $noDevDriveVM } { param($VM) Invoke-Rebuild -VM $VM })

        $result[0] | Should -BeTrue
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { $Message -like '*FAIL*' }
        Should -Invoke -ModuleName $module Remove-RetiredVM -Times 1
    }
}
