@{
    Id         = 'set-root'
    Title      = 'Choose the LazyVM folder'
    Command    = 'Set-LazyVMRoot'
    Parameters = @('-Path D:\DevVM')
    Summary    = 'Optional. Without it, Build-LazyVM uses %USERPROFILE%\LazyVM. The folder is open to you and SYSTEM only. Nothing in the old folder is moved.'
    Covers     = @('Set-LazyVMRoot')
    Omits      = @{
        'Assert-Administrator' = 'stops at once unless run as administrator'
    }
    Steps      = @(
        @{
            Function = 'Assert-NoLegacyInstallation'
            Area     = 'Settings'
            Note     = 'stops while a machine-wide install is still there, naming Convert-LazyVMInstallation'
            Includes = @('Get-RegisteredRoot')
            Reads    = @(
                @{ Label = 'machine-wide install'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root, if still there') }
            )
        }
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
                @{ Label = 'previous folder'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'Assert-RootFolderUsable'
            Area     = 'Settings'
            Note     = 'refuses a folder that holds anything but LazyVM''s own files, before asking'
        }
        @{
            Function = 'Initialize-RootFolder'
            Area     = 'Settings'
            Note     = 'creates the folder, or locks it again: full control for you and SYSTEM only, inherited by everything in it'
            Includes = @('New-RootFolderSecurity', 'Get-CurrentUserSid')
            Writes   = @(
                @{ Label = 'folder access'; Kind = 'folder'; Store = 'D:\DevVM'; Items = @('you + SYSTEM', 'nothing inherited') }
            )
        }
        @{
            Function = 'Set-RegisteredRoot'
            Area     = 'Settings'
            Note     = 'records it'
            Writes   = @(
                @{ Label = 'new folder, read by every later run'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root = D:\DevVM') }
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
