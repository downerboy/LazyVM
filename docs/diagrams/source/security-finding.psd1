@{
    Id         = 'security-finding'
    Title      = 'See the security findings'
    Command    = 'Get-LazyVMSecurityFinding'
    Parameters = @('-Name <VM>', '-Approved  (optional)')
    Summary    = 'Lists what the last nightly security scan found, but the findings approved since, from what it kept; with -Approved, the approvals instead. Does not start or scan the VM, and writes nothing to its log.'
    Covers     = @('Get-LazyVMSecurityFinding', 'Get-SecurityFindingList', 'Get-SecurityApprovalList')
    Omits      = @{ 'Assert-Administrator' = 'stops at once unless run as administrator' }
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder'
            Reads    = @(@{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') })
        }
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'the VM''s settings, read only; nothing is written to the VM''s log (#480)'
            Reads    = @(@{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') })
        }
        @{
            Function = 'Get-SecurityFindingList'
            Area     = 'Security'
            Note     = 'without -Approved: each finding of the last scan not approved since, with the VM''s name; a warning when no scan has run yet'
            Includes = @('Read-SecurityFindingRecord', 'Read-SecurityBaseline', 'Select-UnapprovedSecurityFinding', 'ConvertTo-VMRecordView')
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
