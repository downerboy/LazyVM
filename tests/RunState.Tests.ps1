# RunState.Tests.ps1
# Which long run a VM has going (#425): the run lock a build, maintenance or
# rebuild holds while it runs, the state only the holder writes, and how the
# dashboard reads both. Nothing here needs Hyper-V; the lock is a real file
# under $TestDrive, held by a second handle where a test needs another run.

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
            [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; ResumeFile = (Join-Path -Path $Config -ChildPath 'Resume.json'); LogFile = (Join-Path -Path $Root -ChildPath 'Alpha/Logs/Alpha.log'); LogMaxSizeMB = 10 })
        }
    }

    function Get-TestRunPath([object]$VM) {
        $config = Split-Path -Path $VM.Settings.ResumeFile -Parent
        [pscustomobject]@{ Lock = Join-Path -Path $config -ChildPath 'Run.lock'; State = Join-Path -Path $config -ChildPath 'Run.json' }
    }

    function Read-TestRunState([object]$VM, [string]$Command) {
        <# The latest run Run.json records, or the latest of $Command. #>
        $document = Get-Content -LiteralPath (Get-TestRunPath $VM).State -Raw | ConvertFrom-Json
        $document.Runs.$(if ($Command) { $Command } else { $document.Last })
    }

    function Set-TestRunState([object]$VM, [hashtable[]]$Runs) {
        <# Writes Run.json with $Runs, the last of them the latest. #>
        $byCommand = [ordered]@{}
        foreach ($run in $Runs) { $byCommand[$run.Command] = $run }
        $text = ConvertTo-Json -Depth 4 -InputObject @{ Last = $Runs[-1].Command; Runs = $byCommand }
        Set-Content -LiteralPath (Get-TestRunPath $VM).State -Value $text -NoNewline
        $text
    }

    function Lock-TestRun([object]$VM) {
        <# Holds the VM's run lock as another run would: shared with no one. #>
        [IO.File]::Open((Get-TestRunPath $VM).Lock, 'OpenOrCreate', 'ReadWrite', 'None')
    }
}

Describe 'Enter-VMRun and Exit-VMRun' {
    BeforeEach {
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        $vm = New-TestRunVM
    }

    AfterEach {
        # A test that fails half-way must not leave the lock held for the next.
        InModuleScope $module { if ($script:VMRun) { $script:VMRun.Lock.Dispose(); $script:VMRun = $null } }
    }

    It 'takes the lock and records the run as running, with its command, process and start' {
        $entered = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Enter-VMRun -VM $VM -Command 'Build' }

        $entered | Should -BeTrue
        $state = Read-TestRunState $vm
        $state.Command | Should -Be 'Build'
        $state.Status | Should -Be 'Running'
        $state.ProcessId | Should -Be $PID
        $state.Started | Should -Not -BeNullOrEmpty
        { Lock-TestRun $vm } | Should -Throw -Because 'the run holds the lock, shared with no one'
    }

    It 'keeps the latest run of each other command, so maintenance never hides where a build stopped' {
        $null = Set-TestRunState $vm @(@{ Command = 'Build'; Status = 'Failed'; Phase = 7; UnfinishedPhase = 7 })

        InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            $null = Enter-VMRun -VM $VM -Command 'Maintenance'
            Exit-VMRun -Status 'Completed'
        }

        (Read-TestRunState $vm).Command | Should -Be 'Maintenance'
        (Read-TestRunState $vm 'Build').UnfinishedPhase | Should -Be 7
    }

    It 'starts the record again when Run.json cannot be read, rather than stopping the run' {
        Set-Content -LiteralPath (Get-TestRunPath $vm).State -Value '{ not json'

        $entered = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Enter-VMRun -VM $VM -Command 'Build' }

        $entered | Should -BeTrue
        (Read-TestRunState $vm).Status | Should -Be 'Running'
    }

    It 'is refused while another run holds the lock, and writes nothing' {
        $before = Set-TestRunState $vm @(@{ Command = 'Maintenance'; Status = 'Running' })
        $other = Lock-TestRun $vm
        try {
            $entered = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Enter-VMRun -VM $VM -Command 'Build' }
            InModuleScope $module { Exit-VMRun -Status 'Failed' }
        }
        finally { $other.Dispose() }

        $entered | Should -BeFalse
        Get-Content -LiteralPath (Get-TestRunPath $vm).State -Raw | Should -Be $before
    }

    It 'tries a held lock again for a moment before giving up, since the dashboard opens it briefly' {
        $other = Lock-TestRun $vm
        try { $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Enter-VMRun -VM $VM -Command 'Build' } }
        finally { $other.Dispose() }

        Should -Invoke -ModuleName $module Start-Sleep -Times 4 -Exactly
    }

    It 'refuses a run started inside another in this process, leaving the outer run''s state alone' {
        $results = InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            Enter-VMRun -VM $VM -Command 'Maintenance'
            Enter-VMRun -VM $VM -Command 'Rebuild'
        }

        $results | Should -Be @($true, $false)
        (Read-TestRunState $vm).Command | Should -Be 'Maintenance'
        (Read-TestRunState $vm).Status | Should -Be 'Running'
    }

    It 'refuses a lock or state path with a reparse point in it, before opening anything' {
        Mock -ModuleName $module Assert-NoReparsePoint { throw "$Path is a link" }

        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Enter-VMRun -VM $VM -Command 'Build' } } | Should -Throw '*is a link*'
        Test-Path -LiteralPath (Get-TestRunPath $vm).Lock | Should -BeFalse
    }

    It 'records how it ended and frees the lock' {
        InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            $null = Enter-VMRun -VM $VM -Command 'Build'
            Exit-VMRun -Status 'Completed'
        }

        $state = Read-TestRunState $vm
        $state.Status | Should -Be 'Completed'
        $state.Ended | Should -Not -BeNullOrEmpty
        $state.UnfinishedPhase | Should -BeNullOrEmpty
        { (Lock-TestRun $vm).Dispose() } | Should -Not -Throw
    }

    It 'records the phase a <Status> run was in, so it can be run again from there' -ForEach @(
        @{ Status = 'Failed' }
        @{ Status = 'Stopped' }
    ) {
        InModuleScope $module -Parameters @{ VM = $vm; Status = $Status } {
            param($VM, $Status)
            $null = Enter-VMRun -VM $VM -Command 'Build'
            Set-VMRunPhase -Number 6 -Name 'VM Build'
            Exit-VMRun -Status $Status
        }

        $state = Read-TestRunState $vm
        $state.Status | Should -Be $Status
        $state.Phase | Should -Be 6
        $state.PhaseName | Should -Be 'VM Build'
        $state.UnfinishedPhase | Should -Be 6
    }

    It 'records an outcome the run set, such as <Outcome>, in place of Completed' -ForEach @(
        @{ Outcome = 'WaitingForRestart' }
        @{ Outcome = 'CompletedWithProblems' }
    ) {
        InModuleScope $module -Parameters @{ VM = $vm; Outcome = $Outcome } {
            param($VM, $Outcome)
            $null = Enter-VMRun -VM $VM -Command 'Build'
            Add-VMRunProblemPhase -Number 7
            Set-VMRunOutcome -Status $Outcome
            Exit-VMRun -Status 'Completed'
        }

        $state = Read-TestRunState $vm
        $state.Status | Should -Be $Outcome
        @($state.PhasesWithProblems) | Should -Be @(7)
    }

    It 'keeps Failed over an outcome set before the run failed' {
        InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            $null = Enter-VMRun -VM $VM -Command 'Build'
            Set-VMRunOutcome -Status 'CompletedWithProblems'
            Exit-VMRun -Status 'Failed'
        }

        (Read-TestRunState $vm).Status | Should -Be 'Failed'
    }

    It 'does nothing in a process that does not hold the lock' {
        { InModuleScope $module { Set-VMRunPhase -Number 3 -Name 'Folders'; Exit-VMRun -Status 'Completed' } } | Should -Not -Throw
        Test-Path -LiteralPath (Get-TestRunPath $vm).State | Should -BeFalse
    }

    It 'still frees the lock when the state cannot be written at the end, and says so in the log' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) $null = Enter-VMRun -VM $VM -Command 'Build' }
        Mock -ModuleName $module Write-TextFileAtomic { throw 'disk full' }

        { InModuleScope $module { Exit-VMRun -Status 'Completed' } } | Should -Not -Throw

        { (Lock-TestRun $vm).Dispose() } | Should -Not -Throw
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*disk full*' -and $Level -eq 'WARN' }
    }
}

Describe 'Get-VMRunState' {
    BeforeEach {
        $vm = New-TestRunVM
    }

    It 'returns nothing for a VM that has never had a run, and creates no file' {
        $state = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings }

        $state | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Get-TestRunPath $vm).Lock | Should -BeFalse
    }

    It 'reads a run that holds the lock as Running, with its phase' {
        $null = Set-TestRunState $vm @(@{ Command = 'Build'; Status = 'Running'; Phase = 7; PhaseName = 'Installs'; ProcessId = 42 })
        $other = Lock-TestRun $vm
        try { $state = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings } }
        finally { $other.Dispose() }

        $state.PSObject.TypeNames | Should -Contain 'LazyVM.VMRun'
        $state.Command | Should -Be 'Build'
        $state.Status | Should -Be 'Running'
        $state.Phase | Should -Be 7
        $state.PhaseName | Should -Be 'Installs'
        $state.ProcessId | Should -Be 42
    }

    It 'reads a run recorded as running whose lock is free as EndedUnexpectedly, in the phase it was in' {
        $null = Set-TestRunState $vm @(@{ Command = 'Build'; Status = 'Running'; Phase = 7 })
        (Lock-TestRun $vm).Dispose()

        $state = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings }

        $state.Status | Should -Be 'EndedUnexpectedly'
        $state.UnfinishedPhase | Should -Be 7
    }

    It 'reads a held lock as Running even before the new run has written its state' {
        $null = Set-TestRunState $vm @(@{ Command = 'Build'; Status = 'Completed'; Phase = 8 })
        $other = Lock-TestRun $vm
        try { $state = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings } }
        finally { $other.Dispose() }

        $state.Status | Should -Be 'Running'
        $state.Command | Should -BeNullOrEmpty
        $state.Phase | Should -BeNullOrEmpty
    }

    It 'reads the last run''s outcome once it ended' {
        $null = Set-TestRunState $vm @(@{ Command = 'Build'; Status = 'Failed'; Phase = 6; UnfinishedPhase = 6; PhasesWithProblems = @() })

        $state = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings }

        $state.Status | Should -Be 'Failed'
        $state.UnfinishedPhase | Should -Be 6
    }

    It 'reads the latest build with -Command Build, after a later maintenance run, and not as running while maintenance runs' {
        $null = Set-TestRunState $vm @(
            @{ Command = 'Build'; Status = 'Failed'; Phase = 7; UnfinishedPhase = 7 }
            @{ Command = 'Maintenance'; Status = 'Running' }
        )
        $other = Lock-TestRun $vm
        try {
            $latest = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings }
            $build = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings -Command 'Build' }
        }
        finally { $other.Dispose() }

        $latest.Command | Should -Be 'Maintenance'
        $latest.Status | Should -Be 'Running'
        $build.Status | Should -Be 'Failed'
        $build.UnfinishedPhase | Should -Be 7
    }

    It 'returns nothing with -Command for a command that has not run' {
        $null = Set-TestRunState $vm @(@{ Command = 'Maintenance'; Status = 'Completed' })

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-VMRunState -Settings $VM.Settings -Command 'Build' } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-CommandRun -Exclusive' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Start-Log { }
        Mock -ModuleName $module Stop-Log { }
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
        InModuleScope $module { $script:ran = $false }
    }

    It 'records the run as <Expected> when its work <Case>' -ForEach @(
        @{ Case = 'finishes'; Work = { }; Expected = 'Completed' }
        @{ Case = 'throws'; Work = { throw 'phase 6 broke' }; Expected = 'Failed' }
    ) {
        $work = $Work
        $null = InModuleScope $module -Parameters @{ Work = $work } {
            param($Work)
            function Test-Command { [CmdletBinding()] param([scriptblock]$Work) Invoke-CommandRun -Title 'Build' -Name 'Alpha' -FailureMessage 'Build stopped' -Cmdlet $PSCmdlet -Exclusive -ScriptBlock $Work }
            try { Test-Command -Work $Work } catch { $null = $_ }
        }

        (Read-TestRunState $vm).Status | Should -Be $Expected
    }

    It 'refuses to start while another run holds the lock, saying which, and leaves its state alone' {
        $before = Set-TestRunState $vm @(@{ Command = 'Maintenance'; Status = 'Running'; Started = '2026-11-17T02:00:00+00:00'; ProcessId = 42 })
        $other = Lock-TestRun $vm
        try {
            $thrown = InModuleScope $module {
                function Test-Command { [CmdletBinding()] param() Invoke-CommandRun -Title 'Build' -Name 'Alpha' -FailureMessage 'Build stopped' -Cmdlet $PSCmdlet -Exclusive -ScriptBlock { $script:ran = $true } }
                try { Test-Command; $null } catch { $_.Exception.Message }
            }
        }
        finally { $other.Dispose() }

        $thrown | Should -BeLike '*maintenance of Alpha is already running*'
        InModuleScope $module { $script:ran } | Should -BeFalse
        Get-Content -LiteralPath (Get-TestRunPath $vm).State -Raw | Should -Be $before
        # Nothing in the running one's log, where it would read as that run failing.
        Should -Invoke -ModuleName $module Start-Log -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogError -Times 0 -Exactly
    }

    It 'records the run as Stopped when it is stopped, as by Ctrl+C, which runs no catch block' {
        # The run goes in a pipeline of its own, so the stop ends only that pipeline.
        $stopped = [powershell]::Create('CurrentRunspace')
        $null = $stopped.AddScript({
                & (Get-Module -Name 'LazyVM') {
                    function Test-Command { [CmdletBinding()] param() Invoke-CommandRun -Title 'Build' -Name 'Alpha' -FailureMessage 'Build stopped' -Cmdlet $PSCmdlet -Exclusive -ScriptBlock { throw [System.Management.Automation.PipelineStoppedException]::new() } }
                    Test-Command
                }
            }.ToString())

        try { $null = $stopped.Invoke() } catch { $null = $_ }
        finally { $stopped.Dispose() }

        (Read-TestRunState $vm).Status | Should -Be 'Stopped'
        Should -Invoke -ModuleName $module Write-LogError -Times 0 -Exactly
    }

    It 'leaves the outer run''s lock and state alone when a run inside it is refused' {
        InModuleScope $module {
            function Test-Inner { [CmdletBinding()] param() Invoke-CommandRun -Title 'Rebuild' -Name 'Alpha' -FailureMessage 'x' -Cmdlet $PSCmdlet -Exclusive -ScriptBlock { } }
            function Test-Outer { [CmdletBinding()] param() Invoke-CommandRun -Title 'Maintenance' -Name 'Alpha' -FailureMessage 'x' -Cmdlet $PSCmdlet -Exclusive -ScriptBlock { try { Test-Inner } catch { $null = $_ }; $script:stillHeld = Test-VMRunEntered } }
            Test-Outer
        }

        InModuleScope $module { $script:stillHeld } | Should -BeTrue
        (Read-TestRunState $vm).Command | Should -Be 'Maintenance'
        (Read-TestRunState $vm).Status | Should -Be 'Completed'
    }

    It 'skips quietly with -SkipWhenBusy while another run holds the lock, and says so in the log' {
        $other = Lock-TestRun $vm
        try {
            { InModuleScope $module {
                    function Test-Command { [CmdletBinding()] param() Invoke-CommandRun -Title 'Maintenance' -Name 'Alpha' -FailureMessage 'Maintenance stopped' -Cmdlet $PSCmdlet -Exclusive -SkipWhenBusy -ScriptBlock { $script:ran = $true } }
                    Test-Command
                } } | Should -Not -Throw
        }
        finally { $other.Dispose() }

        InModuleScope $module { $script:ran } | Should -BeFalse
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*already running*skipping*' -and $Level -eq 'INFO' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { $Message -like '*LazyVM - *' }
    }

    It 'takes no lock without -Exclusive' {
        InModuleScope $module {
            function Test-Command { [CmdletBinding()] param() Invoke-CommandRun -Title 'Credential' -Name 'Alpha' -FailureMessage 'x' -Cmdlet $PSCmdlet -ScriptBlock { } }
            Test-Command
        }

        Test-Path -LiteralPath (Get-TestRunPath $vm).State | Should -BeFalse
    }
}

Describe 'Invoke-BuildPhase records each phase (#425)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Initialize-InstallationIso { }
        Mock -ModuleName $module Set-VMRunPhase { }
        Mock -ModuleName $module Add-VMRunProblemPhase { }
        Mock -ModuleName $module Get-BuildPhase {
            [pscustomobject]@{ Number = 7; Name = 'Installs'; Goal = 'Install'; Action = { } }
            [pscustomobject]@{ Number = 8; Name = 'Settings'; Goal = 'Set'; Action = { [BuildOutcome]::CompleteWithProblems } }
        }
        $vm = New-TestRunVM
    }

    It 'records each phase as it starts, and the phases that finished with problems' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) $null = Invoke-BuildPhase -VM $VM }

        Should -Invoke -ModuleName $module Set-VMRunPhase -Times 1 -Exactly -ParameterFilter { $Number -eq 7 -and $Name -eq 'Installs' }
        Should -Invoke -ModuleName $module Set-VMRunPhase -Times 1 -Exactly -ParameterFilter { $Number -eq 8 -and $Name -eq 'Settings' }
        Should -Invoke -ModuleName $module Add-VMRunProblemPhase -Times 1 -Exactly -ParameterFilter { $Number -eq 8 }
    }
}
