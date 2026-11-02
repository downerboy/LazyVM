@{
    Id         = 'set-credential'
    Title      = 'Store the guest account'
    Command    = 'Set-LazyVMCredential'
    Parameters = @('-Name <VM>', '-Credential  (optional)', '-Force  (optional)')
    Summary    = 'Optional before a build: Build-LazyVM generates an account if none is stored. This does not change the password inside an existing VM.'
    Covers     = @('Set-LazyVMCredential')
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
            Function = 'Get-GuestCredential'
            Area     = 'Credentials'
            Note     = 'the stored account, if any: asks before replacing it unless -Force'
            Reads    = @(
                @{ Label = 'guest credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '<VM>\Credentials\guest.cred') }
            )
        }
        @{
            Function = 'Get-Credential'
            External = $true
            Area     = 'PowerShell'
            Note     = 'prompt, if -Credential was not given'
            Reads    = @(
                @{ Label = 'credential typed in'; Kind = 'user'; Store = 'You'; Items = @('user name', 'password', '(empty = generate one)') }
            )
        }
        @{
            Function = 'Set-StoredGuestCredential'
            Area     = 'Credentials'
            Note     = 'local accounts only; Save-StoredCredential encrypts with the key'
            Writes   = @(
                @{ Label = 'encrypted credential'; Kind = 'file'; Store = 'Credential store'; Items = @('Shared\Credentials\.lazyvm.key', '(once; SYSTEM + Administrators)', '<VM>\Credentials\guest.cred') }
            )
        }
    )
}
