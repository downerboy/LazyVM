@{
    Id         = 'recovery-keys'
    Title      = 'List the recovery keys'
    Command    = 'Get-LazyVMRecoveryKey'
    Parameters = @('-Name <VM>  (optional while there is only one)')
    Summary    = 'Lists each BitLocker recovery key LazyVM stores for the VM: its disk, disk GUID, key ID and date, and whether the last export held it. Never the passwords. Only reads.'
    Covers     = @('Get-LazyVMRecoveryKey', 'Get-RecoveryKeyStatus')
    Omits      = @{
        'Assert-Administrator' = 'stops at once unless run as administrator'
    }
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder'
            Reads    = @(@{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') })
        }
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'the VM''s settings, read only'
            Reads    = @(@{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') })
        }
        @{
            Function = 'Get-RecoveryKeyStatus'
            Area     = 'Disks'
            Note     = 'each stored key, and whether the last export held it, as the reminders count it; its password is dropped'
            Includes = @('ConvertTo-RecoveryKeyDate', 'Select-UnexportedRecoveryKey', 'Get-RecoveryKeyStamp')
        }
        @{
            Function = 'Get-StoredRecoveryKey'
            Area     = 'Disks'
            Caller   = 'Get-RecoveryKeyStatus'
            Note     = 'every disk''s key ID and date; nothing when none is stored'
            Reads    = @(@{ Label = 'recovery keys'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\bitlocker.cred') })
        }
        @{
            Function = 'Read-RecoveryKeyExportRecord'
            Area     = 'Disks'
            Caller   = 'Get-RecoveryKeyStatus'
            Note     = 'which keys the last export held; none when there is no record or it cannot be read'
            Reads    = @(@{ Label = 'export record'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('RecoveryKeyExport.json') })
            Writes   = @(@{ Label = 'the keys'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.RecoveryKey per disk, no password') })
        }
    )
}
