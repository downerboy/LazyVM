@{
    Id         = 'security-finding'
    Title      = 'See the security findings'
    Command    = 'Get-LazyVMSecurityFinding'
    Parameters = @('-Name <VM>')
    Summary    = 'Lists what the last nightly security scan found, from what it kept. Does not start or scan the VM.'
    Covers     = @('Get-LazyVMSecurityFinding', 'Get-SecurityFindingList')
    Omits      = @{ 'Write-LogWarning' = 'only when no scan has run yet: says so, in the log and on screen' }
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
            Function = 'Get-SecurityFindingList'
            Area     = 'Security'
            Note     = 'each finding of the last scan, with the VM''s name; a warning when no scan has run yet'
            Includes = @('Read-SecurityFindingRecord')
            Reads    = @(
                @{ Label = 'last findings'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('SecurityFindings.json') }
            )
            Writes   = @(
                @{ Label = 'findings'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.SecurityFinding: Name, Id, Severity, Title,', 'WhatWeFound, WhyItMatters, HowToFix, FirstSeen, Status') }
            )
        }
    )
}
