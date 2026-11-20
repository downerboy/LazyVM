# ReleasePackage.Tests.ps1
# The release zip built by build\Package.ps1: what it holds, and where. The
# README in it shows the logo, so the logo has to be in the zip at the path
# the README names. The app, published by build\Publish.ps1, goes in App
# beside the module (#489).

BeforeAll {
    Set-StrictMode -Version 3.0
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'build/Package.ps1')
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'build/Publish.ps1')

    function New-TestRepository {
        <# A repository with a built Demo module 1.2.3, and with -WithApp, a published app in out\App. #>
        param([switch]$WithApp)
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $moduleSource = Join-Path -Path $root -ChildPath 'src/Demo'
        $built = Join-Path -Path $root -ChildPath 'out/Demo/1.2.3'
        $null = New-Item -ItemType Directory -Path $moduleSource, $built, (Join-Path -Path $root -ChildPath 'docs/images') -Force
        Set-Content -LiteralPath (Join-Path -Path $moduleSource -ChildPath 'Demo.psd1') -Value "@{ ModuleVersion = '1.2.3'; PrivateData = @{ PSData = @{ } } }"
        Set-Content -LiteralPath (Join-Path -Path $built -ChildPath 'Demo.psm1') -Value '# module'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'src/Install.ps1') -Value '# install'
        foreach ($launcher in 'Install LazyVM.cmd', 'Uninstall LazyVM.cmd') {
            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath "src/$launcher") -Value '@echo off'
        }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'README.md') -Value '# readme'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'LICENSE.md') -Value '# licence'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'docs/images/logo.svg') -Value '<svg/>'
        if ($WithApp) {
            New-TestApp -Path (Join-Path -Path $root -ChildPath 'out/App')
        }
        return $root
    }

    function New-TestApp {
        <# A published app at $Path, as Assert-PublishedApp expects it, less the parts in $Without. #>
        param([string]$Path, [string[]]$Without = @())
        $parts = @('LazyVM.UI.Wpf.exe', 'System.Management.Automation.dll', 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
        foreach ($part in $parts | Where-Object { $_ -notin $Without }) {
            $file = Join-Path -Path $Path -ChildPath $part
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $file -Parent) -Force
            Set-Content -LiteralPath $file -Value 'x'
        }
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

Describe 'New-ReleasePackage' {
    BeforeAll {
        $root = New-TestRepository -WithApp

        Mock Write-Host { }
        New-ReleasePackage -Root $root -ModuleName 'Demo'

        $archive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path -Path $root -ChildPath 'out/release/Demo-1.2.3.zip'))
        try { $script:entries = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) }
        finally { $archive.Dispose() }
    }

    It 'puts the installer, the README and the licence at the top of the zip' {
        $script:entries | Should -Contain 'Install.ps1'
        $script:entries | Should -Contain 'README.md'
        $script:entries | Should -Contain 'LICENSE.md'
    }

    It 'puts the launchers a user double-clicks at the top of the zip, beside Install.ps1 (#490)' {
        $script:entries | Should -Contain 'Install LazyVM.cmd'
        $script:entries | Should -Contain 'Uninstall LazyVM.cmd'
    }

    It 'puts the logo at docs/images/logo.svg, where the README shows it from' {
        $script:entries | Should -Contain 'docs/images/logo.svg'
    }

    It 'puts the built module in a folder named for the module' {
        $script:entries | Should -Contain 'Demo/1.2.3/Demo.psm1'
    }

    It 'puts the published app in App, beside the module, where Install.ps1 looks for it (#489)' {
        $script:entries | Should -Contain 'App/LazyVM.UI.Wpf.exe'
        $script:entries | Should -Contain 'App/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1'
    }
}

Describe 'New-ReleasePackage without the app (#489)' {
    It 'stops, so no release ships without the app' {
        $root = New-TestRepository
        Mock Write-Host { }

        { New-ReleasePackage -Root $root -ModuleName 'Demo' } | Should -Throw -ExpectedMessage '*no published app*Publish-App*'
        Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'out/release/Demo-1.2.3.zip') | Should -BeFalse
    }
}

Describe 'Assert-PublishedApp (#489)' {
    It 'passes an app with its exe, PowerShell, and PowerShell''s built-in modules beside it' {
        $app = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-TestApp -Path $app

        { Assert-PublishedApp -Path $app } | Should -Not -Throw
    }

    It 'stops, naming what is missing, when <Missing> is not there' -ForEach @(
        @{ Missing = 'LazyVM.UI.Wpf.exe' }
        @{ Missing = 'System.Management.Automation.dll' }
        @{ Missing = 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1' }
    ) {
        $app = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-TestApp -Path $app -Without $Missing

        { Assert-PublishedApp -Path $app } | Should -Throw -ExpectedMessage "*$(Split-Path -Path $Missing -Leaf)*"
    }
}
