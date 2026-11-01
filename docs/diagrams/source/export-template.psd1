@{
    Id         = 'export-template'
    Title      = 'Save a VM as a config template'
    Command    = 'Export-LazyVMTemplate'
    Parameters = @('-Name <VM>', '-TemplateName <Template>  (optional)')
    Summary    = 'Saves a VM''s settings and tooling list as a config template that new VMs can start from with -ConfigTemplate. The template is named after the VM unless -TemplateName says otherwise, and never replaces an existing one.'
    Covers     = @('Export-LazyVMTemplate')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder'
            Reads    = @(@{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM'; Items = @('Root') })
        }
        @{
            Function = 'Resolve-VMSelection'
            Area     = 'Settings'
            Note     = 'the VM named, or the only one there is'
            Reads    = @(@{ Label = 'VM profiles'; Kind = 'file'; Store = '<Root>\'; Items = @('*\Config\VM.json') })
        }
        @{
            Function = 'Assert-TemplateNameAvailable'
            Area     = 'Settings'
            Note     = 'stops unless the name is valid and no template, built-in or yours, has it'
            Reads    = @(@{ Label = 'existing templates'; Kind = 'file'; Store = 'Config templates'; Items = @('Data\Templates\*.json', 'Shared\Templates\*.json') })
        }
        @{
            Function = 'Export-VMTemplate'
            Area     = 'Settings'
            Note     = 'the VM''s settings and tooling list, without the ones each VM has its own of'
            Reads    = @(@{ Label = 'VM configuration'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') })
            Writes   = @(
                @{ Label = 'config template'; Kind = 'file'; Store = 'Shared\Templates\'; Items = @('<Template>.json') }
                @{ Label = 'the new file'; Kind = 'output'; Store = 'Pipeline'; Items = @('FileInfo') }
            )
        }
    )
}
