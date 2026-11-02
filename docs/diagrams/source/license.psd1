@{
    Id         = 'license'
    Title      = 'Check the license'
    Command    = 'Get-LazyVMLicense'
    Parameters = @('-Name <VM>')
    Summary    = 'Evaluation days and rearms left, the last capture, and what the next maintenance run will do. Starts the VM if it is off.'
    Covers     = @('Get-LazyVMLicense', 'Get-LicenseReport')
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
            Function = 'Get-LicenseReport'
            Area     = 'Maintenance'
            Note     = 'steps 3-6 are its calls'
        }
        @{
            Function = 'Open-GuestSession'
            Area     = 'Guest'
            Caller   = 'Get-LicenseReport'
            Note     = 'starts the VM if it is off and waits for it'
            Reads    = @(
                @{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'PowerShell Direct session'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('running, reachable') }
            )
        }
        @{
            Function = 'Get-GuestLicenseStatus'
            Area     = 'Maintenance'
            Caller   = 'Get-LicenseReport'
            Note     = 'days left, rearms left'
            Reads    = @(
                @{ Label = 'license status'; Kind = 'guest'; Store = 'Running guest'; Items = @('SoftwareLicensingProduct') }
            )
        }
        @{
            Function = 'Get-CaptureManifest'
            Area     = 'Capture'
            Caller   = 'Get-LicenseReport'
            Note     = 'when the last capture was taken, and its databases'
            Reads    = @(
                @{ Label = 'last capture, databases'; Kind = 'file'; Store = '<VM>\State\'; Items = @('manifest.json') }
            )
        }
        @{
            Function = 'Get-MaintenanceDecision'
            Area     = 'Maintenance'
            Caller   = 'Get-LicenseReport'
            Note     = 'none, rearm or rebuild'
            Writes   = @(
                @{ Label = 'license report'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.License: days', 'rearms,', 'last capture', 'next action') }
            )
        }
    )
}
