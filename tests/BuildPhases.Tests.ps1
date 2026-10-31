# BuildPhases.Tests.ps1
# How the build reports a phase whose steps did not all succeed (#226): the
# phase is not called complete, and neither is the build. Nothing here needs
# Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }
}

Describe 'Invoke-BuildPhase' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Initialize-InstallationIso { }
        Mock -ModuleName $module Get-BuildPhase {
            [pscustomobject]@{ Number = 7; Name = 'Installs'; Action = { 'stray' } }
            [pscustomobject]@{ Number = 8; Name = 'Settings'; Action = { [BuildOutcome]::CompleteWithProblems } }
        }
    }

    It 'returns CompleteWithProblems when a phase finished with problems' {
        $outcome = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) "$(Invoke-BuildPhase -VM $VM)" }

        $outcome | Should -Be 'CompleteWithProblems'
    }

    It 'does not call that phase complete, and still calls the others complete' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) $null = Invoke-BuildPhase -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq 'Phase 7 complete' -and $Level -eq 'OK' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { $Message -eq 'Phase 8 complete' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like 'Phase 8 finished with problems*' -and $Level -eq 'WARN' }
    }

    It 'returns Complete when every phase completed' {
        Mock -ModuleName $module Get-BuildPhase { [pscustomobject]@{ Number = 7; Name = 'Installs'; Action = { } } }

        $outcome = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) "$(Invoke-BuildPhase -VM $VM)" }

        $outcome | Should -Be 'Complete'
    }

    It 'names the phases with problems and the phase to re-run from' {
        Mock -ModuleName $module Get-BuildPhase {
            [pscustomobject]@{ Number = 7; Name = 'Installs'; Action = { [BuildOutcome]::CompleteWithProblems } }
            [pscustomobject]@{ Number = 8; Name = 'Settings'; Action = { [BuildOutcome]::CompleteWithProblems } }
        }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) $null = Invoke-BuildPhase -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq 'Phases with problems: 7, 8 - re-run with -FromPhase 7 once the cause is fixed' -and $Level -eq 'WARN' }
    }
}

Describe 'Invoke-VMBuild' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-ResumePhase { 0 }
        Mock -ModuleName $module Unregister-ResumeTask { }
    }

    It 'clears the resume point after a build that finished with problems' {
        Mock -ModuleName $module Invoke-BuildPhase { 'CompleteWithProblems' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) $null = Invoke-VMBuild -VM $VM }

        Should -Invoke -ModuleName $module Unregister-ResumeTask -Times 1 -Exactly
    }
}

Describe 'Complete-GuestConfiguration' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('lazy', [securestring]::new()) }
        Mock -ModuleName $module Connect-Guest { }
        Mock -ModuleName $module Add-SqlDataDisk { }
        Mock -ModuleName $module Unlock-GuestDataDisk { }
        Mock -ModuleName $module Initialize-GuestSqlDisk { }
        Mock -ModuleName $module Move-GuestSqlDataFile { }
        Mock -ModuleName $module Restore-GuestVisualStudioSetting { }
        Mock -ModuleName $module Connect-GuestSqlInstance { }
    }

    It 'returns CompleteWithProblems when a step failed' {
        Mock -ModuleName $module Restore-GuestVisualStudioSetting { throw 'Visual Studio settings restore did not finish within 25 minute(s).' }

        $outcome = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) @(Complete-GuestConfiguration -VM $VM) | Where-Object { $_ -is [BuildOutcome] } | ForEach-Object { "$_" } }

        $outcome | Should -Be 'CompleteWithProblems'
    }

    It 'returns CompleteWithProblems when the VM is not running, because Phase 8 did not run' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Off' } }

        $outcome = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) @(Complete-GuestConfiguration -VM $VM) | Where-Object { $_ -is [BuildOutcome] } | ForEach-Object { "$_" } }

        $outcome | Should -Be 'CompleteWithProblems'
    }

    It 'returns CompleteWithProblems when the VM does not exist' {
        Mock -ModuleName $module Get-VM { }

        $outcome = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) @(Complete-GuestConfiguration -VM $VM) | Where-Object { $_ -is [BuildOutcome] } | ForEach-Object { "$_" } }

        $outcome | Should -Be 'CompleteWithProblems'
    }

    It 'leaves reporting a completed phase to Invoke-BuildPhase' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) $null = Complete-GuestConfiguration -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { $Message -eq 'Phase 8 complete' }
    }
}

Describe 'Install-GuestSoftware' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM { }
    }

    It 'returns CompleteWithProblems when the VM does not exist, because Phase 7 did not run' {
        $outcome = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) @(Install-GuestSoftware -VM $VM) | Where-Object { $_ -is [BuildOutcome] } | ForEach-Object { "$_" } }

        $outcome | Should -Be 'CompleteWithProblems'
    }
}
