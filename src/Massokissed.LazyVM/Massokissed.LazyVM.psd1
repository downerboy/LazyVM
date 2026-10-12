@{
    RootModule           = 'Massokissed.LazyVM.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = '08c1f0fc-8b41-4102-a4a7-847ac770437b'
    Author               = 'Massokissed'
    CompanyName          = 'Massokissed'
    Copyright            = '(c) Massokissed. All rights reserved.'
    Description          = 'Builds and looks after Hyper-V development VMs, unattended: Windows 11, Visual Studio, SQL Server and each VM''s own tooling, rebuilt automatically before the Windows evaluation expires.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')

    # Temporary while Build-LazyVM.ps1 still calls the internal functions
    # directly; replaced by the public command list once the commands exist.
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('Hyper-V', 'VM', 'VisualStudio', 'SQLServer', 'DevBox', 'Windows')
            ProjectUri = 'https://github.com/downerboy/Massokissed.LazyVM'
            LicenseUri = 'https://github.com/downerboy/Massokissed.LazyVM/blob/main/LICENSE.md'
        }
    }
}
