@{
    Id         = 'security-approve'
    Title      = 'Approve a security finding'
    Command    = 'Approve-LazyVMSecurityFinding'
    Parameters = @('-Name <VM>', '-Id <finding Id>', '-Reason <text>  (optional)')
    Summary    = 'Records an open finding of the last scan as approved, with the date and reason, so the nightly scan stops reporting it until it changes. Changes nothing in the VM.'
    Covers     = @('Approve-LazyVMSecurityFinding', 'Get-ApprovableSecurityFinding', 'Add-SecurityApproval')
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
            Function = 'Get-ApprovableSecurityFinding'
            Area     = 'Security'
            Note     = 'before asking: stops, saying why, unless the Id is an open finding of the last scan not approved yet'
            Includes = @('Read-SecurityBaseline', 'Read-SecurityFindingRecord', 'Format-SecurityFindingTime')
            Reads    = @(
                @{ Label = 'last findings'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('SecurityFindings.json') }
                @{ Label = 'approvals'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') }
            )
        }
        @{
            Function = 'Add-SecurityApproval'
            Area     = 'Security'
            Note     = 'unless -WhatIf, or -Confirm is declined: adds the approval, never what was found'
            Includes = @('Read-SecurityBaseline', 'Save-SecurityBaseline')
            Writes   = @(@{ Label = 'approval: Id, Severity, Title, ApprovedOn, Reason'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') })
        }
    )
}
