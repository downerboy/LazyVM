@{
    Id         = 'restore-points'
    Title      = 'List tooling restore points'
    Command    = 'Get-LazyVMRestorePoint'
    Parameters = @('-Name <VM>')
    Summary    = 'Lists the recorded tooling versions you can return to.'
    Covers     = @('Get-ToolingRestorePoint', 'Get-LazyVMRestorePoint')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context and opens the log'
            Reads    = @(
                @{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') }
            )
        }
        @{
            Function = 'Get-ToolingRestorePoint'
            Area     = 'Tooling'
            Note     = 'one per "Tooling" checkpoint, oldest first, with whether its tooling list is still kept'
            Includes = @('Get-ToolingCheckpoint', 'Get-CheckpointStamp', 'Get-ProfileTooling')
            Reads    = @(
                @{ Label = 'checkpoints'; Kind = 'Hyper-V'; Store = '<VM>\Checkpoints\'; Items = @('"Tooling <stamp>"') }
                @{ Label = 'tooling lists'; Kind = 'file'; Store = '<VM>\Config\History\'; Items = @('VM-<stamp>.json') }
            )
            Writes   = @(
                @{ Label = 'restore points'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.RestorePoint: RestorePoint,', 'Taken, Checkpoint, HasToolingList') }
            )
        }
    )
}
