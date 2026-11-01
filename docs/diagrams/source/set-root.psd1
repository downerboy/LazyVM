@{
    Id         = 'set-root'
    Title      = 'Choose the LazyVM folder'
    Command    = 'Set-LazyVMRoot'
    Parameters = @('-Path D:\DevVM')
    Summary    = 'Optional. Without it, Build-LazyVM picks LazyVM on the NTFS drive with the most free space. Nothing in the old folder is moved.'
    Covers     = @('Set-LazyVMRoot')
    Omits      = @{
        'Assert-Administrator' = 'stops at once unless run as administrator'
    }
    Steps      = @(
        @{
            Function = 'Resolve-SettingsRoot'
            Area     = 'Settings'
            Note     = 'checks it is a full local path'
        }
        @{
            Function = 'Get-RegisteredRoot'
            Area     = 'Settings'
            Note     = 'warns if a different folder was in use'
            Reads    = @(
                @{ Label = 'previous folder'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'Set-RegisteredRoot'
            Area     = 'Settings'
            Note     = 'creates the folder if needed and records it'
            Includes = @('New-Folder')
            Writes   = @(
                @{ Label = 'new folder, read by every later run'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root = D:\DevVM') }
            )
        }
        @{
            Function = 'Initialize-ConfigFolder'
            Area     = 'Settings'
            Note     = 'copies the schema for VS Code autocomplete; returns the folder and its settings file'
            Includes = @('Get-ConfigDir')
            Reads    = @(
                @{ Label = 'settings schema'; Kind = 'file'; Store = 'Module Data\'; Items = @('LazyVM.Settings.schema.json') }
            )
            Writes   = @(
                @{ Label = 'schema copy, empty settings file'; Kind = 'file'; Store = 'D:\DevVM\Shared\Config\'; Items = @('LazyVM.Settings.schema.json', 'LazyVM.Settings.json (if new)') }
            )
        }
    )
}
