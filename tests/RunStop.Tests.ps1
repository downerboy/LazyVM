# RunStop.Tests.ps1
# Stopping a running build cleanly (#426): Stop-LazyVMBuild writes a stop
# request for the run going now, and the run stops at its next safe point,
# with a stop that the code carrying on after failures lets through, and
# records itself as Stopped. Nothing here needs Hyper-V; the run lock is a
# real file under $TestDrive.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function New-TestRunVM {
        <# A VM context whose Config folder is a new folder under $TestDrive. #>
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $config = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Alpha/Config') -Force
        InModuleScope $module -Parameters @{ Root = $root; Config = $config.FullName } {
            param($Root, $Config)
            [VMContext]::new(@{
                    VMName         = 'Alpha'
                    Root           = $Root
                    ResumeFile     = (Join-Path -Path $Config -ChildPath 'Resume.json')
                    ResumeTaskName = 'LazyVM-Alpha-Resume'
                    SeedDiskPath   = (Join-Path -Path $Root -ChildPath 'Alpha/Alpha-Seed.iso')
                    LogFile        = (Join-Path -Path $Root -ChildPath 'Alpha/Logs/Alpha.log')
                    LogMaxSizeMB   = 10
                })
        }
    }

    function Get-TestRunPath([object]$VM) {
        $config = Split-Path -Path $VM.Settings.ResumeFile -Parent
        [pscustomobject]@{
            Lock  = Join-Path -Path $config -ChildPath 'Run.lock'
            State = Join-Path -Path $config -ChildPath 'Run.json'
            Stop  = Join-Path -Path $config -ChildPath 'Run.stop'
        }
    }

    function Read-TestRunState([object]$VM) {
        $document = Get-Content -LiteralPath (Get-TestRunPath $VM).State -Raw | ConvertFrom-Json
        $document.Runs.$($document.Last)
    }

    function Set-TestRunState([object]$VM, [hashtable]$Run) {
        $text = ConvertTo-Json -Depth 4 -InputObject @{ Last = $Run.Command; Runs = @{ $Run.Command = $Run } }
        Set-Content -LiteralPath (Get-TestRunPath $VM).State -Value $text -NoNewline
    }

    function Lock-TestRun([object]$VM) {
        <# Holds the VM's run lock as a run in another process would. #>
        [IO.File]::Open((Get-TestRunPath $VM).Lock, 'OpenOrCreate', 'ReadWrite', 'None')
    }

    function Enter-TestRun([object]$VM, [string]$Command = 'Build') {
        <# Takes the VM's run lock in this process, as the running build. #>
        $null = InModuleScope $module -Parameters @{ VM = $VM; Command = $Command } { param($VM, $Command) Enter-VMRun -VM $VM -Command $Command }
    }

    function Request-TestStop([object]$VM) {
        <# Asks the run this process holds to stop, as Stop-LazyVMBuild would from another process. #>
        InModuleScope $module -Parameters @{ VM = $VM } {
            param($VM)
            Request-VMRunStop -Settings $VM.Settings -Run ([pscustomobject]@{ ProcessId = $script:VMRun.State.ProcessId; Started = $script:VMRun.State.Started })
        }
    }

    function New-TestStop {
        <# A VMRunStoppedException, which only the module's code can name: a mock's body runs here. #>
        InModuleScope $module { [VMRunStoppedException]::new('stopped') }
    }

    function Exit-TestRun {
        InModuleScope $module { if ($script:VMRun) { $script:VMRun.Lock.Dispose(); $script:VMRun = $null } }
    }
}

Describe 'Assert-VMRunNotStopped' {
    BeforeEach {
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        $vm = New-TestRunVM
    }

    AfterEach { Exit-TestRun }

    It 'does nothing in a process that holds no run lock, whatever Run.stop says' {
        Set-Content -LiteralPath (Get-TestRunPath $vm).Stop -Value '{"ProcessId":1,"Started":"2026-11-16T10:00:00Z"}'

        { InModuleScope $module { Assert-VMRunNotStopped -Boundary } } | Should -Not -Throw
    }

    It 'does nothing while the run has not been asked to stop' {
        Enter-TestRun $vm

        { InModuleScope $module { Assert-VMRunNotStopped -Boundary } } | Should -Not -Throw
    }

    It 'stops a run asked to stop, naming the VM and the phase it is in, and says so in the log' {
        Enter-TestRun $vm
        InModuleScope $module { Set-VMRunPhase -Number 7 -Name 'Install' }
        Request-TestStop $vm

        $thrown = InModuleScope $module { try { Assert-VMRunNotStopped; $null } catch { $_ } }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        $thrown.Exception | Should -BeOfType [System.OperationCanceledException]
        $thrown.Exception.Message | Should -Be 'The build of Alpha was stopped in phase 7, Install, as asked.'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like 'Asked to stop*' -and $Level -eq 'WARN' }
    }

    It 'ignores a request for another run, such as one that has ended' {
        Enter-TestRun $vm
        InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            Request-VMRunStop -Settings $VM.Settings -Run ([pscustomobject]@{ ProcessId = $PID; Started = '2026-01-01T00:00:00Z' })
        }

        { InModuleScope $module { Assert-VMRunNotStopped -Boundary } } | Should -Not -Throw
    }

    It 'stops a wait only once, so the clean-up after it can wait in turn, but every phase and step after it' {
        Enter-TestRun $vm
        Request-TestStop $vm

        { InModuleScope $module { Assert-VMRunNotStopped } } | Should -Throw
        { InModuleScope $module { Assert-VMRunNotStopped } } | Should -Not -Throw -Because 'the clean-up waits for the guest too'
        { InModuleScope $module { Assert-VMRunNotStopped -Boundary } } | Should -Throw -Because 'a stop taken for a failure still stops the next phase or step'
    }

    It 'is not stopped by a request left over from an earlier run, which taking the lock removes' {
        Set-Content -LiteralPath (Get-TestRunPath $vm).Stop -Value "{`"ProcessId`":$PID,`"Started`":`"2026-11-16T10:00:00Z`"}"

        Enter-TestRun $vm

        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }

    It 'removes the request when the run ends' {
        Enter-TestRun $vm
        Request-TestStop $vm

        InModuleScope $module { Exit-VMRun -Status 'Stopped' }

        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }
}

Describe 'Find-VMRunStoppedException' {
    It 'finds the stop <Case>' -ForEach @(
        @{ Case = 'itself' }
        @{ Case = 'as an inner exception' }
        @{ Case = 'in the error record of an exception' }
    ) {
        $found = InModuleScope $module -Parameters @{ Case = $Case } {
            param($Case)
            $stop = [VMRunStoppedException]::new('stopped')
            $exception = switch ($Case) {
                'itself' { $stop }
                'as an inner exception' { [InvalidOperationException]::new('wrapped', $stop) }
                default { [System.Management.Automation.RuntimeException]::new('carried', $null, [System.Management.Automation.ErrorRecord]::new($stop, 'Stop', 'OperationStopped', $null)) }
            }
            Find-VMRunStoppedException -Exception $exception
        }

        $found.Message | Should -Be 'stopped'
    }

    It 'finds nothing in a failure' {
        InModuleScope $module { Test-VMRunStoppedError -Exception ([InvalidOperationException]::new('broke')) } | Should -BeFalse
    }
}

Describe 'A stop goes through what carries on after failures' {
    BeforeEach {
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        $vm = New-TestRunVM
    }

    AfterEach { Exit-TestRun }

    It 'Invoke-IsolatedStep lets the stop up, without counting it as a failure or running the steps after it' {
        $thrown = InModuleScope $module {
            $script:secondRan = $false
            $steps = @(
                @{ Name = 'First'; Action = { throw [VMRunStoppedException]::new('stopped') } }
                @{ Name = 'Second'; Action = { $script:secondRan = $true } }
            )
            try { $null = Invoke-IsolatedStep -What 'test' -Steps $steps; $null } catch { $_ }
        }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        InModuleScope $module { $script:secondRan } | Should -BeFalse
        Should -Invoke -ModuleName $module Write-LogError -Times 0 -Exactly
    }

    It 'Invoke-IsolatedStep stops before the next step when the run is asked to stop' {
        Enter-TestRun $vm
        Request-TestStop $vm

        $thrown = InModuleScope $module {
            $script:stepRan = $false
            try { $null = Invoke-IsolatedStep -What 'test' -Steps @(@{ Name = 'Only'; Action = { $script:stepRan = $true } }); $null } catch { $_ }
        }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        InModuleScope $module { $script:stepRan } | Should -BeFalse
    }

    It 'Invoke-GuestScript -RetryOnDisconnect does not run the script again after a stop' {
        $stop = New-TestStop
        Mock -ModuleName $module Invoke-GuestScriptJob { throw $stop }.GetNewClosure()
        Mock -ModuleName $module Test-GuestSessionOpen { $false }

        $thrown = InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            try { Invoke-GuestScript -VM $VM -ScriptBlock { } -RetryOnDisconnect; $null } catch { $_ }
        }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        Should -Invoke -ModuleName $module Invoke-GuestScriptJob -Times 1 -Exactly
    }

    It 'Wait-Until stops before its next try, even with -NoThrow' {
        Enter-TestRun $vm
        Request-TestStop $vm

        $thrown = InModuleScope $module {
            $script:tried = $false
            try { $null = Wait-Until -Timeout ([timespan]::FromMinutes(5)) -NoThrow -Condition { $script:tried = $true; $false }; $null } catch { $_ }
        }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        InModuleScope $module { $script:tried } | Should -BeFalse
    }

    It 'Invoke-GuestTask only unregisters its guest task on a stop, leaving the work in the guest running' {
        Mock -ModuleName $module Invoke-GuestScript { 'boot' }
        $stop = New-TestStop
        Mock -ModuleName $module Wait-Until { throw $stop }.GetNewClosure()

        $thrown = InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            try { Invoke-GuestTask -VM $VM -TaskName 'LazyVM-Test' -Work { } -TimeoutMinutes 5 -Activity 'the test'; $null } catch { $_ }
        }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'tidying up*' -and $ArgumentList[1] -eq $true }
    }

    It 'Invoke-GuestTask still stops its guest task after a failure' {
        Mock -ModuleName $module Invoke-GuestScript { 'boot' }
        Mock -ModuleName $module Wait-Until { throw 'timed out' }

        $null = InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            try { Invoke-GuestTask -VM $VM -TaskName 'LazyVM-Test' -Work { } -TimeoutMinutes 5 -Activity 'the test' } catch { $null = $_ }
        }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'tidying up*' -and $ArgumentList[1] -eq $false }
    }
}

Describe 'A build asked to stop' {
    BeforeEach {
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Initialize-InstallationIso { }
        Mock -ModuleName $module Remove-UnattendSeedDisk { $true }
        Mock -ModuleName $module Get-VM { }
        $vm = New-TestRunVM
        Set-Content -LiteralPath $vm.Settings.SeedDiskPath -Value 'disc'
        InModuleScope $module { $script:phaseRan = @() }
        Mock -ModuleName $module Get-BuildPhase {
            [pscustomobject]@{ Number = 6; Name = 'VM Build'; Goal = 'Create'; Action = { $script:phaseRan += 6 } }
            [pscustomobject]@{ Number = 7; Name = 'Install'; Goal = 'Install'; Action = { $script:phaseRan += 7 } }
        }
    }

    AfterEach { Exit-TestRun }

    It 'stops before the next phase, removes the answer-file disc, and records that phase as the one to run from' {
        Enter-TestRun $vm
        Request-TestStop $vm

        $thrown = InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            try { $null = Invoke-BuildPhase -VM $VM -FromPhase 6; $null } catch { $_ }
            Exit-VMRun -Status 'Stopped'
        }

        $thrown.Exception.GetType().Name | Should -Be 'VMRunStoppedException'
        InModuleScope $module { $script:phaseRan } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Remove-UnattendSeedDisk -Times 1 -Exactly
        $state = Read-TestRunState $vm
        $state.Status | Should -Be 'Stopped'
        $state.UnfinishedPhase | Should -Be 6
    }

    It 'removes the resume task, so it does not start again by itself, but keeps where to carry on from' {
        Mock -ModuleName $module Get-ResumePhase { 3 }
        Mock -ModuleName $module Unregister-ResumeTask { }
        $stop = New-TestStop
        Mock -ModuleName $module Invoke-BuildPhase { throw $stop }.GetNewClosure()

        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-VMBuild -VM $VM } } | Should -Throw -ExceptionType ([System.OperationCanceledException])

        Should -Invoke -ModuleName $module Unregister-ResumeTask -Times 1 -Exactly -ParameterFilter { $KeepResumePoint }
    }

    It 'leaves the resume task alone after a failure, so a crash while resuming keeps it' {
        Mock -ModuleName $module Get-ResumePhase { 3 }
        Mock -ModuleName $module Unregister-ResumeTask { }
        Mock -ModuleName $module Invoke-BuildPhase { throw 'broke' }

        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Invoke-VMBuild -VM $VM } } | Should -Throw

        Should -Invoke -ModuleName $module Unregister-ResumeTask -Times 0 -Exactly
    }
}

Describe 'Invoke-CommandRun with a run asked to stop' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Start-Log { }
        Mock -ModuleName $module Stop-Log { }
        Mock -ModuleName $module Test-LogStarted { $true }
        Mock -ModuleName $module Initialize-ConfigFolder { }
        Mock -ModuleName $module Move-ToolingIntoProfile { $false }
        Mock -ModuleName $module Sync-GuestUserFromStore { }
        Mock -ModuleName $module Write-RunReminder { }
        Mock -ModuleName $module Test-Unattended { $false }
        Mock -ModuleName $module Get-TrustedHostPath { }
        $vm = New-TestRunVM
        $root = $vm.Settings.Root
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'test' } }.GetNewClosure()
        $settings = $vm.Settings
        Mock -ModuleName $module Read-TrustedVMSetting { [pscustomobject]@{ Settings = $settings; ProfilePath = 'VM.json'; MissingKeys = @(); Warnings = @() } }.GetNewClosure()
    }

    AfterEach { Exit-TestRun }

    It 'records the run as Stopped, not Failed, and ends with the error LazyVM.RunStopped' {
        $thrown = InModuleScope $module {
            function Test-Command {
                [CmdletBinding()] param()
                Invoke-CommandRun -Title 'Build' -Name 'Alpha' -FailureMessage 'Build stopped' -Cmdlet $PSCmdlet -Exclusive -ScriptBlock {
                    param($VM)
                    Set-VMRunPhase -Number 7 -Name 'Install'
                    Request-VMRunStop -Settings $VM.Settings -Run ([pscustomobject]@{ ProcessId = $script:VMRun.State.ProcessId; Started = $script:VMRun.State.Started })
                    Assert-VMRunNotStopped -Boundary
                }
            }
            try { Test-Command; $null } catch { $_ }
        }

        $thrown.FullyQualifiedErrorId | Should -BeLike 'LazyVM.RunStopped*'
        $thrown.Exception.Message | Should -Be 'The build of Alpha was stopped in phase 7, Install, as asked.'
        $state = Read-TestRunState $vm
        $state.Status | Should -Be 'Stopped'
        $state.UnfinishedPhase | Should -Be 7
        Should -Invoke -ModuleName $module Write-LogError -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like 'The build of Alpha was stopped*' -and $Level -eq 'WARN' }
        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }
}

Describe 'Stop-LazyVMBuild' {
    BeforeEach {
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        $vm = New-TestRunVM
        $root = $vm.Settings.Root
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'test' } }.GetNewClosure()
        $settings = $vm.Settings
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ Settings = $settings } }.GetNewClosure()
        $started = '2026-11-16T10:00:00.0000000+00:00'
    }

    AfterEach { Exit-TestRun }

    It 'says no build is running, and writes nothing, when none is' {
        $result = Stop-LazyVMBuild -Name 'Alpha' -WarningVariable warned -WarningAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        "$warned" | Should -BeLike '*No build of Alpha is running*'
        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }

    It 'says no build is running when the last one ended, even if Run.json still says running' {
        Set-TestRunState $vm @{ Command = 'Build'; Status = 'Running'; ProcessId = 4242; Started = $started }

        $null = Stop-LazyVMBuild -Name 'Alpha' -WarningVariable warned -WarningAction SilentlyContinue

        "$warned" | Should -BeLike '*No build of Alpha is running*'
        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }

    It 'stops nothing while <Command> is running, and says so' -ForEach @(
        @{ Command = 'Maintenance' }
        @{ Command = 'Rebuild' }
    ) {
        Set-TestRunState $vm @{ Command = $Command; Status = 'Running'; ProcessId = 4242; Started = $started }
        $other = Lock-TestRun $vm
        try { $null = Stop-LazyVMBuild -Name 'Alpha' -ErrorVariable failed -ErrorAction SilentlyContinue }
        finally { $other.Dispose() }

        $refusal = @($failed | Where-Object { $_.FullyQualifiedErrorId -like 'LazyVM.NotABuild*' })
        $refusal.Count | Should -Be 1
        "$refusal" | Should -BeLike '*not a build, so nothing was stopped*'
        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }

    It 'asks the running build to stop, and returns it with StopRequested' {
        Set-TestRunState $vm @{ Command = 'Build'; Status = 'Running'; ProcessId = 4242; Started = $started; Phase = 7; PhaseName = 'Install' }
        $other = Lock-TestRun $vm
        try { $result = Stop-LazyVMBuild -Name 'Alpha' -Confirm:$false }
        finally { $other.Dispose() }

        $result.Command | Should -Be 'Build'
        $result.Phase | Should -Be 7
        $result.StopRequested | Should -BeTrue
        $request = Get-Content -LiteralPath (Get-TestRunPath $vm).Stop -Raw | ConvertFrom-Json
        $request.ProcessId | Should -Be 4242
    }

    It 'writes nothing with -WhatIf' {
        Set-TestRunState $vm @{ Command = 'Build'; Status = 'Running'; ProcessId = 4242; Started = $started }
        $other = Lock-TestRun $vm
        try { $null = Stop-LazyVMBuild -Name 'Alpha' -WhatIf }
        finally { $other.Dispose() }

        Test-Path -LiteralPath (Get-TestRunPath $vm).Stop | Should -BeFalse
    }

    It 'reaches the build it read, which then stops at its next safe point' {
        Enter-TestRun $vm

        $result = Stop-LazyVMBuild -Name 'Alpha' -Confirm:$false

        $result.StopRequested | Should -BeTrue
        { InModuleScope $module { Assert-VMRunNotStopped -Boundary } } | Should -Throw -ExceptionType ([System.OperationCanceledException])
    }
}
