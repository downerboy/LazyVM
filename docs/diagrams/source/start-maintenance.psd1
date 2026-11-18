@{
    Id         = 'start-maintenance'
    Title      = 'Run maintenance now'
    Command    = 'Start-LazyVMMaintenance'
    Parameters = @('-Name <VM>  (optional with one VM)')
    Summary    = 'Starts the VM''s maintenance task, so maintenance runs exactly as its nightly run does, and returns at once. Starts nothing while a build, maintenance, rebuild, restore or removal of the VM is running, or when maintenance is not scheduled. Never takes the run lock: the task''s run does.'
    Covers     = @('Start-LazyVMMaintenance')
    Omits      = @{ 'Get-VMRunCommandText' = 'names the run going in the message' }
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
            Note     = 'read-only: the VM''s Config folder and its maintenance task''s name'
            Reads    = @(
                @{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-VMRunState'
            Area     = 'Common'
            Note     = 'the run going now; stops, saying so, while a build, maintenance or rebuild is running'
            Reads    = @(
                @{ Label = 'run'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('Run.lock (held or not)', 'Run.json', 'Run.stop') }
            )
        }
        @{
            Function = 'Get-ScheduledTask'
            External = $true
            Area     = 'Task Scheduler'
            Note     = 'the maintenance task; stops, saying so, when it is not registered or is running already'
            Reads    = @(
                @{ Label = 'maintenance task'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'State') }
            )
        }
        @{
            Function = 'Start-ScheduledTask'
            External = $true
            Area     = 'Task Scheduler'
            Note     = 'unless -WhatIf: starts the task, which runs Invoke-LazyVMMaintenance as SYSTEM'
            Writes   = @(
                @{ Label = 'maintenance run'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>  (started)') }
                @{ Label = 'start'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.MaintenanceStart: Name, TaskName, Started') }
            )
        }
    )
}
