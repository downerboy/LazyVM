@{
    Id         = 'dashboard'
    Title      = 'See the dashboard data'
    Command    = 'Get-LazyVMDashboard'
    Parameters = @('-Name  (wildcards, default *)')
    Summary    = 'Lists every VM with what the dashboard shows: Get-LazyVM''s list, and each VM''s disks, memory, last maintenance, open findings and templates. Only reads. No administrator rights needed.'
    Covers     = @('Get-LazyVMDashboard', 'New-DashboardEntry', 'Get-VMDiskUsage', 'Get-MaintenanceRunSummary', 'Get-SecurityFindingSummary', 'Get-VMTemplateSummary')
    Omits      = @{}
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
            Function = 'Get-LazyVM'
            Area     = 'command'
            Note     = 'every VM matching -Name, with its state and maintenance task (see List VMs)'
            Reads    = @(
                @{ Label = 'profiles, state, task'; Kind = 'file'; Store = 'Get-LazyVM'; Items = @('<VM>\Config\VM.json', 'Hyper-V, Task Scheduler') }
            )
        }
        @{
            Function = 'New-DashboardEntry'
            Area     = 'Dashboard'
            Note     = 'per VM; a part it cannot read goes in Problems'
        }
        @{
            Function = 'Get-VM'
            External = $true
            Caller   = 'New-DashboardEntry'
            Area     = 'Hyper-V'
            Note     = 'built VMs only: when created, memory in use'
            Reads    = @(
                @{ Label = 'created, memory'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('CreationTime, MemoryAssigned') }
            )
        }
        @{
            Function = 'Get-VMDiskUsage'
            Caller   = 'New-DashboardEntry'
            Area     = 'Dashboard'
            Note     = 'built VMs only: each disk, with its checkpoint files (Get-VMHardDiskDrive, Get-VHD)'
            Reads    = @(
                @{ Label = 'disks'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('attached disks, file and maximum sizes') }
            )
        }
        @{
            Function = 'Read-VMSetting'
            Caller   = 'New-DashboardEntry'
            Area     = 'Settings'
            Note     = 'read-only; when the settings are OK'
            Reads    = @(
                @{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-MaintenanceRunSummary'
            Caller   = 'New-DashboardEntry'
            Area     = 'Dashboard'
            Note     = 'when the task is registered: last run and result (Get-ScheduledTaskInfo)'
            Reads    = @(
                @{ Label = 'last run'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>') }
            )
        }
        @{
            Function = 'Get-SecurityFindingSummary'
            Caller   = 'New-DashboardEntry'
            Area     = 'Dashboard'
            Note     = 'last scan, and findings neither approved nor resolved'
            Includes = @('Read-SecurityFindingRecord', 'Read-SecurityBaseline', 'Select-UnapprovedSecurityFinding')
            Reads    = @(
                @{ Label = 'last findings'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('SecurityFindings.json') }
                @{ Label = 'approvals'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') }
            )
        }
        @{
            Function = 'Get-VMTemplateSummary'
            Caller   = 'New-DashboardEntry'
            Area     = 'Dashboard'
            Note     = 'the configuration first built from, and the green template'
            Includes = @('Get-VMAsBuiltProfilePath', 'Get-AutomaticTemplateName', 'Get-UserTemplatePath')
            Reads    = @(
                @{ Label = 'templates'; Kind = 'file'; Store = 'Templates'; Items = @('<VM>\Config\VM.Template.json', 'Shared\Templates\<VM>-latest.json') }
            )
            Writes   = @(
                @{ Label = 'dashboard rows'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.Dashboard per VM') }
            )
        }
    )
}
