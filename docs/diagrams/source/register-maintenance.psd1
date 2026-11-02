@{
    Id         = 'register-maintenance'
    Title      = 'Schedule maintenance again'
    Command    = 'Register-LazyVMMaintenance'
    Parameters = @('-Name <VM>')
    Summary    = 'Build-LazyVM already does this. Use it after changing MaintenanceTime, or if scheduling failed during a build.'
    Covers     = @('Register-LazyVMMaintenance')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context and opens the log'
            Reads    = @(
                @{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKCU:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') }
            )
        }
        @{
            Function = 'Register-TrustedHostPath'
            Area     = 'Settings'
            Note     = 'allows the places outside the LazyVM folder the settings name, such as BackupDir, for the task'
            Includes = @('Get-OutsideHostPath', 'Add-TrustedHostPath')
            Writes   = @(@{ Label = 'places outside the LazyVM folder, allowed for the tasks'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('<your SID>\HostPaths') })
        }
        @{
            Function = 'Register-RebuildSchedule'
            Area     = 'Maintenance'
            Note     = 'refuses without a stored credential or a valid HH:mm MaintenanceTime; the task runs as SYSTEM and names the LazyVM folder'
            Includes = @('Assert-GuestCredential', 'Register-LazyVMHostTask')
            Reads    = @(
                @{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'daily maintenance task'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'daily at MaintenanceTime', 'as SYSTEM,', 'wake to run,', '6 h limit', '2 retries') }
            )
        }
    )
}
