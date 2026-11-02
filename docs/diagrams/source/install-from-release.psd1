@{
    Id         = 'install-from-release'
    Title      = 'Install from a release'
    Command    = '.\LazyVM\Install.ps1'
    Parameters = @()
    External   = $true
    Summary    = 'As administrator. Copies the module from a downloaded release to %ProgramFiles%\LazyVM, which it locks so only administrators can change it and only you can read it, adds it to your PSModulePath, replacing an earlier copy of the same version, and unblocks it. Removes copies earlier LazyVM 6 builds put in your own folders.'
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
    )
}
