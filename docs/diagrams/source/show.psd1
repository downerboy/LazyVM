@{
    Id         = 'show'
    Title      = 'Show LazyVM and its commands'
    Command    = 'Show-LazyVM'
    Parameters = @('or just: LazyVM')
    Summary    = 'What typing LazyVM on its own shows: the installed version, the LazyVM folder and the VMs in it, where the module is installed, and every command with its synopsis. Reads only.'
    Covers     = @('Show-LazyVM')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder; says so when none has been chosen yet'
            Reads    = @(@{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root') })
        }
        @{
            Function = 'Get-VMProfileName'
            Area     = 'Settings'
            Note     = 'every VM with a profile in that folder'
            Reads    = @(@{ Label = 'VM profiles'; Kind = 'file'; Store = '<Root>\'; Items = @('*\Config\VM.json') })
            Writes   = @(@{ Label = 'version, folder, VMs, module folder'; Kind = 'output'; Store = 'Pipeline'; Items = @('lines of text') })
        }
        @{
            Function = 'Get-Help'
            External = $true
            Area     = 'PowerShell'
            Note     = 'the synopsis of each exported command'
            Reads    = @(@{ Label = 'comment-based help'; Kind = 'file'; Store = 'Module'; Items = @('each command''s .SYNOPSIS') })
            Writes   = @(@{ Label = 'command list'; Kind = 'output'; Store = 'Pipeline'; Items = @('name and synopsis') })
        }
    )
}
