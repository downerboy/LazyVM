@{
    Id         = 'capture'
    Title      = 'Capture state'
    Command    = 'Save-LazyVMState'
    Parameters = @('-Name <VM>')
    Summary    = 'Copies to the host what a rebuild must keep and the VM''s records do not, into a capture folder of its own; the newest three are kept. Maintenance and rebuilds run the same capture. Environment, firewall rules, scheduled tasks, SQL logins and Agent jobs and application settings are recorded in VM.json every night instead (see Daily maintenance).'
    Covers     = @('Save-LazyVMState', 'Save-GuestState')
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
            Function = 'Save-GuestState'
            Area     = 'Capture'
            Note     = 'steps 3-12 are its calls; each area runs isolated (Invoke-IsolatedStep): one that fails is a warning in the manifest and the rest still run'
            Includes = @('Invoke-IsolatedStep', 'Get-Stamp', 'New-Folder')
            Writes   = @(@{ Label = 'capture folder'; Kind = 'folder'; Store = '<VM>\State\Captures\'; Items = @('<stamp>\') })
        }
        @{
            Function = 'Open-GuestSession'
            Area     = 'Guest'
            Caller   = 'Save-GuestState'
            Note     = 'starts the VM if it is off and waits for it'
            Reads    = @(@{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'PowerShell Direct session'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('running, reachable') })
        }
        @{
            Function = 'Initialize-GuestSqlDisk'
            Area     = 'Installation'
            Caller   = 'Save-GuestState'
            Note     = 'finds the data disk''s letter, so backups land on it'
        }
        @{
            Function = 'Get-GuestIdentity'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'computer name, user, OS build, install date, time zone'
            Reads    = @(@{ Label = 'guest identity'; Kind = 'guest'; Store = 'Running guest'; Items = @('Win32_OperatingSystem') })
        }
        @{
            Function = 'Save-GuestVisualStudioState'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'Visual Studio settings, NuGet.Config, .gitconfig, snippets and templates; workloads and extensions are in the tooling list'
            Reads    = @(@{ Label = 'Visual Studio files'; Kind = 'guest'; Store = 'Running guest'; Items = @('settings per instance', 'NuGet.Config, .gitconfig', 'Documents snippets, templates') })
            Writes   = @(
                @{ Label = 'VS files'; Kind = 'folder'; Store = '<VM>\State\Captures\<stamp>\'; Items = @('vs\') }
                @{ Label = 'settings for phase 8 and maintenance'; Kind = 'file'; Store = '<VM>\Backups\'; Items = @('VisualStudio.vssettings') }
            )
        }
        @{
            Function = 'Save-GuestSqlState'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'backs up every user database to the data disk and checks each backup'
            Reads    = @(@{ Label = 'databases'; Kind = 'guest'; Store = 'SQL Server'; Items = @('user databases') })
            Writes   = @(@{ Label = 'backups on the data disk'; Kind = 'folder'; Store = 'D:\SQLBackup\'; Items = @('<database>.bak') })
        }
        @{
            Function = 'Save-GuestWindowsState'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'certificates, the private keys protected with a password kept in the credential store'
            Reads    = @(@{ Label = 'certificates'; Kind = 'guest'; Store = 'Running guest'; Items = @('certificate stores') })
            Writes   = @(
                @{ Label = 'Windows archive'; Kind = 'file'; Store = '<VM>\State\Captures\<stamp>\'; Items = @('windows\winstate.zip') }
                @{ Label = 'certificate password'; Kind = 'file'; Store = '<VM>\Credentials\'; Items = @('certs.cred') }
            )
        }
        @{
            Function = 'Save-GuestAppSetting'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'records the AppSettings keys in VM.json; nothing goes into the capture itself'
            Reads    = @(@{ Label = 'registry values'; Kind = 'guest'; Store = 'AppSettings keys'; Items = @('HKCU\Software\...') })
            Writes   = @(
                @{ Label = 'application settings'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  GuestAppSettings') }
                @{ Label = 'secret values'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\') }
            )
        }
        @{
            Function = 'Get-GuestStateFingerprint'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'certificate thumbprints and the Visual Studio settings hash, which nightly maintenance compares'
            Reads    = @(@{ Label = 'fingerprint'; Kind = 'guest'; Store = 'Running guest'; Items = @('certificates, VS settings') })
        }
        @{
            Function = 'Write-TextFileAtomic'
            Area     = 'Common'
            Caller   = 'Save-GuestState'
            Note     = 'the manifest, in the capture folder and as the newest capture, which restore reads'
            Includes = @('Get-CaptureManifestPath')
            Writes   = @(@{ Label = 'manifest'; Kind = 'file'; Store = '<VM>\State\'; Items = @('Captures\<stamp>\manifest.json', 'manifest.json') })
        }
        @{
            Function = 'Remove-OldCapture'
            Area     = 'Capture'
            Caller   = 'Save-GuestState'
            Note     = 'keeps the newest 3 capture folders'
            Writes   = @(@{ Label = 'older captures deleted'; Kind = 'folder'; Store = '<VM>\State\Captures\'; Items = @('all but the newest 3') })
        }
    )
}
