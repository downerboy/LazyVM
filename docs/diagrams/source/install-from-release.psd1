@{
    Id         = 'install-from-release'
    Title      = 'Install from a release'
    Command    = '.\LazyVM\Install.ps1'
    Parameters = @()
    External   = $true
    Summary    = 'Copies the module from a downloaded release to where PowerShell 7 and the SYSTEM maintenance task find it, replacing an earlier copy of the same version, and unblocks it.'
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
                @{ Label = 'module installed for all users'; Kind = 'folder'; Store = '$env:ProgramFiles\PowerShell\'; Items = @('Modules\LazyVM\', '<version>\') }
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
