@{
    Id         = 'config-templates'
    Title      = 'List the config templates'
    Command    = 'Get-LazyVMConfigTemplate'
    Parameters = @()
    Summary    = 'Lists the config templates a new VM can be created from: the built-in ones and your own, each name once, as a build would use it. A file that cannot be read, or a name several of yours share, is left out with a warning. Only reads, so no administrator rights are needed.'
    Covers     = @('Get-LazyVMConfigTemplate', 'Select-NamedVMTemplate')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Get-RegisteredRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder, if one is chosen yet'
            Reads    = @(
                @{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'Get-VMTemplate'
            Area     = 'Settings'
            Note     = 'every template file, built-in first; a file that cannot be read keeps its problem, which becomes a warning'
            Includes = @('Read-VMTemplateFile')
            Reads    = @(
                @{ Label = 'config templates'; Kind = 'file'; Store = 'Templates'; Items = @('<module>\Data\Templates\*.json', 'Shared\Templates\*.json') }
            )
        }
        @{
            Function = 'Select-VMTemplateName'
            Area     = 'Settings'
            Note     = 'the names of the usable ones, sorted, each once'
        }
        @{
            Function = 'Select-NamedVMTemplate'
            Area     = 'Settings'
            Note     = 'for each name, yours over a built-in one; a name several of yours share becomes a warning'
            Writes   = @(
                @{ Label = 'templates'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.ConfigTemplate: Name, BuiltIn, Automatic, Path') }
            )
        }
    )
}
