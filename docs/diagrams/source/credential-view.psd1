@{
    Id         = 'credential-view'
    Title      = 'See the guest account'
    Command    = 'Get-LazyVMCredential'
    Parameters = @('-Name <VM>', '-AsPlainText | -ToClipboard | -RecoveryPassword  (optional)')
    Summary    = 'Returns the account LazyVM uses inside the VM. -AsPlainText shows the password; -ToClipboard puts it on the clipboard, out of clipboard history; -RecoveryPassword lists the BitLocker recovery passwords instead.'
    Covers     = @('Get-LazyVMCredential')
    Omits      = @{
        'Assert-Administrator' = 'stops at once unless run as administrator'
    }
    Steps      = @(
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'finds the key and the credential files'
            Includes = @('Resolve-LazyVMRoot')
            Reads    = @(
                @{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Get-StoredCredential'
            Area     = 'Credentials'
            Note     = 'decrypts with the key'
            Reads    = @(
                @{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'credential'; Kind = 'output'; Store = 'Pipeline'; Items = @('PSCredential', 'or user name', 'and password as text') }
            )
        }
        @{
            Function = 'Get-StoredSecretTable'
            Area     = 'Credentials'
            Note     = 'with -RecoveryPassword, instead: every disk''s BitLocker recovery password'
            Reads    = @(@{ Label = 'recovery passwords'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\bitlocker.cred') })
            Writes   = @(@{ Label = 'recovery passwords'; Kind = 'output'; Store = 'Pipeline'; Items = @('Disk, DiskGuid, Recorded,', 'RecoveryPassword') })
        }
        @{
            Function = 'Set-ClipboardSecret'
            Area     = 'Credentials'
            Note     = 'with -ToClipboard: the password, kept out of clipboard history and sync'
            Writes   = @(@{ Label = 'password'; Kind = 'host'; Store = 'Clipboard'; Items = @('not in history or sync') })
        }
    )
}
