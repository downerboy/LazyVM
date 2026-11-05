@{
    Id         = 'security-revoke'
    Title      = 'Revoke a security finding approval'
    Command    = 'Revoke-LazyVMSecurityFinding'
    Parameters = @('-Name <VM>', '-Id <finding Id>')
    Summary    = 'Removes an approval, so the next nightly scan reports the finding again if it still finds it. Changes nothing in the VM.'
    Covers     = @('Revoke-LazyVMSecurityFinding', 'Get-SecurityApproval', 'Remove-SecurityApproval')
    Omits      = @{ 'Write-CommandItemError' = 'only for an Id that is not approved: logs why, and writes it as an error of that pipeline item' }
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
            Function = 'Get-SecurityApproval'
            Area     = 'Security'
            Note     = 'before asking: unless the Id is approved, says so as an error, and the pipeline goes on'
            Includes = @('Read-SecurityBaseline')
            Reads    = @(@{ Label = 'approvals'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') })
        }
        @{
            Function = 'Remove-SecurityApproval'
            Area     = 'Security'
            Note     = 'unless -WhatIf, or -Confirm is declined: removes the approval'
            Includes = @('Update-SecurityBaseline')
            Writes   = @(@{ Label = 'approvals without it'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('SecurityBaseline.json') })
        }
    )
}
