@{
    Id         = 'removal-plan'
    Title      = 'List what removing a VM deletes'
    Command    = 'Get-LazyVMRemovalPlan'
    Parameters = @('-Name <VM>')
    Summary    = 'What Remove-LazyVM would delete, with sizes, what it would keep and why, and the disks with your own work that go too, as one object. Only reads, and writes nothing, not even the log.'
    Covers     = @('Get-LazyVMRemovalPlan', 'Get-VMRemovalPreview')
    Omits      = @{
        'Assert-Administrator' = 'Hyper-V reports the VM''s disks only to an administrator'
        'Test-PathWithin'      = 'a path test used to sort what to delete'
    }
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
            Note     = 'read-only: the VM''s settings, and in Get-VMRemovalPreview every other VM''s, so nothing they use is listed'
            Reads    = @(
                @{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '*\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-VMRemovalPreview'
            Area     = 'Maintenance'
            Note     = 'what Remove-LazyVM deletes and keeps, as it decides it, with each item''s size'
            Includes = @('Get-VMProfileName', 'Get-DiskChain', 'Get-PathSize')
            Reads    = @(
                @{ Label = 'disks and checkpoints'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('disks of <VM>', 'disks of other VMs') }
                @{ Label = 'tasks'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'LazyVM-ResumeAfterReboot-<VM>') }
                @{ Label = 'files and sizes'; Kind = 'file'; Store = 'VM folder'; Items = @('<VM>\ and anything a setting put elsewhere') }
            )
        }
        @{
            Function = 'Get-VMRemovalPlan'
            Area     = 'Maintenance'
            Caller   = 'Get-VMRemovalPreview'
            Note     = 'decides what goes and what is kept, and why; stops when the VM folder holds something another VM uses'
            Includes = @('Assert-VMRootFolder', 'Get-VMOwnedPath', 'Get-ParentFolder')
            Writes   = @(
                @{ Label = 'removal plan'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.RemovalPlan: HyperVState,', 'CheckpointCount, Tasks, Items, Total,', 'Kept, WorkDisks') }
            )
        }
    )
}
