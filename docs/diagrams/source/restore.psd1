@{
    Id         = 'restore'
    Title      = 'Restore state'
    Command    = 'Restore-LazyVMState'
    Parameters = @('-Name <VM>')
    Summary    = 'Puts the newest capture and the VM''s records back into the VM. A rebuild runs the same restore.'
    Covers     = @('Restore-LazyVMState', 'Restore-GuestState')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context and opens the log'
            Reads    = @(@{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') })
        }
        @{
            Function = 'Restore-GuestState'
            Area     = 'Restore'
            Note     = 'steps 3-9 are its calls; each area runs isolated (Invoke-IsolatedStep), so a failed one does not stop the rest'
            Includes = @('Invoke-IsolatedStep', 'Get-CaptureManifestPath')
        }
        @{
            Function = 'Get-CaptureManifest'
            Area     = 'Capture'
            Caller   = 'Restore-GuestState'
            Note     = 'none: nothing to restore, and that is not a failure'
            Reads    = @(@{ Label = 'what was captured'; Kind = 'file'; Store = '<VM>\State\'; Items = @('manifest.json') })
        }
        @{
            Function = 'Open-GuestSession'
            Area     = 'Guest'
            Caller   = 'Restore-GuestState'
            Note     = 'starts the VM if it is off and waits for it'
            Reads    = @(@{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'PowerShell Direct session'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('running, reachable') })
        }
        @{
            Function = 'Initialize-GuestSqlDisk'
            Area     = 'Installation'
            Caller   = 'Restore-GuestState'
            Note     = 'finds the data disk''s letter'
        }
        @{
            Function = 'Restore-GuestWindowsState'
            Area     = 'Restore'
            Caller   = 'Restore-GuestState'
            Note     = '10a: environment, firewall rules and scheduled tasks from VM.json; certificates from the archive'
            Reads    = @(
                @{ Label = 'records'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  GuestEnvironment,', 'GuestFirewallRules, GuestScheduledTasks') }
                @{ Label = 'Windows archive'; Kind = 'file'; Store = '<VM>\State\Captures\<stamp>\'; Items = @('windows\winstate.zip') }
                @{ Label = 'secrets, certificate password'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\') }
            )
            Writes   = @(@{ Label = 'Windows restored'; Kind = 'guest'; Store = 'New guest'; Items = @('environment, firewall rules', 'scheduled tasks, certificates') })
        }
        @{
            Function = 'Restore-GuestVisualStudioState'
            Area     = 'Restore'
            Caller   = 'Restore-GuestState'
            Note     = '10b: Visual Studio files'
            Reads    = @(@{ Label = 'VS files'; Kind = 'folder'; Store = '<VM>\State\Captures\<stamp>\'; Items = @('vs\') })
            Writes   = @(@{ Label = 'VS files restored'; Kind = 'guest'; Store = 'New guest'; Items = @('NuGet.Config, .gitconfig', 'snippets, templates') })
        }
        @{
            Function = 'Restore-GuestSqlState'
            Area     = 'Restore'
            Caller   = 'Restore-GuestState'
            Note     = '10c: instance settings, logins with their SIDs, databases (attached from D:, or from their backups), then Agent jobs'
            Reads    = @(
                @{ Label = 'SQL records'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  GuestSql') }
                @{ Label = 'database files and backups'; Kind = 'folder'; Store = 'D: data disk'; Items = @('D:\SQLData\', 'D:\SQLBackup\<database>.bak') }
            )
            Writes   = @(@{ Label = 'SQL restored'; Kind = 'guest'; Store = 'SQL Server'; Items = @('settings, logins, databases', 'Agent jobs, operators, alerts') })
        }
        @{
            Function = 'Restore-GuestAppSetting'
            Area     = 'Restore'
            Caller   = 'Restore-GuestState'
            Note     = '10e: the application settings VM.json records'
            Reads    = @(
                @{ Label = 'app settings'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  GuestAppSettings') }
                @{ Label = 'secret values'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\') }
            )
            Writes   = @(@{ Label = 'app settings restored'; Kind = 'guest'; Store = 'New guest'; Items = @('registry values written') })
        }
        @{
            Function = 'Restore-GuestVisualStudioSetting'
            Area     = 'Installation'
            Note     = 'imports the Visual Studio settings; when it cannot, nightly maintenance does'
            Reads    = @(@{ Label = 'VS settings backup'; Kind = 'file'; Store = '<VM>\Backups\'; Items = @('VisualStudio.vssettings') })
            Writes   = @(@{ Label = 'VS settings'; Kind = 'guest'; Store = 'Visual Studio'; Items = @('imported, or pending') })
        }
    )
}
