# ReleasePackage.Tests.ps1
# The release zip built by build\Package.ps1: what it holds, and where. The
# README in it shows the logo, so the logo has to be in the zip at the path
# the README names.

BeforeAll {
    Set-StrictMode -Version 3.0
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'build/Package.ps1')
}

Describe 'New-ReleasePackage' {
    BeforeAll {
        $root = Join-Path -Path $TestDrive -ChildPath 'repo'
        $moduleSource = Join-Path -Path $root -ChildPath 'src/Demo'
        $built = Join-Path -Path $root -ChildPath 'out/Demo/1.2.3'
        $null = New-Item -ItemType Directory -Path $moduleSource, $built, (Join-Path -Path $root -ChildPath 'docs/images') -Force
        Set-Content -LiteralPath (Join-Path -Path $moduleSource -ChildPath 'Demo.psd1') -Value "@{ ModuleVersion = '1.2.3'; PrivateData = @{ PSData = @{ } } }"
        Set-Content -LiteralPath (Join-Path -Path $built -ChildPath 'Demo.psm1') -Value '# module'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'src/Install.ps1') -Value '# install'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'README.md') -Value '# readme'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'LICENSE.md') -Value '# licence'
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'docs/images/logo.svg') -Value '<svg/>'

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

    It 'puts the logo at docs/images/logo.svg, where the README shows it from' {
        $script:entries | Should -Contain 'docs/images/logo.svg'
    }

    It 'puts the built module in a folder named for the module' {
        $script:entries | Should -Contain 'Demo/1.2.3/Demo.psm1'
    }
}
