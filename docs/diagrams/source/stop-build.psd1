@{
    Id         = 'stop-build'
    Title      = 'Stop a running build'
    Command    = 'Stop-LazyVMBuild'
    Parameters = @('-Name <VM>  (optional with one VM)')
    Summary    = 'Asks the build running now to stop, and returns at once. The build stops at its next safe point: before the next phase or step, or while it waits for the VM or for work in the guest. It cleans up as a failed build does and records itself as Stopped. Work already started in the guest carries on by itself. Stops only a build: with maintenance or a rebuild running, it says so and changes nothing. Never takes the run lock.'
    Covers     = @('Stop-LazyVMBuild', 'Request-VMRunStop')
    Omits      = @{ 'Get-VMRunCommandText' = 'names the run that is not a build in the message' }
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder'
            Reads    = @(
                @{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'read-only: where the VM''s Config folder is'
            Reads    = @(
                @{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-VMRunState'
            Area     = 'Common'
            Note     = 'the run going now; stops, saying so, when none is, or when it is maintenance or a rebuild'
            Reads    = @(
                @{ Label = 'run'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('Run.lock (held or not)', 'Run.json', 'Run.stop') }
            )
        }
        @{
            Function = 'Request-VMRunStop'
            Area     = 'Common'
            Note     = 'unless -WhatIf: the stop request, naming the running build by its process and start, so it reaches no later run'
            Includes = @('Get-VMRunPath', 'Assert-NoReparsePoint', 'Write-TextFileAtomic')
            Writes   = @(
                @{ Label = 'stop request'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('Run.stop: ProcessId, Started, Requested') }
            )
        }
        @{
            Function = 'Get-VMRunState'
            Area     = 'Common'
            Note     = 'the build again, now with StopRequested'
            Writes   = @(
                @{ Label = 'build'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.VMRun, StopRequested true') }
            )
        }
    )
}
