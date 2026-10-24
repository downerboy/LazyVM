# GuestOSDisk.Tests.ps1
# Extending C: (Expand-GuestSystemDrive) runs in every build and every
# maintenance run. It must change nothing when there is nothing to do, take a
# checkpoint before changing anything, keep it and stop retrying when
# something fails, and never stop the run. The guest and Hyper-V are mocked;
# nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Classes defined in a module are only visible inside it.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }
}

Describe 'Expand-GuestSystemDrive' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Get-ExpansionCheckpoint { @() }
        Mock -ModuleName $module New-ToolingCheckpoint { }
        Mock -ModuleName $module Remove-ExpansionCheckpoint { }
    }

    It 'changes and logs nothing when C: already has the whole disk' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Action = 'None'; Reason = '' } } -ParameterFilter { $Activity -eq 'OS disk check' }
        Mock -ModuleName $module Invoke-GuestScript { throw 'must not run' } -ParameterFilter { $Activity -eq 'C: drive expansion' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Expand-GuestSystemDrive -VM $VM }

        Should -Invoke -ModuleName $module New-ToolingCheckpoint -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -Exactly
    }

    It 'takes a checkpoint first, then removes it once everything worked' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Action = 'Expand'; Reason = '20480 MB of the OS disk is unused' } } -ParameterFilter { $Activity -eq 'OS disk check' }
        Mock -ModuleName $module Invoke-GuestScript { @([pscustomobject]@{ Level = 'OK'; Text = 'C: resized from 120 GB to 139 GB' }, [pscustomobject]@{ Level = 'OK'; Text = 'recovery partition moved' }) } -ParameterFilter { $Activity -eq 'C: drive expansion' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Expand-GuestSystemDrive -VM $VM }

        Should -Invoke -ModuleName $module New-ToolingCheckpoint -Times 1 -Exactly -ParameterFilter { $Name -like 'C: expansion *' -and $SkipPrune }
        Should -Invoke -ModuleName $module Remove-ExpansionCheckpoint -Times 1 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*resized from 120 GB to 139 GB' -and $Level -eq 'OK' }
    }

    It 'keeps the checkpoint and says how to go back when something failed' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Action = 'Expand'; Reason = 'x' } } -ParameterFilter { $Activity -eq 'OS disk check' }
        Mock -ModuleName $module Invoke-GuestScript { @([pscustomobject]@{ Level = 'WARN'; Text = 'reagentc /enable failed' }) } -ParameterFilter { $Activity -eq 'C: drive expansion' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Expand-GuestSystemDrive -VM $VM }

        Should -Invoke -ModuleName $module Remove-ExpansionCheckpoint -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*Restore-VMSnapshot*' -and $Level -eq 'WARN' }
    }

    It 'changes nothing when no checkpoint can be taken' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Action = 'Expand'; Reason = 'x' } } -ParameterFilter { $Activity -eq 'OS disk check' }
        Mock -ModuleName $module Invoke-GuestScript { throw 'must not run' } -ParameterFilter { $Activity -eq 'C: drive expansion' }
        Mock -ModuleName $module New-ToolingCheckpoint { throw 'checkpoints are off' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Expand-GuestSystemDrive -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { $Activity -eq 'C: drive expansion' }
    }

    It 'does not try again while the checkpoint of a failed attempt exists' {
        Mock -ModuleName $module Get-ExpansionCheckpoint { @('C: expansion 20261018-180159') }
        Mock -ModuleName $module Invoke-GuestScript { throw 'must not run' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Expand-GuestSystemDrive -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*earlier attempt*' -and $Level -eq 'WARN' }
    }

    It 'logs a failure instead of throwing, so the run carries on' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'the guest went away' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Expand-GuestSystemDrive -VM $VM } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }
}
