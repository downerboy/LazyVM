# Install.Tests.ps1
# Install.ps1, the installer in a release download: what it says when the
# folder it is given holds no built module, that it installs for the
# current user only, outside OneDrive, and how it adds its folder to the
# user's PSModulePath (#284). Nothing is installed.

BeforeAll {
    $installScript = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\Install.ps1'
}

Describe 'Install.ps1' {
    It 'says how to install when given <Case>' -ForEach @(
        @{ Case = 'the repository''s src folder, which holds the module''s source (#90)'; Folders = @('LazyVM\Classes', 'LazyVM\Data', 'LazyVM\Private', 'LazyVM\Public') }
        @{ Case = 'a folder with no LazyVM folder at all'; Folders = @('Other') }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($folder in $Folders) {
            New-Item -ItemType Directory -Path (Join-Path -Path $path -ChildPath $folder) -Force | Out-Null
        }

        { & $installScript -Path $path } | Should -Throw -ExpectedMessage '*There is no LazyVM module folder*./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out*'
    }

    It 'installs for the current user only, in a local folder OneDrive does not sync, without elevation (#284)' {
        $text = Get-Content -LiteralPath $installScript -Raw

        $text | Should -Not -Match '#Requires -RunAsAdministrator'
        $text | Should -Match "\`$modulesDir = Join-Path -Path \(\[Environment\]::GetFolderPath\('LocalApplicationData'\)\)"
        $text | Should -Not -Match "\`$modulesDir = Join-Path -Path \(\[Environment\]::GetFolderPath\('MyDocuments'\)\)"
        $text | Should -Not -Match '\$target = Join-Path -Path \$env:ProgramFiles'
    }
}

Describe 'Add-PathListEntry, in Install.ps1 (#284)' {
    BeforeAll {
        # The function on its own, without running the installer.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-PathListEntry' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    It 'adds <Entry> to ''<List>'', giving ''<Expected>''' -ForEach @(
        @{ List = ''; Entry = 'C:\Users\sean\AppData\Local\LazyVM\Modules'; Expected = 'C:\Users\sean\AppData\Local\LazyVM\Modules' }
        @{ List = 'D:\Modules'; Entry = 'C:\L\Modules'; Expected = 'D:\Modules;C:\L\Modules' }
        @{ List = 'D:\Modules;'; Entry = 'C:\L\Modules'; Expected = 'D:\Modules;C:\L\Modules' }
    ) {
        Add-PathListEntry -List $List -Entry $Entry | Should -Be $Expected
    }

    It 'leaves the list as it is when it has the entry already, <Case>' -ForEach @(
        @{ Case = 'written the same'; List = 'D:\Modules;C:\L\Modules' }
        @{ Case = 'in other case, with a trailing backslash'; List = 'D:\Modules;c:\l\modules\' }
        @{ Case = 'as an environment variable'; List = 'D:\Modules;%LAZYVM_TEST_ROOT%\Modules' }
    ) {
        $env:LAZYVM_TEST_ROOT = 'C:\L'
        try { Add-PathListEntry -List $List -Entry 'C:\L\Modules' | Should -Be $List }
        finally { Remove-Item -Path Env:\LAZYVM_TEST_ROOT }
    }
}
