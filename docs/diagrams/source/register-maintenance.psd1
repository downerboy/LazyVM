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
                @{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') }
            )
        }
        @{
            Function = 'Register-RebuildSchedule'
            Area     = 'Maintenance'
            Note     = 'refuses without a stored credential or a valid HH:mm MaintenanceTime'
            Includes = @('Assert-GuestCredential')
            Reads    = @(
                @{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'daily maintenance task'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'daily at MaintenanceTime', 'SYSTEM', 'wake to run,', '6 h limit', '2 retries') }
            )
        }
    )
}
