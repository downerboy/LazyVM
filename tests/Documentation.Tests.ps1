# Documentation.Tests.ps1
# Show-LazyVMHelp opens the guide, the use cases or the diagrams for the
# installed version in the browser (#501). It only opens a page: nothing is
# fetched or run, and only the three fixed pages can be asked for. The
# browser is mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
}

Describe 'Get-DocumentationUrl' {
    It 'points at the page of the installed version, by its release tag' {
        $url = InModuleScope $module { Get-DocumentationUrl -Topic Guide -Version ([version]'6.39.0') -Prerelease '' }

        $url | Should -Be 'https://github.com/downerboy/LazyVM/blob/v6.39.0/docs/Guide.md'
    }

    It 'names the page for each topic' -ForEach @(
        @{ Topic = 'Guide'; Page = 'docs/Guide.md' }
        @{ Topic = 'UseCases'; Page = 'docs/UseCases.md' }
        @{ Topic = 'Diagrams'; Page = 'docs/Diagrams.md' }
    ) {
        $url = InModuleScope $module -Parameters @{ Topic = $Topic } { Get-DocumentationUrl -Topic $Topic -Version ([version]'6.39.0') -Prerelease '' }

        $url | Should -BeLike "*/v6.39.0/$Page"
    }

    It 'points at main for a build with a prerelease label, which has no release tag' {
        $url = InModuleScope $module { Get-DocumentationUrl -Topic Diagrams -Version ([version]'7.0.0') -Prerelease 'alpha1' }

        $url | Should -Be 'https://github.com/downerboy/LazyVM/blob/main/docs/Diagrams.md'
    }
}

Describe 'Show-LazyVMHelp' {
    BeforeEach {
        Mock -ModuleName $module Start-Process { }
    }

    It 'opens the guide by default, with nothing but the address' {
        Show-LazyVMHelp

        Should -Invoke -ModuleName $module Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like 'https://github.com/downerboy/LazyVM/blob/*/docs/Guide.md' -and -not $ArgumentList
        }
    }

    It 'opens the page for the topic asked for' -ForEach @(
        @{ Topic = 'UseCases'; Page = 'UseCases.md' }
        @{ Topic = 'Diagrams'; Page = 'Diagrams.md' }
    ) {
        Show-LazyVMHelp -Topic $Topic

        Should -Invoke -ModuleName $module Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -like "*/docs/$Page" }
    }

    It 'opens the page of the module version the command belongs to' {
        $version = (Get-Module -Name $module).Version

        Show-LazyVMHelp

        Should -Invoke -ModuleName $module Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -like "*/blob/v$version/*" -or $FilePath -like '*/blob/main/*' }
    }

    It 'refuses a topic that is not one of the three pages' {
        { Show-LazyVMHelp -Topic 'https://example.com' } | Should -Throw

        Should -Invoke -ModuleName $module Start-Process -Times 0 -Exactly
    }

    It 'says why when the browser cannot be opened' {
        Mock -ModuleName $module Start-Process { throw 'No default browser' }

        { Show-LazyVMHelp -ErrorAction Stop } | Should -Throw '*No default browser*'
    }
}
