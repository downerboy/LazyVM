# AppBuild.Tests.ps1
# Scripts\Start-AppBuild.ps1, the script the LazyVM app runs each build
# with, in a pwsh process of its own (#427). It runs here with pwsh -File,
# as the app runs it, next to a stand-in LazyVM module whose Build-LazyVM
# records what it was given, so nothing is built.

BeforeAll {
    $source = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\LazyVM\Scripts\Start-AppBuild.ps1'
    $pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'

    $moduleDir = Join-Path -Path $TestDrive -ChildPath 'LazyVM'
    $null = New-Item -ItemType Directory -Path (Join-Path -Path $moduleDir -ChildPath 'Scripts')
    Copy-Item -LiteralPath $source -Destination (Join-Path -Path $moduleDir -ChildPath 'Scripts')
    Copy-Item -LiteralPath (Join-Path -Path (Split-Path -Path $source -Parent) -ChildPath 'AppProcess.ps1') -Destination (Join-Path -Path $moduleDir -ChildPath 'Scripts')
    $script = Join-Path -Path $moduleDir -ChildPath 'Scripts\Start-AppBuild.ps1'
    $calls = Join-Path -Path $TestDrive -ChildPath 'calls.json'
    $modulePathFile = Join-Path -Path $TestDrive -ChildPath 'module-path.txt'
    Set-Content -LiteralPath (Join-Path -Path $moduleDir -ChildPath 'LazyVM.psm1') -Value @"
function Build-LazyVM {
    [CmdletBinding()]
    param([string]`$Name, [string]`$ConfigTemplate, [string]`$UserName, [int]`$FromPhase)
    `$PSBoundParameters | ConvertTo-Json -Compress | Set-Content -LiteralPath '$calls'
    Set-Content -LiteralPath '$modulePathFile' -Value `$env:PSModulePath
    if (`$Name -eq 'Stopped') {
        `$PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([Exception]::new('The build of Stopped was stopped in phase 7, as asked.'), 'LazyVM.RunStopped', 'OperationStopped', `$Name))
    }
    if (`$Name -eq 'Failed') { throw 'There is no Windows ISO.' }
}
"@
    New-ModuleManifest -Path (Join-Path -Path $moduleDir -ChildPath 'LazyVM.psd1') -RootModule 'LazyVM.psm1' -FunctionsToExport 'Build-LazyVM'

    function Invoke-AppBuild {
        param([string[]]$Arguments)
        $resultPath = Join-Path -Path $TestDrive -ChildPath "result-$([guid]::NewGuid()).json"
        & $pwsh -NoProfile -NonInteractive -File $script @Arguments -ResultPath $resultPath | Out-Null
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Result   = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            Call     = Get-Content -LiteralPath $calls -Raw | ConvertFrom-Json -AsHashtable
        }
    }
}

Describe 'Start-AppBuild.ps1' {
    BeforeEach { Remove-Item -LiteralPath $calls -ErrorAction SilentlyContinue }

    It 'builds the VM with the template and the user name, and ends with Completed and exit code 0' {
        $run = Invoke-AppBuild -Arguments '-Name', 'DevBox', '-ConfigTemplate', 'PlainWindows', '-UserName', 'sean'

        $run.ExitCode | Should -Be 0
        $run.Result.Outcome | Should -Be 'Completed'
        $run.Call.Name | Should -Be 'DevBox'
        $run.Call.ConfigTemplate | Should -Be 'PlainWindows'
        $run.Call.UserName | Should -Be 'sean'
    }

    It 'passes no template or user name when they are not given' {
        $run = Invoke-AppBuild -Arguments '-Name', 'DevBox'

        $run.Call.Keys | Should -Be @('Name')
    }

    It 'builds from the phase it is given, and passes no phase when it is not given' {
        $run = Invoke-AppBuild -Arguments '-Name', 'DevBox', '-FromPhase', '7'

        $run.Call.FromPhase | Should -Be 7
        (Invoke-AppBuild -Arguments '-Name', 'DevBox').Call.Keys | Should -Not -Contain 'FromPhase'
    }

    It 'builds from phase 0 when that is the phase given' {
        $run = Invoke-AppBuild -Arguments '-Name', 'DevBox', '-FromPhase', '0'

        $run.Call.Keys | Should -Contain 'FromPhase'
        $run.Call.FromPhase | Should -Be 0
    }

    It 'passes a value with quotes and spaces as it is, never as script text' {
        $run = Invoke-AppBuild -Arguments '-Name', 'DevBox', '-ConfigTemplate', "My 'own'; template"

        $run.Call.ConfigTemplate | Should -Be "My 'own'; template"
    }

    It 'loads modules only from folders administrators control, never from the user''s own' {
        $env:PSModulePath = "$TestDrive\UserModules$([IO.Path]::PathSeparator)$env:PSModulePath"
        try { $null = Invoke-AppBuild -Arguments '-Name', 'DevBox' }
        finally { $env:PSModulePath = $env:PSModulePath.Substring("$TestDrive\UserModules$([IO.Path]::PathSeparator)".Length) }

        $folders = (Get-Content -LiteralPath $modulePathFile -Raw).Trim() -split [IO.Path]::PathSeparator
        $folders | Should -Not -Contain "$TestDrive\UserModules"
        $folders | Should -Not -Contain (Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'PowerShell\Modules')
        $folders | Should -Contain (Join-Path -Path ([Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'LazyVM\Modules')
    }

    It 'ends with Stopped, the error ID LazyVM.RunStopped and exit code 2 when the build is stopped' {
        $run = Invoke-AppBuild -Arguments '-Name', 'Stopped'

        $run.ExitCode | Should -Be 2
        $run.Result.Outcome | Should -Be 'Stopped'
        $run.Result.ErrorId | Should -Be 'LazyVM.RunStopped'
        $run.Result.Message | Should -BeLike '*stopped in phase 7*'
    }

    It 'ends with Failed, the reason and exit code 1 when the build fails' {
        $run = Invoke-AppBuild -Arguments '-Name', 'Failed'

        $run.ExitCode | Should -Be 1
        $run.Result.Outcome | Should -Be 'Failed'
        $run.Result.Message | Should -Be 'There is no Windows ISO.'
    }
}
