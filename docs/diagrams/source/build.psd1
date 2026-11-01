@{
    Id         = 'build'
    Title      = 'Build a VM'
    Command    = 'Build-LazyVM'
    Parameters = @('-Name <VM>', '-ConfigTemplate <Template>  (optional)', '-FromPhase 0-8  (optional)', '-NoUnattend  (optional)')
    Summary    = 'Invoke-VMBuild runs phases 0 to 8, skipping work already done; Build-LazyVM then schedules maintenance. Running it again finishes an interrupted build.'
    Covers     = @('Build-LazyVM', 'Invoke-VMBuild', 'Invoke-BuildPhase', 'Get-BuildPhase', 'Install-GuestSoftware', 'Complete-GuestConfiguration')
    Omits      = @{
        'Test-BuildPhaseNumber' = 'validates -FromPhase before the command runs'
    }
    Steps      = @(
        @{
            Function = 'Initialize-BuildTarget'
            Area     = 'Settings'
            Note     = 'first run: picks the root and creates the profile, from -ConfigTemplate when given'
            Reads    = @(
                @{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root, if already set') }
                @{ Label = 'drive with most free space'; Kind = 'host'; Store = 'Fixed drives'; Items = @('NTFS, free space') }
                @{ Label = 'config template, with -ConfigTemplate'; Kind = 'file'; Store = 'Config templates'; Items = @('Data\Templates\*.json', 'Shared\Templates\*.json') }
            )
            Writes   = @(
                @{ Label = 'LazyVM folder, first run'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root = X:\LazyVM') }
                @{ Label = 'settings file and profile, if new'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context and opens the log'
            Reads    = @(@{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') })
        }
        @{
            Function = 'Sync-VMProfile'
            Area     = 'Settings'
            Note     = 'fills in any setting VM.json lacks from the shared template'
            Reads    = @(@{ Label = 'shared template'; Kind = 'file'; Store = 'Shared\Config\'; Items = @('LazyVM.Settings.json') })
            Writes   = @(@{ Label = 'complete profile'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json', 'VM.Template.json  (first time only)') })
        }
        @{
            Function = 'Invoke-VMBuild'
            Area     = 'Host'
            Note     = 'runs the phases from -FromPhase or the resume point, whichever is later'
        }
        @{
            Function = 'Get-ResumePhase'
            Area     = 'Host'
            Caller   = 'Invoke-VMBuild'
            Note     = 'picks up after a host restart'
            Reads    = @(@{ Label = 'phase to resume at'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM\<VM>'; Items = @('ResumePhase') })
        }
        @{
            Function = 'Invoke-BuildPhase'
            Area     = 'Host'
            Caller   = 'Invoke-VMBuild'
            Note     = 'runs each phase of Get-BuildPhase in order (steps 7-18); when a phase throws, deletes the answer-file disc first'
            Includes = @('Get-BuildPhase', 'Remove-UnattendSeedDisk')
        }
        @{
            Function = 'Initialize-InstallationIso'
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'the Windows ISO, before anything changes; opens the download page and stops if there is none'
            Reads    = @(@{ Label = 'Windows ISO'; Kind = 'file'; Store = 'Shared\ISO\  or  Downloads\'; Items = @('Windows 11 Enterprise', 'Evaluation ISO') })
            Writes   = @(@{ Label = 'Windows ISO in place'; Kind = 'file'; Store = 'Shared\ISO\'; Items = @('Win11Ent_Eval.iso', '(moved from Downloads)') })
        }
        @{
            Function = 'Repair-HyperVService'
            Also     = @('Test-HostReadiness')
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phases 0 and 1: the Hyper-V services, then CPU, SLAT, memory and free space'
            Reads    = @(@{ Label = 'host checks'; Kind = 'host'; Store = 'This PC'; Items = @('vmms, vmcompute, CPU, SLAT', 'RAM, free space') })
        }
        @{
            Function = 'Enable-HyperVFeature'
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 2; returns RestartPending when the host must restart'
            Writes   = @(
                @{ Label = 'resume task, only if a restart is needed'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-ResumeAfterReboot-<VM>') }
                @{ Label = 'where to resume'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM\<VM>'; Items = @('ResumePhase = 3') }
            )
        }
        @{
            Function = 'Initialize-HostFolder'
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 3'
            Writes   = @(@{ Label = 'folders created if missing'; Kind = 'folder'; Store = '<Root>\'; Items = @('Shared\ ISO, Installers, Credentials', '<VM>\ Disks, Credentials, Backups,', 'Logs, Checkpoints') })
        }
        @{
            Function = 'Initialize-SqlServerIso'
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 4: downloads the SQL Server ISO if it is missing'
            Reads    = @(@{ Label = 'SQL Server ISO'; Kind = 'web'; Store = 'download.microsoft.com'; Items = @('SQL Server 2025 ISO, only if missing') })
            Writes   = @(@{ Label = 'SQL Server ISO in place'; Kind = 'file'; Store = 'Shared\Installers\'; Items = @('SQLServer2025-x64-ENU-EntDev.iso') })
        }
        @{
            Function = 'Initialize-SqlDataVhd'
            Also     = @('Initialize-DevDriveVhd', 'Initialize-UserDataVhd')
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 5: existing disks are never overwritten'
            Writes   = @(@{ Label = 'data disk, Dev Drive and User disk'; Kind = 'file'; Store = '<VM>\Disks\'; Items = @('<VM>-SQL.vhdx  (100 GB)', '<VM>-DevDrive.vhdx  (250 GB)', '<VM>-User.vhdx  (20 GB)') })
        }
        @{
            Function = 'Initialize-GuestCredential'
            Area     = 'Credentials'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 6, for a VM that does not exist yet, without -NoUnattend: generates the account if there is none'
            Reads    = @(@{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'credential, if new'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') })
        }
        @{
            Function = 'New-UnattendSeedDisk'
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 6: the answer file for Setup, in the same cases'
            Writes   = @(@{ Label = 'answer-file disc'; Kind = 'file'; Store = '<VM>\Disks\'; Items = @('<VM>-Seed.iso') })
        }
        @{
            Function = 'New-GuestVM'
            Area     = 'Host'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 6: Gen 2, Secure Boot, TPM, dynamic memory'
            Reads    = @(@{ Label = 'install discs'; Kind = 'file'; Store = 'Shared\ISO\  <VM>\Disks\'; Items = @('Win11Ent_Eval.iso', '<VM>-Seed.iso') })
            Writes   = @(
                @{ Label = 'Windows disk, VM files'; Kind = 'file'; Store = '<VM>\'; Items = @('Disks\<VM>-OS.vhdx', 'Virtual Machines\  (configuration)') }
                @{ Label = 'new VM'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('created, not started yet') }
            )
        }
        @{
            Function = 'Install-GuestSoftware'
            Area     = 'Installation'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 7: starts the VM, waits for Setup and deletes the answer-file disc; attaches and prepares D:, W: and U: and puts the personal folders on U:; extends C:; BitLocker; Enhanced Session; removes built-in apps and applies the appearance and Developer Mode; Sysmon; then the tooling list: Visual Studio Installer products, SQL Server, winget packages, official installers; Windows updates; records the tooling list'
            Includes = @('Test-SeedDiskAttached', 'Assert-GuestCredential', 'Start-VMFromInstallMedia', 'Wait-GuestReady', 'Remove-UnattendSeedDisk', 'Add-SqlDataDisk', 'Add-DevDriveDisk', 'Add-UserDataDisk', 'Connect-Guest', 'Expand-GuestSystemDrive', 'Unlock-GuestDataDisk', 'Initialize-GuestSqlDisk', 'Initialize-GuestDevDrive', 'Initialize-GuestUserDisk', 'Protect-GuestPersistentDisk', 'Enable-GuestEnhancedSession', 'Set-GuestCustomization', 'Set-GuestSysmon', 'Get-BuildTooling', 'Wait-GuestNetwork', 'Install-ToolingProduct', 'Install-SqlServerIfMissing', 'Install-WingetPackage', 'Install-OfficialInstaller', 'Update-GuestWindows', 'Initialize-VMTooling', 'Write-ToolingReinstallReport')
            Reads    = @(
                @{ Label = 'tooling list'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json, its Tooling,', 'or the shared template''s') }
                @{ Label = 'SQL Server media'; Kind = 'file'; Store = 'Shared\Installers\'; Items = @('SQLServer2025 ISO') }
                @{ Label = 'updates and packages'; Kind = 'web'; Store = 'Internet'; Items = @('VS bootstrappers, Marketplace,', 'winget, Windows Update') }
            )
            Writes   = @(
                @{ Label = 'installed and configured guest'; Kind = 'guest'; Store = 'Guest'; Items = @('D: data disk, W: Dev Drive,', 'U: User disk', 'BitLocker, Sysmon, appearance', 'VS + SSMS, extensions', 'SQL Server 2025, winget apps', 'Windows updates') }
                @{ Label = 'tooling list, what needs a manual install'; Kind = 'file'; Store = '<VM>\'; Items = @('Config\VM.json', 'State\reinstall-by-hand.txt') }
            )
        }
        @{
            Function = 'Complete-GuestConfiguration'
            Area     = 'Installation'
            Caller   = 'Invoke-BuildPhase'
            Note     = 'phase 8: 8a the SQL data disk, 8b moves SQL data files onto it, 8c answers Visual Studio''s first launch and imports its settings; a step that fails does not stop the others'
            Includes = @('Connect-Guest', 'Assert-GuestCredential', 'Invoke-IsolatedStep', 'Add-SqlDataDisk', 'Unlock-GuestDataDisk', 'Initialize-GuestSqlDisk', 'Move-GuestSqlDataFile', 'Restore-GuestVisualStudioSetting')
            Reads    = @(@{ Label = 'VS settings backup'; Kind = 'file'; Store = '<VM>\Backups\'; Items = @('VisualStudio.vssettings') })
            Writes   = @(@{ Label = 'configured guest'; Kind = 'guest'; Store = 'Guest'; Items = @('user databases on D:\SQLData', 'VS settings imported, or pending', 'for nightly maintenance') })
        }
        @{
            Function = 'Unregister-ResumeTask'
            Area     = 'Host'
            Caller   = 'Invoke-VMBuild'
            Note     = 'unless the host is restarting'
            Writes   = @(@{ Label = 'resume entries removed'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('resume task deleted', 'ResumePhase cleared') })
        }
        @{
            Function = 'Register-RebuildSchedule'
            Area     = 'Maintenance'
            Note     = 'a failure here is logged; the build still stands'
            Reads    = @(@{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'daily maintenance task'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'daily at MaintenanceTime', 'runs as SYSTEM') })
        }
    )
}
