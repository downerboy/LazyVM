# MaintenanceStart.Tests.ps1
# Running maintenance now (#428): Start-LazyVMMaintenance starts the VM's
# maintenance task, so the run is the nightly one, and starts nothing while
# another run of the VM is going or when the task is not there. Task
# Scheduler and the run state are mocked, so nothing here needs Hyper-V.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
}

Describe 'Start-LazyVMMaintenance' {
    BeforeEach {
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = 'C:\LazyVM'; Source = 'test' } }
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ Settings = @{ VMName = 'Alpha'; Root = 'C:\LazyVM'; ScheduleTaskName = 'LazyVM-Maintain-Alpha' } } }
        Mock -ModuleName $module Get-VMRunState { }
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LazyVM-Maintain-Alpha'; State = 'Ready' } }
        Mock -ModuleName $module Start-ScheduledTask { }
    }

    It 'starts the VM''s maintenance task and says which, and when' {
        $result = Start-LazyVMMaintenance -Name 'Alpha' -Confirm:$false

        Should -Invoke -ModuleName $module Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LazyVM-Maintain-Alpha' }
        $result.PSTypeNames | Should -Contain 'LazyVM.MaintenanceStart'
        $result.Name | Should -Be 'Alpha'
        $result.TaskName | Should -Be 'LazyVM-Maintain-Alpha'
        $result.Started | Should -BeOfType ([datetime])
    }

    It 'starts it after a run that has ended' {
        Mock -ModuleName $module Get-VMRunState { [pscustomobject]@{ Command = 'Build'; Status = 'Failed' } }

        $null = Start-LazyVMMaintenance -Name 'Alpha' -Confirm:$false

        Should -Invoke -ModuleName $module Start-ScheduledTask -Times 1 -Exactly
    }

    It 'starts nothing while <Command> is running, and says so' -ForEach @(
        @{ Command = 'Build'; Said = 'A build of Alpha is running*' }
        @{ Command = 'Maintenance'; Said = 'Maintenance of Alpha is running*' }
        @{ Command = 'Rebuild'; Said = 'A rebuild of Alpha is running*' }
        @{ Command = $null; Said = 'A run of Alpha is running*' }
    ) {
        Mock -ModuleName $module Get-VMRunState { [pscustomobject]@{ Command = $Command; Status = 'Running' } }.GetNewClosure()

        $result = Start-LazyVMMaintenance -Name 'Alpha' -ErrorVariable failed -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $failed.Count | Should -Be 1
        $failed[0].FullyQualifiedErrorId | Should -BeLike 'LazyVM.RunBusy*'
        "$($failed[0])" | Should -BeLike $Said
        Should -Invoke -ModuleName $module Start-ScheduledTask -Times 0 -Exactly
    }

    It 'says how to schedule maintenance when the task is not there' {
        Mock -ModuleName $module Get-ScheduledTask { }

        $result = Start-LazyVMMaintenance -Name 'Alpha' -ErrorVariable failed -ErrorAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $failed[0].FullyQualifiedErrorId | Should -BeLike 'LazyVM.MaintenanceNotScheduled*'
        "$($failed[0])" | Should -BeLike '*Register-LazyVMMaintenance -Name Alpha*'
        Should -Invoke -ModuleName $module Start-ScheduledTask -Times 0 -Exactly
    }

    It 'does not start the task again while it is running' {
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LazyVM-Maintain-Alpha'; State = 'Running' } }

        $null = Start-LazyVMMaintenance -Name 'Alpha' -ErrorVariable failed -ErrorAction SilentlyContinue

        $failed[0].FullyQualifiedErrorId | Should -BeLike 'LazyVM.RunBusy*'
        "$($failed[0])" | Should -BeLike '*running already*'
        Should -Invoke -ModuleName $module Start-ScheduledTask -Times 0 -Exactly
    }

    It 'starts nothing with -WhatIf' {
        $result = Start-LazyVMMaintenance -Name 'Alpha' -WhatIf

        $result | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Start-ScheduledTask -Times 0 -Exactly
    }

    It 'fails when Task Scheduler cannot start the task' {
        Mock -ModuleName $module Start-ScheduledTask { throw 'Access is denied.' }

        { Start-LazyVMMaintenance -Name 'Alpha' -Confirm:$false } | Should -Throw '*Access is denied*'
    }
}
