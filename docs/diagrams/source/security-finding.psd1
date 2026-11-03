@{
    Id         = 'security-finding'
    Title      = 'See the security findings'
    Command    = 'Get-LazyVMSecurityFinding'
    Parameters = @('-Name <VM>', '-Approved  (optional)')
    Summary    = 'Lists what the last nightly security scan found, but the findings approved since, from what it kept; with -Approved, the approvals instead. Does not start or scan the VM.'
    Covers     = @('Get-LazyVMSecurityFinding', 'Get-SecurityFindingList', 'Get-SecurityApprovalList')
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
            Note     = 'without -Approved: each finding of the last scan not approved since, with the VM''s name; a warning when no scan has run yet'
            Includes = @('Read-SecurityFindingRecord', 'Read-SecurityBaseline', 'Select-UnapprovedSecurityFinding')
            Reads    = @(
                @{ Label = 'last findings'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('SecurityFindings.json') }
                @{ Label = 'approvals'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') }
            )
            Writes   = @(
                @{ Label = 'findings'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.SecurityFinding: Name, Id, Severity, Title,', 'WhatWeFound, WhyItMatters, HowToFix, FirstSeen, Status') }
            )
        }
        @{
            Function = 'Get-SecurityApprovalList'
            Area     = 'Security'
            Note     = 'with -Approved: each approval, with the VM''s name; says so when there is none'
            Includes = @('Read-SecurityBaseline')
            Reads    = @(@{ Label = 'approvals'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') })
            Writes   = @(@{ Label = 'approvals'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.SecurityApproval: Name, Id, Severity,', 'Title, ApprovedOn, Reason') })
        }
    )
}
