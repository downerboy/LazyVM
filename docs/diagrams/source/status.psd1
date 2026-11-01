@{
    Id         = 'status'
    Title      = 'List VMs'
    Command    = 'Get-LazyVM'
    Parameters = @('-Name  (wildcards, default *)')
    Summary    = 'Lists the VMs in the LazyVM folder with their state and maintenance. No administrator rights needed.'
    Covers     = @('Get-LazyVM')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder'
            Reads    = @(
                @{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'Get-VMProfileName'
            Area     = 'Settings'
            Note     = 'every VM with a profile, matching -Name'
            Includes = @('Get-VMProfilePath')
            Reads    = @(
                @{ Label = 'profiles'; Kind = 'file'; Store = '*\Config\'; Items = @('VM.json') }
            )
        }
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'per VM'
            Reads    = @(
                @{ Label = 'MaintenanceTime, settings errors'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-VM'
            External = $true
            Area     = 'Hyper-V'
            Note     = 'per VM'
            Reads    = @(
                @{ Label = 'state'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('VM state') }
            )
        }
        @{
            Function = 'Get-ScheduledTask'
            External = $true
            Includes = @('Get-MaintenanceTaskName')
            Area     = 'ScheduledTasks'
            Note     = 'per VM'
            Reads    = @(
                @{ Label = 'task registered?'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>') }
            )
            Writes   = @(
                @{ Label = 'VM list'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.VM per VM') }
            )
        }
    )
}
