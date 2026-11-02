@{
    Id         = 'convert-installation'
    Title      = 'Move a machine-wide install to your account'
    Command    = 'Convert-LazyVMInstallation'
    Parameters = @('-Path <new folder>  (optional)')
    Summary    = 'Once, after updating from LazyVM 5. Moves C:\LazyVM, its tasks, passwords and registry key to the current user. Each step skips what is already done, so running it again after an interruption carries on; nothing of the old install is removed until every step has succeeded.'
    Covers     = @('Convert-LazyVMInstallation', 'Invoke-InstallationMigration')
    Omits      = @{
        'Assert-Administrator' = 'stops at once unless run as administrator'
        'Resolve-SettingsRoot' = 'checks -Path is a folder on a local drive'
        'Get-DefaultRoot'      = 'the new folder when -Path is left out: %USERPROFILE%\LazyVM'
        'Test-PathWithin'      = 'refuses a new folder inside the old one, or the other way round'
        'Get-TaskUserName'     = 'names the user in the log'
    }
    Steps      = @(
        @{
            Function = 'Get-LegacyRoot'
            Area     = 'Settings'
            Note     = 'nothing to move without one'
            Reads    = @(@{ Label = 'machine-wide install'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root') })
        }
        @{
            Function = 'Invoke-InstallationMigration'
            Area     = 'Migration'
            Note     = 'runs the steps below, logging to Shared\Logs\Migration.log in the new folder'
            Includes = @('Start-Log', 'Stop-Log')
            Writes   = @(@{ Label = 'migration log'; Kind = 'file'; Store = '<new>\Shared\Logs\'; Items = @('Migration.log') })
        }
        @{
            Function = 'Assert-NoRunningTask'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'stops while a LazyVM task is running'
            Reads    = @(@{ Label = 'LazyVM tasks'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-*  state') })
        }
        @{
            Function = 'Initialize-RootFolder'
            Area     = 'Settings'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'the new folder, open to you and SYSTEM only; again at the end, so everything moved in inherits it'
            Writes   = @(@{ Label = 'folder access'; Kind = 'folder'; Store = '<new>'; Items = @('you + SYSTEM', 'nothing inherited') })
        }
        @{
            Function = 'Move-LegacyTask'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'first, so no nightly run starts mid-move; asks for your Windows password once'
            Includes = @('Register-LazyVMHostTask')
            Reads    = @(@{ Label = 'tasks run as SYSTEM'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'LazyVM-ResumeAfterReboot-<VM>') })
            Writes   = @(@{ Label = 'same tasks, as you'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('elevated, signed in or not') })
        }
        @{
            Function = 'Convert-LegacyCredential'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 're-encrypts each credential, reads it back, then replaces the file; deletes the key once all are done'
            Includes = @('Get-LegacyCredentialKeyPath', 'Convert-LegacyCredentialFile')
            Reads    = @(@{ Label = 'old key and credentials'; Kind = 'file'; Store = '<old>'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\*.cred') })
            Writes   = @(@{ Label = 'credentials for you only'; Kind = 'file'; Store = '<old>\<VM>\Credentials\'; Items = @('*.cred  (DPAPI)', 'key deleted') })
        }
        @{
            Function = 'Move-LegacyVMStorage'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'unless the folder stays: Hyper-V storage migration, the VM keeps running; checks free space first'
            Includes = @('ConvertTo-NewRootPath', 'Get-FolderSize', 'Get-FreeSpace')
            Reads    = @(@{ Label = 'VM files'; Kind = 'Hyper-V'; Store = 'VMs in <old>'; Items = @('configuration, checkpoints, disks') })
            Writes   = @(@{ Label = 'VM files'; Kind = 'Hyper-V'; Store = '<new>\<VM>\'; Items = @('Virtual Machines, Checkpoints, Disks') })
        }
        @{
            Function = 'Assert-NoVMFileLeft'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'stops before any other file moves if a VM still uses a disk in the old folder, a checkpoint''s parent disk included'
            Reads    = @(@{ Label = 'disks in use'; Kind = 'Hyper-V'; Store = 'VMs and checkpoints'; Items = @('attached disks', 'parent disks') })
        }
        @{
            Function = 'Dismount-LegacyDvdMedia'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'ejects ISOs attached from the old folder'
            Writes   = @(@{ Label = 'DVD drives'; Kind = 'Hyper-V'; Store = 'VMs'; Items = @('ejected') })
        }
        @{
            Function = 'Move-LegacyFile'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'every other file, one at a time, to the same place'
            Writes   = @(@{ Label = 'settings, logs, state, ISOs'; Kind = 'file'; Store = '<new>'; Items = @('Shared\', '<VM>\') })
        }
        @{
            Function = 'Mount-MovedDvdMedia'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'attaches the ISOs again from the new folder'
            Writes   = @(@{ Label = 'DVD drives'; Kind = 'Hyper-V'; Store = 'VMs'; Items = @('ISO from <new>') })
        }
        @{
            Function = 'Copy-LegacyRegistry'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'the folder and any interrupted build'
            Includes = @('Get-LegacyResumePhase', 'Set-ResumePhase', 'Set-RegisteredRoot')
            Writes   = @(@{ Label = 'your registry'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root = <new>', '<VM>  ResumePhase') })
        }
        @{
            Function = 'Remove-LegacyInstallation'
            Area     = 'Migration'
            Caller   = 'Invoke-InstallationMigration'
            Note     = 'last: the old folder once empty, the Program Files copy, then the HKLM key'
            Writes   = @(@{ Label = 'old install removed'; Kind = 'registry'; Store = 'Machine-wide'; Items = @('<old>  (if empty)', 'Program Files\PowerShell\Modules\LazyVM', 'HKLM:\SOFTWARE\LazyVM') })
        }
    )
}
