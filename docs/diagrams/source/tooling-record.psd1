@{
    Id         = 'tooling-record'
    Title      = 'Record tooling now'
    Command    = 'Save-LazyVMTooling'
    Parameters = @('-Name <VM>')
    Summary    = 'Does now what maintenance does every day. Get-LazyVMTooling shows the same comparison without recording anything.'
    Covers     = @('Save-LazyVMTooling')
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
            Function = 'Open-GuestSession'
            Area     = 'Tooling'
            Note     = 'starts the VM if it is off, connects with PowerShell Direct'
            Reads    = @(
                @{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'VM started if it was off'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('running') }
            )
        }
        @{
            Function = 'Update-ToolingRecord'
            Area     = 'Tooling'
            Note     = 'takes the checkpoint before adopting a change'
            Reads    = @(
                @{ Label = 'what is installed'; Kind = 'guest'; Store = 'Guest tooling'; Items = @('vswhere + vs_installer export', 'winget export', 'Marketplace extensions') }
                @{ Label = 'last recorded tooling list'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') }
            )
            Writes   = @(
                @{ Label = 'checkpoint, only on a change'; Kind = 'Hyper-V'; Store = '<VM>\Checkpoints\'; Items = @('checkpoint "Tooling <stamp>"', 'oldest pruned past ToolingCheckpointsToKeep (3)') }
                @{ Label = 'new tooling version, only on a change'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json', 'History\VM-<stamp>.json') }
            )
        }
        @{
            Function = 'Stop-GuestGracefully'
            Area     = 'Maintenance'
            Note     = 'only if this run started the VM'
            Writes   = @(
                @{ Label = 'VM back off'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('off') }
            )
        }
    )
}
