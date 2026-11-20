@{
    Id         = 'install-from-release'
    Title      = 'Install from a release'
    Command    = '.\LazyVM\Install.ps1'
    Parameters = @()
    External   = $true
    Summary    = 'As administrator. Copies the module and the app from a downloaded release to %ProgramFiles%\LazyVM, which it locks so only administrators can change it and only you can read it, adds the module to your PSModulePath, replacing an earlier copy of the same version, and unblocks it. Adds the LazyVM Start menu shortcut, in a folder only administrators can change. Removes copies earlier LazyVM 6 builds put in your own folders. Install LazyVM.cmd runs the same, as administrator.'
    CalledBy   = @{ Name = 'Install LazyVM.cmd'; Kind = 'double-click'; Notes = @('asks for administrator rights', 'needs PowerShell 7.6') }
    Covers     = @()
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Copy-Item'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'newest version folder beside the script'
            Reads    = @(
                @{ Label = 'module from the zip'; Kind = 'folder'; Store = 'LazyVM\LazyVM\'; Items = @('<version>\') }
            )
            Writes   = @(
                @{ Label = 'module, admin-only to change, readable by you'; Kind = 'folder'; Store = '%ProgramFiles%\LazyVM\'; Items = @('Modules\LazyVM\', '<version>\') }
                @{ Label = 'module folder on your PSModulePath'; Kind = 'registry'; Store = 'HKCU:\Environment'; Items = @('PSModulePath') }
            )
        }
        @{
            Function = 'Unblock-File'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'removes the downloaded-from-the-internet mark, which would stop PowerShell loading the module'
            Writes   = @(
                @{ Label = 'files PowerShell will load'; Kind = 'folder'; Store = 'Modules\LazyVM\'; Items = @('<version>\  (unblocked)') }
            )
        }
        @{
            Function = 'Install-App'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'copied beside the old app, then swapped in; an app that is running is kept'
            Reads    = @(
                @{ Label = 'app from the zip'; Kind = 'folder'; Store = 'LazyVM\App\'; Items = @('LazyVM.UI.Wpf.exe') }
            )
            Writes   = @(
                @{ Label = 'app, admin-only to change, readable by you'; Kind = 'folder'; Store = '%ProgramFiles%\LazyVM\'; Items = @('App\') }
            )
        }
        @{
            Function = 'Install-StartMenuShortcut'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'only when the app is installed, and the folder is administrators'' alone to change; replaces one that is there'
            Writes   = @(
                @{ Label = 'Start menu shortcut, locked'; Kind = 'file'; Store = 'all-users Start menu'; Items = @('LazyVM.lnk') }
            )
        }
    )
}
