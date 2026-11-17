@{
    Id         = 'build-phases'
    Title      = 'List the build phases'
    Command    = 'Get-LazyVMBuildPhase'
    Parameters = @()
    Summary    = 'Lists the phases Build-LazyVM runs, in order: the number -FromPhase takes, the name, and the goal, which the app shows as a build''s progress. Only reads the module''s list of phases, so it needs no VM, no LazyVM folder and no administrator rights.'
    Covers     = @('Get-LazyVMBuildPhase')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Get-BuildPhase'
            Area     = 'Host'
            Note     = 'every phase, in order, the same list a build runs'
            Writes   = @(
                @{ Label = 'phases'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.BuildPhase: Number, Name, Goal') }
            )
        }
    )
}
