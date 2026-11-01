@{
    Id         = 'tooling-view'
    Title      = 'See installed tooling'
    Command    = 'Get-LazyVMTooling'
    Parameters = @('-Name <VM>')
    Summary    = 'Lists what is installed and what the next maintenance run would record.'
    Covers     = @('Get-GuestToolingReport', 'Get-LazyVMTooling')
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
            Function = 'Get-GuestToolingReport'
            Area     = 'Tooling'
            Note     = 'opens the guest, takes the inventory and compares it with the recorded list; records nothing'
            Includes = @('Open-GuestSession', 'Get-GuestToolingInventory', 'Write-TextFileAtomic', 'Read-VMTooling', 'ConvertTo-ToolingRecord', 'Add-ToolingSource', 'Merge-AwaitingReinstall', 'Compare-ToolingRecord')
            Reads    = @(
                @{ Label = 'what is installed'; Kind = 'guest'; Store = 'Guest tooling'; Items = @('vswhere + vs_installer export', 'winget export', 'Marketplace extensions') }
                @{ Label = 'last recorded tooling list'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') }
            )
            Writes   = @(
                @{ Label = 'raw inventory'; Kind = 'file'; Store = '<VM>\State\tooling\'; Items = @('inventory-<stamp>.json') }
                @{ Label = 'report'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.Tooling: products, packages,', 'unmatched extensions, pending changes') }
            )
        }
    )
}
