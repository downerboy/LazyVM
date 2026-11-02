@{
    Id         = 'new-profile'
    Title      = 'Create a VM profile without building'
    Command    = 'New-LazyVM'
    Parameters = @('-Name <VM>', '-From <OtherVM> | -ConfigTemplate <Template>  (optional)')
    Summary    = 'Creates the profile only. Build-LazyVM does this by itself when the profile is missing.'
    Covers     = @('New-LazyVM')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder; stops if none has been chosen yet'
            Reads    = @(
                @{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'New-VMProfile'
            Area     = 'Settings'
            Note     = 'applies -ConfigTemplate''s Settings, or copies -From settings except paths, computer name, maintenance time and disk identity; schedules maintenance an hour after the latest existing VM'
            Reads    = @(
                @{ Label = 'settings and tooling, with -From'; Kind = 'file'; Store = '<OtherVM>\Config\'; Items = @('VM.json') }
                @{ Label = 'config template, with -ConfigTemplate'; Kind = 'file'; Store = 'Config templates'; Items = @('Data\Templates\*.json', 'Shared\Templates\*.json') }
                @{ Label = 'shared template'; Kind = 'file'; Store = 'Shared\Config\'; Items = @('LazyVM.Settings.json') }
                @{ Label = 'maintenance times in use'; Kind = 'file'; Store = '*\Config\'; Items = @('VM.json') }
            )
            Writes   = @(
                @{ Label = 'new profile'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') }
                @{ Label = 'tooling list to build with'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json', 'its Tooling  (with -From)') }
            )
        }
        @{
            Function = 'Get-LazyVM'
            Area     = 'command'
            Note     = 'returns the new VM as LazyVM.VM'
        }
    )
}
