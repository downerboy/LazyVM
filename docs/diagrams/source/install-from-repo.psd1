@{
    Id         = 'install-from-repo'
    Title      = 'Install from the repository'
    Command    = './Invoke-AnalyzerAndTest.ps1'
    Parameters = @('&& ./src/Install.ps1 -Path out')
    External   = $true
    Summary    = 'Builds the module, checks it and runs the tests, then installs it for all users only if every check passes. Any failure stops before step 5. Install-FromRepository.cmd runs the same, as administrator.'
    CalledBy   = @{ Name = 'Install-FromRepository.cmd'; Kind = 'double-click'; Notes = @('asks for administrator rights') }
    Covers     = @()
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Invoke-Assemble'
            Area     = 'build\Assemble.ps1'
            Note     = 'merges Public\ and Private\ into one .psm1, then imports it to check the exports'
            Reads    = @(
                @{ Label = 'module source'; Kind = 'folder'; Store = 'src\LazyVM\'; Items = @('Public\  Private\  Data\', 'LazyVM.psd1') }
            )
            Writes   = @(
                @{ Label = 'built module'; Kind = 'folder'; Store = 'out\LazyVM\'; Items = @('<version>\') }
            )
        }
        @{
            Function = 'Install-BuildTool'
            Area     = 'build\Tools.ps1'
            Note     = 'installs the pinned version when it is missing; other versions are left alone'
            Reads    = @(
                @{ Label = 'pinned build tools'; Kind = 'web'; Store = 'PowerShell Gallery'; Items = @('PSScriptAnalyzer 1.24.0', 'Pester 5.7.1') }
            )
            Writes   = @(
                @{ Label = 'build tools, if they were missing'; Kind = 'folder'; Store = 'CurrentUser modules'; Items = @('PSScriptAnalyzer', 'Pester') }
            )
        }
        @{
            Function = 'Invoke-Analyze'
            Area     = 'build\Analyze.ps1'
            Note     = 'in a job of its own; any finding stops here'
            Reads    = @(
                @{ Label = 'code and analyzer rules'; Kind = 'folder'; Store = 'Repo'; Items = @('src\  tests\', 'PSScriptAnalyzerSettings.psd1') }
            )
        }
        @{
            Function = 'Invoke-Test'
            Area     = 'build\Test.ps1'
            Note     = 'any failure stops here'
            Reads    = @(
                @{ Label = 'Pester tests'; Kind = 'folder'; Store = 'Repo'; Items = @('tests\*.Tests.ps1') }
                @{ Label = 'built module'; Kind = 'folder'; Store = 'out\LazyVM\'; Items = @('<version>\') }
            )
            Writes   = @(
                @{ Label = 'test results'; Kind = 'file'; Store = 'out\'; Items = @('testResults.xml') }
            )
        }
        @{
            Function = 'Install.ps1'
            Arguments = '-Path out'
            External = $true
            Area     = 'script'
            Note     = 'only when every check passed: copies the newest built version and unblocks it'
            Reads    = @(@{ Label = 'built module'; Kind = 'folder'; Store = 'out\LazyVM\'; Items = @('<version>\') })
            Writes   = @(@{ Label = 'module installed for all users, SYSTEM included'; Kind = 'folder'; Store = '$env:ProgramFiles\PowerShell\'; Items = @('Modules\LazyVM\<version>\') })
        }
    )
}
