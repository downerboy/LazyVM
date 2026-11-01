@{
    Id         = 'maintenance'
    Title      = 'Daily maintenance'
    Command    = 'Invoke-LazyVMMaintenance'
    Parameters = @('-Name <VM>', '-WhatIf  (optional)')
    Summary    = 'Each night: records hardware changes made in Hyper-V, looks after the disks, records what changed in the guest, backs up the databases, keeps the guest up to date, and acts on the evaluation license only when it is within RebuildThresholdDays (10) of expiry. With -WhatIf, Get-MaintenancePreview says what a run would do and nothing else runs. Returns None, Rearmed, Rebuilt or Built.'
    CalledBy   = @{ Name = 'LazyVM-Maintain-<VM>'; Kind = 'task'; Notes = @('daily at MaintenanceTime', 'as SYSTEM') }
    Covers     = @('Invoke-LazyVMMaintenance', 'Invoke-Maintenance', 'Invoke-DailyMaintenance')
    Omits      = @{
        'Get-MaintenancePreview' = 'runs only with -WhatIf, in place of everything else; the summary says so'
    }
    Steps      = @(
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context, opens the log and records any hardware change made in Hyper-V'
            Reads    = @(
                @{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') }
                @{ Label = 'hardware'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('processors, memory, disk sizes, switch') }
            )
            Writes   = @(
                @{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') }
                @{ Label = 'hardware change'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') }
            )
        }
        @{
            Function = 'Sync-VMProfile'
            Area     = 'Settings'
            Note     = 'fills in any setting VM.json lacks from the shared template'
            Reads    = @(@{ Label = 'shared template'; Kind = 'file'; Store = 'Shared\Config\'; Items = @('LazyVM.Settings.json') })
            Writes   = @(@{ Label = 'complete profile'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json', 'VM.Template.json  (first time only)') })
        }
        @{
            Function = 'Invoke-Maintenance'
            Area     = 'Maintenance'
            Note     = 'steps 4-23 are its calls; no VM: returns Build and Invoke-Rebuild builds one instead'
            Reads    = @(@{ Label = 'does the VM exist'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('Get-VM <VM>') })
        }
        @{
            Function = 'Open-GuestSession'
            Area     = 'Guest'
            Caller   = 'Invoke-Maintenance'
            Note     = 'starts the VM if it is off and waits for it, then opens the session'
            Reads    = @(@{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'PowerShell Direct session'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('running, reachable') })
        }
        @{
            Function = 'Invoke-DailyMaintenance'
            Area     = 'Maintenance'
            Caller   = 'Invoke-Maintenance'
            Note     = 'steps 6-22 are its calls; a step that fails is logged and the rest still run'
        }
        @{
            Function = 'Expand-GuestSystemDrive'
            Area     = 'Installation'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'only when the OS disk has new space: checkpoint, moves the recovery partition to the end and extends C:'
            Writes   = @(@{ Label = 'bigger C:'; Kind = 'guest'; Store = 'Running guest'; Items = @('C: over the whole OS disk') })
        }
        @{
            Function = 'Install-UserDisk'
            Area     = 'Disks'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'an older VM gets its User disk; what the personal folders hold on C: is copied to it'
            Writes   = @(@{ Label = 'User disk'; Kind = 'file'; Store = '<VM>\Disks\'; Items = @('<VM>-User.vhdx  (U:, if missing)') })
        }
        @{
            Function = 'Protect-GuestPersistentDisk'
            Area     = 'Disks'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'BitLocker on C:, then on each persistent disk that does not have it'
            Writes   = @(@{ Label = 'encrypted disks, recovery passwords'; Kind = 'file'; Store = 'Guest and credential store'; Items = @('C:, D:, W:, U: with auto-unlock', '<VM>\Credentials\') })
        }
        @{
            Function = 'Backup-UserDisk'
            Area     = 'Disks'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'one copy of the User disk, still encrypted, made only when its files changed'
            Reads    = @(@{ Label = 'User disk'; Kind = 'file'; Store = '<VM>\Disks\'; Items = @('<VM>-User.vhdx') })
            Writes   = @(@{ Label = 'copy'; Kind = 'file'; Store = '<VM>\Backups\'; Items = @('<VM>-User.vhdx  (or BackupDir)') })
        }
        @{
            Function = 'Update-ToolingRecord'
            Area     = 'Tooling'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'takes a checkpoint before adopting a tooling change'
            Reads    = @(
                @{ Label = 'what is installed'; Kind = 'guest'; Store = 'Guest tooling'; Items = @('vswhere + vs_installer export', 'winget export', 'Marketplace extensions') }
                @{ Label = 'last recorded tooling list'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  Tooling') }
            )
            Writes   = @(
                @{ Label = 'checkpoint, only on a change'; Kind = 'Hyper-V'; Store = '<VM>\Checkpoints\'; Items = @('checkpoint "Tooling <stamp>"', 'oldest pruned past ToolingCheckpointsToKeep (3)') }
                @{ Label = 'new tooling version, only on a change'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json', 'History\VM-<stamp>.json') }
            )
        }
        @{
            Function = 'Update-GuestEnvironmentRecord'
            Area     = 'Capture'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'environment variables, PATH, hosts entries and mapped drives; then the same for the other records'
            Includes = @('Update-GuestFirewallRecord', 'Update-GuestScheduledTaskRecord', 'Update-GuestSqlRecord', 'Update-GuestAppSettingRecord')
            Reads    = @(@{ Label = 'guest settings'; Kind = 'guest'; Store = 'Running guest'; Items = @('environment, firewall rules', 'scheduled tasks', 'SQL logins, settings, Agent jobs', 'AppSettings registry values') })
            Writes   = @(
                @{ Label = 'records, only on a change'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  GuestEnvironment, GuestFirewallRules,', 'GuestScheduledTasks, GuestSql, GuestAppSettings') }
                @{ Label = 'secret values'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\') }
            )
        }
        @{
            Function = 'Backup-GuestUserDatabase'
            Area     = 'Capture'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'DBCC CHECKDB each user database and, only when it passes, backs it up: one good backup of each'
            Reads    = @(@{ Label = 'databases'; Kind = 'guest'; Store = 'SQL Server'; Items = @('online, writable user databases') })
            Writes   = @(@{ Label = 'backups'; Kind = 'folder'; Store = 'D:\SQLBackup\'; Items = @('<database>.bak') })
        }
        @{
            Function = 'Start-GuestStoreAppUpdate'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'asks the Microsoft Store to check for app updates, as a guest task as SYSTEM'
            Writes   = @(@{ Label = 'update scan'; Kind = 'guest'; Store = 'Microsoft Store'; Items = @('UpdateScanMethod') })
        }
        @{
            Function = 'Set-GuestSysmon'
            Area     = 'Installation'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'turns Sysmon on and installs it if it is not; applies the configuration again only when LazyVM ships a new one'
            Reads    = @(@{ Label = 'configuration'; Kind = 'file'; Store = 'Module Data\Sysmon\'; Items = @('sysmonconfig.xml') })
            Writes   = @(@{ Label = 'Sysmon'; Kind = 'guest'; Store = 'Running guest'; Items = @('Sysmon feature and service', 'HKLM:\SOFTWARE\LazyVM  config hash') })
        }
        @{
            Function = 'Update-GuestVisualStudioSetting'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'applies the captured Visual Studio settings while they are pending, once Visual Studio has been opened and is closed'
            Reads    = @(@{ Label = 'settings backup'; Kind = 'file'; Store = '<VM>\Backups\'; Items = @('VisualStudio.vssettings') })
            Writes   = @(@{ Label = 'settings applied'; Kind = 'guest'; Store = 'Visual Studio'; Items = @('imported settings', 'pending flag cleared') })
        }
        @{
            Function = 'Update-GuestWingetPackage'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'winget upgrades, except Visual Studio, SQL Server, pinned packages and running programs'
            Writes   = @(@{ Label = 'upgraded packages'; Kind = 'guest'; Store = 'Running guest'; Items = @('new versions; the tooling list is unchanged') })
        }
        @{
            Function = 'Update-GuestWindows'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'quality and security updates; restarts only when nobody can be disturbed'
            Reads    = @(@{ Label = 'updates'; Kind = 'web'; Store = 'Windows Update'; Items = @('quality and security updates') })
            Writes   = @(@{ Label = 'patched Windows'; Kind = 'guest'; Store = 'Running guest'; Items = @('updates installed', 'restart now or left pending') })
        }
        @{
            Function = 'Get-GuestLicenseStatus'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'days left, rearms left'
            Reads    = @(@{ Label = 'license status'; Kind = 'guest'; Store = 'Running guest'; Items = @('SoftwareLicensingProduct', 'SoftwareLicensingService') })
        }
        @{
            Function = 'Get-MaintenanceDecision'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'more than the threshold left, or no countdown: none; rearms left: rearm; otherwise: rebuild'
            Reads    = @(@{ Label = 'threshold'; Kind = 'setting'; Store = 'VM settings'; Items = @('RebuildThresholdDays = 10') })
        }
        @{
            Function = 'Test-GuestStateChanged'
            Area     = 'Capture'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'decision none: has anything only a capture keeps changed since the last capture?'
            Reads    = @(
                @{ Label = 'fingerprint now'; Kind = 'guest'; Store = 'Running guest'; Items = @('certificates, Visual Studio settings') }
                @{ Label = 'fingerprint then'; Kind = 'file'; Store = '<VM>\State\'; Items = @('manifest.json') }
            )
        }
        @{
            Function = 'Save-GuestState'
            Area     = 'Capture'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'on a rearm or rebuild, or when the state changed (see Capture state)'
            Reads    = @(@{ Label = 'state to keep'; Kind = 'guest'; Store = 'Running guest'; Items = @('VS settings', 'SQL databases + logins', 'env, certs, tasks, apps') })
            Writes   = @(@{ Label = 'captured state'; Kind = 'folder'; Store = '<VM>\State\'; Items = @('Captures\<stamp>\  vs\  windows\', 'manifest.json', 'D:\SQLBackup\<database>.bak') })
        }
        @{
            Function = 'Invoke-GuestRearm'
            Area     = 'Maintenance'
            Caller   = 'Invoke-DailyMaintenance'
            Note     = 'decision rearm: slmgr rearm, then a restart'
            Writes   = @(@{ Label = 'rearmed Windows'; Kind = 'guest'; Store = 'Running guest'; Items = @('evaluation reset to 90 days', 'one rearm used') })
        }
        @{
            Function = 'Stop-GuestGracefully'
            Area     = 'Maintenance'
            Caller   = 'Invoke-Maintenance'
            Note     = 'only if the run started the VM, and not before a rebuild'
            Writes   = @(@{ Label = 'VM back off'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('off') })
        }
        @{
            Function  = 'Invoke-Rebuild'
            Arguments = '-SkipCapture'
            Area      = 'Maintenance'
            Note      = 'only when no rearms are left or the rearm failed (see Rebuild a VM); without -SkipCapture when there is no VM'
        }
    )
}
