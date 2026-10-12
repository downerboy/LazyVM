# Module.Tests.ps1
# The module as users see it: what it exports, and that every command has
# the help Get-Help shows.

BeforeDiscovery {
    $manifestPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/Massokissed.LazyVM/Massokissed.LazyVM.psd1'
    $commands = @((Import-PowerShellDataFile -LiteralPath $manifestPath).FunctionsToExport | ForEach-Object { @{ Command = $_ } })
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule
}

Describe 'The module' {
    It 'exports exactly the commands in Public, each from a file of the same name' {
        $public = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object)
        $exported = @(Get-Command -Module 'Massokissed.LazyVM' | ForEach-Object { $_.Name } | Sort-Object)

        $exported | Should -Be $public
    }

    It 'uses only approved verbs' {
        $approved = @(Get-Verb | ForEach-Object { $_.Verb })
        foreach ($command in Get-Command -Module 'Massokissed.LazyVM') {
            $approved | Should -Contain $command.Verb -Because "$($command.Name) should use an approved verb"
        }
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Massokissed.LazyVM.psd1') -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe '<Command>' -ForEach $commands {
    BeforeAll {
        $help = Get-Help -Name $Command -Full
    }

    It 'has a synopsis, a description and an example' {
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeLike "*$Command*"   # Get-Help's stand-in when there is none
        ($help.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'describes every parameter' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $parameters = (Get-Command -Name $Command).Parameters.Keys | Where-Object { $common -notcontains $_ }
        foreach ($parameter in $parameters) {
            $described = $help.Parameters.Parameter | Where-Object { $_.Name -eq $parameter }
            ($described.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "-$parameter needs a description"
        }
    }
}
