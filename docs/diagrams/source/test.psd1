@{
    Id         = 'test'
    Title      = 'Check a VM end to end'
    Command    = 'Test-LazyVM'
    Parameters = @('-Name <VM>', '-ReportPath <file>  (optional)')
    Summary    = 'Checks the LazyVM folder, the ISOs, the VM, PowerShell Direct, the guest''s set-up and the maintenance task, and says what to run to fix each. Reads only: a VM that is off is not started.'
    Covers     = @('Test-LazyVM')
    Omits      = @{
        'Assert-Administrator' = 'stops at once unless run as administrator'
    }
    Steps      = @(
        @{
            Function = 'Get-LazyVMDiagnostic'
            Area     = 'Maintenance'
            Note     = 'every check in order; one that cannot be made is a FAIL and the rest still run'
            Includes = @('Resolve-LazyVMRoot', 'Read-VMSetting', 'Get-IsoCheck', 'Get-StoredCredential', 'New-DiagnosticCheck')
            Reads    = @(
                @{ Label = 'folder and settings'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', '<VM>\Config\VM.json') }
                @{ Label = 'media'; Kind = 'file'; Store = 'Shared\'; Items = @('ISO\Win11Ent_Eval.iso', 'Installers\SQLServer2025 ISO') }
                @{ Label = 'VM and task'; Kind = 'Hyper-V'; Store = 'Hyper-V and Task Scheduler'; Items = @('VM <VM>', 'LazyVM-Maintain-<VM>') }
                @{ Label = 'guest set-up, if running'; Kind = 'guest'; Store = 'Running guest'; Items = @('PowerShell Direct, disks', 'automatic sign-in on or off') }
            )
            Writes   = @(@{ Label = 'checks'; Kind = 'output'; Store = 'Pipeline'; Items = @('Status, Area, Check, Detail') })
        }
        @{
            Function = 'Set-Content'
            External = $true
            Area     = 'PowerShell'
            Note     = 'only with -ReportPath: the same checks as a text report'
            Writes   = @(@{ Label = 'report'; Kind = 'file'; Store = '-ReportPath'; Items = @('<file>') })
        }
    )
}
