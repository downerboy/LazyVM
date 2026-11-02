@{
    Id         = 'recovery-key-export'
    Title      = 'Export the recovery passwords'
    Command    = 'Export-LazyVMRecoveryKey'
    Parameters = @('-Name <VM, wildcards>  (optional, default *)', '-Path <file>', '-Force  (optional)')
    Summary    = 'Writes the BitLocker recovery passwords of the VM, or of every VM, to a file you keep offline, and records which keys it held so the reminders stop. Never writes over a file without -Force; warns about a file inside the LazyVM folder or in OneDrive.'
    Covers     = @('Export-LazyVMRecoveryKey')
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
            Function = 'Select-VMProfileName'
            Area     = 'Settings'
            Note     = 'the VMs -Name matches, every VM by default; stops for a name without wildcards that no VM has'
            Includes = @('Get-VMProfileName')
            Reads    = @(@{ Label = 'VM profiles'; Kind = 'file'; Store = '<Root>\'; Items = @('*\Config\VM.json') })
        }
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'each VM''s settings, read only'
            Reads    = @(@{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') })
        }
        @{
            Function = 'Get-StoredRecoveryKey'
            Area     = 'Disks'
            Note     = 'every disk''s recovery password, key ID and date; stops when none is stored'
            Includes = @('Get-NoRecoveryKeyMessage')
            Reads    = @(@{ Label = 'recovery passwords'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\bitlocker.cred') })
        }
        @{
            Function = 'Test-PathWithin'
            Area     = 'Common'
            Note     = 'before asking: stops for a missing folder or an existing file without -Force; warns when -Force with -Name drops other VMs'' keys, and for a file in the LazyVM folder or OneDrive'
            Includes = @('Test-CloudSyncedPath')
        }
        @{
            Function = 'Use-RunRoot'
            Area     = 'Common'
            Note     = 'the writes below are checked for reparse points in the LazyVM folder'
        }
        @{
            Function = 'Write-TextFileAtomic'
            Area     = 'Common'
            Caller   = 'Use-RunRoot'
            Note     = 'the file, plain text, one field per line'
            Includes = @('Format-RecoveryKeyExport')
            Writes   = @(@{ Label = 'recovery passwords'; Kind = 'file'; Store = '-Path'; Items = @('<file>, such as on a USB drive') })
        }
        @{
            Function = 'Save-RecoveryKeyExportRecord'
            Area     = 'Disks'
            Caller   = 'Use-RunRoot'
            Note     = 'which keys each VM''s export held, by disk GUID and key ID, never the passwords'
            Writes   = @(
                @{ Label = 'export record'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('RecoveryKeyExport.json') }
                @{ Label = 'the file'; Kind = 'output'; Store = 'Pipeline'; Items = @('FileInfo') }
            )
        }
    )
}
