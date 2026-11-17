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

Describe 'Get-BuildPhase goals (#422)' {
    It 'gives every phase a goal, shown after "Phase N:"' {
        foreach ($phase in InModuleScope $module { @(Get-BuildPhase) }) {
            $phase.Goal | Should -Not -BeNullOrEmpty -Because "phase $($phase.Number) needs a goal"
            $phase.Goal | Should -MatchExactly '^[A-Z]' -Because "phase $($phase.Number)'s goal starts with a capital"
            $phase.Goal | Should -Not -Match '\.$' -Because "phase $($phase.Number)'s goal follows 'Phase N:', with no full stop"
        }
    }

    It 'numbers the phases from 0, one after another' {
        $numbers = InModuleScope $module { @(Get-BuildPhase | ForEach-Object { $_.Number }) }

        $numbers | Should -Be @(0..($numbers.Count - 1))
    }
}

Describe 'Get-LazyVMBuildPhase (#422)' {
    It 'returns every phase in order, with its number, name and goal' {
        $expected = InModuleScope $module { @(Get-BuildPhase) }

        $phases = @(Get-LazyVMBuildPhase)

        $phases.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $phases.Count; $i++) {
            $phases[$i].Number | Should -Be $expected[$i].Number
            $phases[$i].Name | Should -Be $expected[$i].Name
            $phases[$i].Goal | Should -Be $expected[$i].Goal
        }
    }

    It 'returns LazyVM.BuildPhase objects, without the code that runs the phase' {
        $phase = @(Get-LazyVMBuildPhase)[0]

        $phase.PSObject.TypeNames | Should -Contain 'LazyVM.BuildPhase'
        $phase.PSObject.Properties.Name | Should -Be @('Number', 'Name', 'Goal')
    }

    It 'needs no VM, no LazyVM folder and no administrator rights' {
        Mock -ModuleName $module Assert-Administrator { throw 'not elevated' }
        Mock -ModuleName $module Resolve-LazyVMRoot { throw 'no LazyVM folder' }

        { Get-LazyVMBuildPhase } | Should -Not -Throw
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

    It 'sets up Sysmon in the guest (#236)' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('lazy', [securestring]::new()) }
        foreach ($step in 'Wait-GuestReady', 'Add-SqlDataDisk', 'Add-DevDriveDisk', 'Add-UserDataDisk', 'Connect-Guest',
            'Expand-GuestSystemDrive', 'Unlock-GuestDataDisk', 'Initialize-GuestSqlDisk', 'Initialize-GuestDevDrive', 'Initialize-GuestUserDisk',
            'Protect-GuestPersistentDisk', 'Enable-GuestEnhancedSession', 'Set-GuestCustomization', 'Set-GuestSysmon', 'Set-GuestEventLogging',
            'Wait-GuestNetwork', 'Install-SqlServerIfMissing', 'Restore-GuestRecordedAppSetting', 'Initialize-VMTooling') {
            Mock -ModuleName $module $step { }
        }
        # Classes defined in a module are only visible inside it.
        $tooling = InModuleScope $module { [ToolingRecord]::new() }
        Mock -ModuleName $module Get-BuildTooling { $tooling }
        Mock -ModuleName $module Write-ToolingReinstallReport { $true }

        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestWaitMinutes = 1; GuestNetworkWaitMinutes = 1 }) }

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-GuestSoftware -VM $VM }

        Should -Invoke -ModuleName $module Set-GuestSysmon -Times 1 -Exactly
    }

    It 'sets the event logs, audit policy and PowerShell logging in the guest, after Sysmon (#291)' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('lazy', [securestring]::new()) }
        foreach ($step in 'Wait-GuestReady', 'Add-SqlDataDisk', 'Add-DevDriveDisk', 'Add-UserDataDisk', 'Connect-Guest',
            'Expand-GuestSystemDrive', 'Unlock-GuestDataDisk', 'Initialize-GuestSqlDisk', 'Initialize-GuestDevDrive', 'Initialize-GuestUserDisk',
            'Protect-GuestPersistentDisk', 'Enable-GuestEnhancedSession', 'Set-GuestCustomization',
            'Wait-GuestNetwork', 'Install-SqlServerIfMissing', 'Restore-GuestRecordedAppSetting', 'Initialize-VMTooling') {
            Mock -ModuleName $module $step { }
        }
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Set-GuestSysmon { $script:order.Add('sysmon') }
        Mock -ModuleName $module Set-GuestEventLogging { $script:order.Add('event logging') }
        $tooling = InModuleScope $module { [ToolingRecord]::new() }
        Mock -ModuleName $module Get-BuildTooling { $tooling }
        Mock -ModuleName $module Write-ToolingReinstallReport { $true }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestWaitMinutes = 1; GuestNetworkWaitMinutes = 1 }) }

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-GuestSoftware -VM $VM }

        $script:order -join ',' | Should -Be 'sysmon,event logging'
    }
}

Describe 'Install-GuestSoftware Windows updates (#234)' {
    BeforeAll {
        $buildVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestWaitMinutes = 1; GuestNetworkWaitMinutes = 1 }) }
        $emptyTooling = InModuleScope $module { [ToolingRecord]::new() }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('lazy', [securestring]::new()) }
        foreach ($step in 'Wait-GuestReady', 'Remove-UnattendSeedDisk', 'Add-SqlDataDisk', 'Add-DevDriveDisk', 'Add-UserDataDisk',
            'Connect-Guest', 'Expand-GuestSystemDrive', 'Unlock-GuestDataDisk', 'Initialize-GuestSqlDisk', 'Initialize-GuestDevDrive', 'Initialize-GuestUserDisk',
            'Protect-GuestPersistentDisk', 'Enable-GuestEnhancedSession', 'Set-GuestCustomization', 'Set-GuestSysmon', 'Set-GuestEventLogging', 'Install-ToolingProduct',
            'Install-SqlServerIfMissing', 'Install-WingetPackage', 'Install-OfficialInstaller', 'Restore-GuestRecordedAppSetting', 'Initialize-VMTooling') {
            Mock -ModuleName $module $step { }
        }
        Mock -ModuleName $module Get-BuildTooling { $emptyTooling }
        Mock -ModuleName $module Wait-GuestNetwork { $true }
        Mock -ModuleName $module Write-ToolingReinstallReport { $true }
        Mock -ModuleName $module Update-GuestWindows { $false }
        Mock -ModuleName $module Wait-GuestSettled { }
    }

    It 'waits for the guest to settle after it restarted it for the updates, before going on (#276)' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Update-GuestWindows { $script:order.Add('updates'); $true }
        Mock -ModuleName $module Wait-GuestSettled { $script:order.Add('settle') }
        Mock -ModuleName $module Initialize-VMTooling { $script:order.Add('tooling record') }

        $null = InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM }

        $script:order -join ',' | Should -Be 'updates,settle,tooling record'
    }

    It 'does not wait for the guest to settle when the updates did not restart it (#276)' {
        $null = InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM }

        Should -Invoke -ModuleName $module Wait-GuestSettled -Times 0 -Exactly
    }

    It 'installs Windows updates after the tooling, and may restart the new VM for them' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Install-OfficialInstaller { $script:order.Add('tooling') }
        Mock -ModuleName $module Update-GuestWindows { $script:order.Add('updates') }

        $null = InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM }

        $script:order -join ',' | Should -Be 'tooling,updates'
        Should -Invoke -ModuleName $module Update-GuestWindows -Times 1 -Exactly -ParameterFilter { $StartedByLazyVM }
    }

    It 'carries on when Windows updates fail, without failing the phase' {
        Mock -ModuleName $module Update-GuestWindows { throw 'Windows Update is broken' }

        $outcome = @(InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM })

        $outcome.Count | Should -Be 0
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }

    It 'puts back the application settings VM.json records once the applications and updates are in, so a VM built from a template starts with them (#325)' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Update-GuestWindows { $script:order.Add('updates'); $false }
        Mock -ModuleName $module Restore-GuestRecordedAppSetting { $script:order.Add('app settings'); $true }
        Mock -ModuleName $module Initialize-VMTooling { $script:order.Add('tooling record') }

        $null = InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM }

        $script:order -join ',' | Should -Be 'updates,app settings,tooling record'
    }

    It 'carries on when the application settings cannot be put back, without failing the phase (#325)' {
        Mock -ModuleName $module Restore-GuestRecordedAppSetting { throw 'the guest went away' }

        $outcome = @(InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM })

        $outcome.Count | Should -Be 0
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }

    It 'skips Windows updates when the guest has no network' {
        Mock -ModuleName $module Wait-GuestNetwork { $false }

        $null = InModuleScope $module -Parameters @{ VM = $buildVM } { param($VM) Install-GuestSoftware -VM $VM }

        Should -Invoke -ModuleName $module Update-GuestWindows -Times 0
    }
}
