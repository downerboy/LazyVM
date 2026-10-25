# Install.Tests.ps1
# Install.ps1, the installer in a release download: what it says when the
# folder it is given holds no built module. Nothing is installed.

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
}
