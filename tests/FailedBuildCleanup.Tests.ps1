# FailedBuildCleanup.Tests.ps1
# What a build leaves behind when it stops, and what it says about why
# (#227, #247): the answer-file disc holds the guest password, a guest task that
# timed out stays registered, and the reason given must be the real one.
# Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $settings = @{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup'; GuestWaitMinutes = 90 }
}

Describe 'Wait-GuestReady' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Get-VMIntegrationService { [pscustomobject]@{ PrimaryStatusDescription = 'OK' } }
        Mock -ModuleName $module Remove-PSSession { } -RemoveParameterType Session
        Mock -ModuleName $module Invoke-Command { $false } -RemoveParameterType Session
        # The first try is refused, as before the account exists; every try
        # after that reaches a guest still in OOBE.
        $tries = @{ Count = 0 }
        Mock -ModuleName $module New-PSSession {
            $tries.Count++
            if ($tries.Count -eq 1) { throw 'The credential is invalid.' }
            [pscustomobject]@{ Name = 'session' }
        }
        # Two tries, then the time is up.
        Mock -ModuleName $module Wait-Until { $null = & $Condition $State; $null = & $Condition $State; $null }
    }

    It 'gives the reason the guest was last not ready, not an older error' {
        $wait = {
            InModuleScope $module -Parameters @{ Settings = $settings } {
                param($Settings)
                Wait-GuestReady -VM ([VMContext]::new($Settings)) -Credential ([pscredential]::new('lazy', [securestring]::new())) -TimeoutMinutes 90 -RequireProvisioned
            }
        }

        $failure = $wait | Should -Throw -ExpectedMessage '*first-logon*' -PassThru
        $failure.Exception.Message | Should -Not -BeLike '*credential is invalid*'
    }
}

Describe 'Invoke-BuildPhase when a phase fails' {
    # Phase 6 builds the answer-file disc and phase 7 removes it once the
    # guest is ready; a build that stops anywhere in between must not leave
    # it on disk (#247).
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Initialize-InstallationIso { }
        Mock -ModuleName $module Remove-UnattendSeedDisk { $true }
        Mock -ModuleName $module Get-VM { }
        $seedDisk = 'D:\DevVM\Alpha\Disks\Alpha-Seed.iso'
        $disc = @{ Exists = $true }
        Mock -ModuleName $module Test-Path { $disc.Exists } -ParameterFilter { $LiteralPath -eq $seedDisk }

        $build = {
            InModuleScope $module -Parameters @{ SeedDisk = $seedDisk } {
                param($SeedDisk)
                Invoke-BuildPhase -VM ([VMContext]::new(@{ VMName = 'Alpha'; SeedDiskPath = $SeedDisk }))
            }
        }
    }

    It 'deletes the answer-file disc, which holds the guest password, and still stops the build' {
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 6; Name = 'VM Build'; Action = { throw 'New-VM failed.' } } }

        $build | Should -Throw -ExpectedMessage 'New-VM failed.'
        Should -Invoke -ModuleName $module Remove-UnattendSeedDisk -Times 1 -Exactly
    }

    It 'leaves the answer-file disc to phase 7 when no phase fails' {
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 6; Name = 'VM Build'; Action = { } } }

        $null = & $build

        Should -Invoke -ModuleName $module Remove-UnattendSeedDisk -Times 0 -Exactly
    }

    It 'says to finish Setup in the VM console when the VM exists' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha' } }
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 6; Name = 'VM Build'; Action = { throw 'Start-VM failed.' } } }

        $build | Should -Throw -ExpectedMessage 'Start-VM failed.'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*VM console*' -and $Level -eq 'WARN' }
    }

    It 'does not say the answer-file disc is gone when it could not be deleted' {
        Mock -ModuleName $module Remove-UnattendSeedDisk { $false }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha' } }
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 6; Name = 'VM Build'; Action = { throw 'Start-VM failed.' } } }

        $build | Should -Throw -ExpectedMessage 'Start-VM failed.'
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -Exactly -ParameterFilter { $Message -like '*disc is gone*' }
    }

    It 'does not send the user to the VM console when there is no VM' {
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 6; Name = 'VM Build'; Action = { throw 'New-VM failed.' } } }

        $build | Should -Throw -ExpectedMessage 'New-VM failed.'
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -Exactly -ParameterFilter { $Message -like '*VM console*' }
    }

    It 'does not look for the answer-file disc in Hyper-V when there is none' {
        $disc.Exists = $false
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 1; Name = 'Readiness'; Action = { throw 'Hyper-V is not available.' } } }

        $build | Should -Throw -ExpectedMessage 'Hyper-V is not available.'
        Should -Invoke -ModuleName $module Remove-UnattendSeedDisk -Times 0 -Exactly
    }
}

Describe 'Remove-UnattendSeedDisk' {
    # The answer-file disc holds the guest password in clear text, so it is
    # deleted even when it cannot be ejected from the VM first (#255).
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $seedDisk = Join-Path -Path $TestDrive -ChildPath 'Alpha-Seed.iso'
        Set-Content -LiteralPath $seedDisk -Value 'password'

        $remove = {
            InModuleScope $module -Parameters @{ SeedDisk = $seedDisk } {
                param($SeedDisk)
                Remove-UnattendSeedDisk -VM ([VMContext]::new(@{ VMName = 'Alpha'; SeedDiskPath = $SeedDisk }))
            }
        }
    }

    It 'deletes the answer-file disc when it cannot be ejected' {
        Mock -ModuleName $module Get-VMDvdDrive { throw 'Hyper-V was unable to find a virtual machine with name "Alpha".' }

        & $remove

        $seedDisk | Should -Not -Exist
    }

    It 'warns that the answer-file disc could not be ejected' {
        Mock -ModuleName $module Get-VMDvdDrive { throw 'Hyper-V was unable to find a virtual machine with name "Alpha".' }

        & $remove

        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*eject*unable to find*' -and $Level -eq 'WARN' }
    }

    It 'returns $true once the answer-file disc is deleted' {
        Mock -ModuleName $module Get-VMDvdDrive { }

        & $remove | Should -Be $true
    }

    It 'returns $false and says to delete the answer-file disc by hand when it cannot be deleted' {
        Mock -ModuleName $module Get-VMDvdDrive { }
        Mock -ModuleName $module Remove-Item { throw 'The process cannot access the file because it is being used by another process.' } -ParameterFilter { $LiteralPath -eq $seedDisk }

        & $remove | Should -Be $false
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*by hand*' -and $Level -eq 'WARN' }
    }
}

Describe 'Install-GuestSoftware when the answer-file disc cannot be deleted' {
    # Phase 7 carries on, but must not report itself complete while the
    # guest password is still on disk (#255).
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $seedDisk = Join-Path -Path $TestDrive -ChildPath 'Alpha-Seed.iso'
        Set-Content -LiteralPath $seedDisk -Value 'password'
        Mock -ModuleName $module Get-VMDvdDrive { }
        Mock -ModuleName $module Remove-Item { throw 'The process cannot access the file because it is being used by another process.' } -ParameterFilter { $LiteralPath -eq $seedDisk }

        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('lazy', [securestring]::new()) }
        Mock -ModuleName $module Wait-GuestReady { }
        foreach ($step in 'Add-SqlDataDisk', 'Add-DevDriveDisk', 'Add-UserDataDisk', 'Connect-Guest', 'Expand-GuestSystemDrive',
            'Unlock-GuestDataDisk', 'Initialize-GuestSqlDisk', 'Initialize-GuestDevDrive', 'Initialize-GuestUserDisk',
            'Protect-GuestPersistentDisk', 'Enable-GuestEnhancedSession', 'Set-GuestCustomization',
            'Install-SqlServerIfMissing', 'Initialize-VMTooling') {
            Mock -ModuleName $module $step { }
        }
        $tooling = InModuleScope $module { [ToolingRecord]::new() }
        Mock -ModuleName $module Get-BuildTooling { $tooling }
        Mock -ModuleName $module Wait-GuestNetwork { $false }
        Mock -ModuleName $module Write-ToolingReinstallReport { $true }
    }

    It 'says to delete it by hand and returns CompleteWithProblems' {
        $outcome = InModuleScope $module -Parameters @{ SeedDisk = $seedDisk } {
            param($SeedDisk)
            @(Install-GuestSoftware -VM ([VMContext]::new(@{ VMName = 'Alpha'; SeedDiskPath = $SeedDisk; GuestWaitMinutes = 90; GuestNetworkWaitMinutes = 5 })) -UsedUnattend) |
                Where-Object { $_ -is [BuildOutcome] } | ForEach-Object { "$_" }
        }

        $outcome | Should -Be 'CompleteWithProblems'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*by hand*' -and $Level -eq 'WARN' }
    }
}

Describe 'Invoke-GuestTask when it times out' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Start-Sleep { }
        $guest = @{ TidyFails = $false }
        Mock -ModuleName $module Invoke-GuestScript {
            switch -Wildcard ($Activity) {
                'starting *' { 'boot1' }
                'checking on *' { [pscustomobject]@{ Done = $null; TaskState = 'Running'; BootTime = 'boot1' } }
                'tidying up *' { if ($guest.TidyFails) { throw 'The session state is Broken.' } }
            }
        }

        $run = {
            InModuleScope $module -Parameters @{ Settings = $settings } {
                param($Settings)
                Invoke-GuestTask -VM ([VMContext]::new($Settings)) -TaskName 'LazyVM-VSSettings' -Work { 'OK' } -TimeoutMinutes 0 -Activity 'Visual Studio settings restore'
            }
        }
    }

    It 'removes the guest task before reporting the timeout' {
        $run | Should -Throw -ExpectedMessage 'Visual Studio settings restore did not finish within*'

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'tidying up *' }
    }

    It 'still reports the timeout when the guest task cannot be removed' {
        $guest.TidyFails = $true

        $run | Should -Throw -ExpectedMessage 'Visual Studio settings restore did not finish within*'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*LazyVM-VSSettings*' -and $Level -eq 'WARN' }
    }
}
