@{
    Id         = 'settings'
    Title      = 'View settings'
    Command    = 'Get-LazyVMSetting'
    Parameters = @('-Name <VM>', '-Setting  (wildcards)')
    Summary    = 'Every setting as the VM uses it, where the value came from, and what it does. No administrator rights needed.'
    Covers     = @('Get-LazyVMSetting')
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
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'defaults, then host file, then VM profile; later wins'
            Reads    = @(
                @{ Label = 'defaults'; Kind = 'file'; Store = 'Module Data\'; Items = @('LazyVM.Settings.schema.json') }
                @{ Label = 'your values'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-SettingDescription'
            Area     = 'Settings'
            Note     = 'per setting, from the schema'
            Includes = @('Get-SettingsSchema')
            Writes   = @(
                @{ Label = 'effective settings'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.Setting: Value,', 'Source', 'Description') }
            )
        }
    )
}
