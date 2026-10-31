# Module.Tests.ps1
# The module as users see it: what it exports, and that every command has
# the help Get-Help shows.

BeforeDiscovery {
    $manifestPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/LazyVM/LazyVM.psd1'
    $commands = @((Import-PowerShellDataFile -LiteralPath $manifestPath).FunctionsToExport | ForEach-Object { @{ Command = $_ } })
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule
}

Describe 'The module' {
    It 'exports exactly the commands in Public, each from a file of the same name' {
        $public = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object)
        $exported = @(Get-Command -Module 'LazyVM' -CommandType Function | ForEach-Object { $_.Name } | Sort-Object)

        $exported | Should -Be $public
    }

    It 'exports one alias, LazyVM, for Show-LazyVM' {
        $aliases = @(Get-Command -Module 'LazyVM' -CommandType Alias)

        $aliases.Name | Should -Be @('LazyVM')
        $aliases[0].ResolvedCommandName | Should -Be 'Show-LazyVM'
    }

    It 'uses only approved verbs' {
        $approved = @(Get-Verb | ForEach-Object { $_.Verb })
        foreach ($command in Get-Command -Module 'LazyVM' -CommandType Function) {
            $approved | Should -Contain $command.Verb -Because "$($command.Name) should use an approved verb"
        }
    }

    It 'lets every command that changes something be tried with -WhatIf and confirmed with -Confirm' {
        # Build and Invoke run whole unattended operations, which a WhatIf
        # could not meaningfully preview; the verbs below change one thing.
        $changing = 'New', 'Set', 'Remove', 'Restore', 'Save', 'Register'
        foreach ($command in Get-Command -Module 'LazyVM' | Where-Object { $changing -contains $_.Verb }) {
            $command.Parameters.Keys | Should -Contain 'WhatIf' -Because "$($command.Name) changes something"
        }
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'LazyVM.psd1') -ErrorAction Stop } | Should -Not -Throw
    }

    It 'completes -Name with the VMs in the LazyVM folder' {
        $root = Join-Path -Path $TestDrive -ChildPath 'Root'
        foreach ($name in 'Alpha', 'Beta') {
            $configDir = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath "$name\Config") -Force
            Set-Content -LiteralPath (Join-Path -Path $configDir.FullName -ChildPath 'VM.json') -Value '{}'
        }
        Mock -ModuleName 'LazyVM' Get-RegisteredRoot { $root }.GetNewClosure()

        foreach ($line in 'Get-LazyVM -Name ', 'Export-LazyVMTemplate -Name ') {
            $completions = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches

            $completions.CompletionText | Should -Be @('Alpha', 'Beta') -Because $line
        }
    }

    It 'completes <Command> -ConfigTemplate with the built-in and the user''s config templates' -ForEach @(
        @{ Command = 'New-LazyVM' }
        @{ Command = 'Build-LazyVM' }
    ) {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $templates = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Shared/Templates') -Force
        Set-Content -LiteralPath (Join-Path -Path $templates.FullName -ChildPath 'web.json') -Value '{ "Name": "WebDev", "Settings": {} }'
        Mock -ModuleName 'LazyVM' Get-RegisteredRoot { $root }.GetNewClosure()

        $line = "$Command -Name Beta -ConfigTemplate "
        $completions = (TabExpansion2 -inputScript $line -cursorColumn $line.Length).CompletionMatches

        $completions.CompletionText | Should -Be @('Developer', 'PlainWindows', 'WebDev')
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
