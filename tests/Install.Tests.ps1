# Install.Tests.ps1
# Install.ps1, the installer in a release download: what it says when the
# folder it is given holds no built module, that it installs for the
# current user only, outside OneDrive, and how it adds its folder to the
# user's PSModulePath (#284), and how it removes earlier copies that would
# load instead of the installed version (#311). Nothing is installed.

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

    It 'installs in Program Files, locked so only administrators can change it, which needs elevation (#284)' {
        $text = Get-Content -LiteralPath $installScript -Raw

        $text | Should -Match '#Requires -RunAsAdministrator'
        $text | Should -Match '\$installDir = Join-Path -Path \$env:ProgramFiles -ChildPath \$moduleName'
        $text | Should -Match 'Set-InstallFolderAccess -Path \$installDir'
    }
}

Describe 'The user''s PSModulePath, in Install.ps1 (#284)' {
    BeforeAll {
        # The function on its own, without running the installer.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Add-PathListEntry', 'Remove-PathListEntry', 'Test-SameFolder') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
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

    It 'takes out an earlier module folder however it is written, keeping the rest' {
        $env:LAZYVM_TEST_ROOT = 'C:\L'
        try { Remove-PathListEntry -List 'D:\Modules;%LAZYVM_TEST_ROOT%\Modules\;E:\M' -Entry 'C:\L\Modules' | Should -Be 'D:\Modules;E:\M' }
        finally { Remove-Item -Path Env:\LAZYVM_TEST_ROOT }
    }
}

Describe 'Earlier copies, in Install.ps1 (#311)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Test-LinkInFolder', 'Remove-EarlierCopy', 'Get-OtherModuleVersion', 'Write-ShadowingCopyWarning', 'Test-SameFolder') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        # A junction, as Windows makes without elevation; elsewhere, a symbolic link.
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    }

    BeforeEach {
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'LazyVM\5.2.0') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'LazyVM\5.2.0\LazyVM.psd1') -Value '@{}'
        $outside = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') -Value 'keep'
    }

    It 'removes an earlier copy and says where' {
        $copy = Join-Path -Path $folder -ChildPath 'LazyVM'

        $said = Remove-EarlierCopy -Path $copy 6>&1

        Test-Path -LiteralPath $copy | Should -BeFalse
        "$said" | Should -BeLike "*Removed*$copy*"
    }

    It 'does nothing when there is no copy' {
        $said = Remove-EarlierCopy -Path (Join-Path -Path $folder -ChildPath 'Missing') 6>&1 3>&1

        $said | Should -BeNullOrEmpty
    }

    It 'keeps a copy that is a link, warning, and leaves what it points to alone' {
        $link = Join-Path -Path $folder -ChildPath 'Linked'
        New-Item -ItemType $linkType -Path $link -Target $outside | Out-Null

        $warning = Remove-EarlierCopy -Path $link 3>&1

        Test-Path -LiteralPath $link | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$link*link*"
    }

    It 'keeps a copy that holds a link, warning, and removes nothing from it' {
        $copy = Join-Path -Path $folder -ChildPath 'LazyVM'
        New-Item -ItemType $linkType -Path (Join-Path -Path $copy -ChildPath '5.2.0\Data') -Target $outside | Out-Null

        $warning = Remove-EarlierCopy -Path $copy 3>&1

        Test-Path -LiteralPath (Join-Path -Path $copy -ChildPath '5.2.0\LazyVM.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$copy*"
    }

    It 'finds every version but the one being installed' {
        $module = Join-Path -Path $folder -ChildPath 'LazyVM'
        foreach ($name in '6.4.0', '6.3.1', 'Notes') {
            New-Item -ItemType Directory -Path (Join-Path -Path $module -ChildPath $name) -Force | Out-Null
        }

        $other = @(Get-OtherModuleVersion -Path $module -Keep '6.4.0' | ForEach-Object { $_.Name } | Sort-Object)

        $other | Should -Be @('5.2.0', '6.3.1')
    }

    It 'finds no other version when there is no module folder' {
        @(Get-OtherModuleVersion -Path (Join-Path -Path $folder -ChildPath 'Missing') -Keep '6.4.0').Count | Should -Be 0
    }

    It 'says nothing when the installed version comes first on PSModulePath' {
        Mock Get-Module { [pscustomobject]@{ ModuleBase = 'C:\Program Files\LazyVM\Modules\LazyVM\6.4.0' } } -ParameterFilter { $ListAvailable }

        Write-ShadowingCopyWarning -Path 'C:\Program Files\LazyVM\Modules\LazyVM\6.4.0\' 3>&1 | Should -BeNullOrEmpty
    }

    It 'warns with the path of a copy that comes before the installed version' {
        Mock Get-Module {
            [pscustomobject]@{ ModuleBase = 'D:\Modules\LazyVM\5.2.0' }
            [pscustomobject]@{ ModuleBase = 'C:\Program Files\LazyVM\Modules\LazyVM\6.4.0' }
        } -ParameterFilter { $ListAvailable }

        $warning = Write-ShadowingCopyWarning -Path 'C:\Program Files\LazyVM\Modules\LazyVM\6.4.0' 3>&1

        "$warning" | Should -BeLike '*D:\Modules\LazyVM\5.2.0*'
    }

    It 'removes LazyVM 5''s copy and every other version, then checks which loads first' {
        $text = Get-Content -LiteralPath $installScript -Raw

        $text | Should -Match 'foreach \(\$earlier in .*\$machineWide\) \{\s+Remove-EarlierCopy -Path \$earlier'
        $text | Should -Match 'Get-OtherModuleVersion -Path'
        $text | Should -Match 'Write-ShadowingCopyWarning -Path \$target'
    }
}
