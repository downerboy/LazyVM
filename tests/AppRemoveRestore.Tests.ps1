# AppRemoveRestore.Tests.ps1
# Scripts\Start-AppRemove.ps1 and Scripts\Start-AppRestore.ps1, the scripts
# the LazyVM app runs each delete and each restore with, in a pwsh process of
# its own so closing the app cannot stop one part way (#524). They run here
# with pwsh -File, as the app runs them, next to a stand-in LazyVM module
# whose Remove-LazyVM and Restore-LazyVMTooling record what they were given,
# so nothing is deleted or restored.

BeforeAll {
    $sourceDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\LazyVM\Scripts'
    $pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'

    $moduleDir = Join-Path -Path $TestDrive -ChildPath 'LazyVM'
    $null = New-Item -ItemType Directory -Path (Join-Path -Path $moduleDir -ChildPath 'Scripts')
    Copy-Item -Path (Join-Path -Path $sourceDir -ChildPath '*.ps1') -Destination (Join-Path -Path $moduleDir -ChildPath 'Scripts')
    $scriptDir = Join-Path -Path $moduleDir -ChildPath 'Scripts'
    $calls = Join-Path -Path $TestDrive -ChildPath 'calls.json'
    $modulePathFile = Join-Path -Path $TestDrive -ChildPath 'module-path.txt'
    Set-Content -LiteralPath (Join-Path -Path $moduleDir -ChildPath 'LazyVM.psm1') -Value @"
function Remove-LazyVM {
    [CmdletBinding()]
    param([string]`$Name, [switch]`$Force)
    `$PSBoundParameters | ConvertTo-Json -Compress | Set-Content -LiteralPath '$calls'
    Set-Content -LiteralPath '$modulePathFile' -Value `$env:PSModulePath
    if (`$Name -eq 'Partly') { throw "'Partly' was only partly removed." }
}
function Restore-LazyVMTooling {
    [CmdletBinding()]
    param([string]`$Name, [string]`$RestorePoint, [switch]`$Force)
    `$PSBoundParameters | ConvertTo-Json -Compress | Set-Content -LiteralPath '$calls'
    Set-Content -LiteralPath '$modulePathFile' -Value `$env:PSModulePath
    if (`$Name -eq 'Busy') { throw 'A build of Busy is running, so it was not restored.' }
}
"@
    New-ModuleManifest -Path (Join-Path -Path $moduleDir -ChildPath 'LazyVM.psd1') -RootModule 'LazyVM.psm1' -FunctionsToExport 'Remove-LazyVM', 'Restore-LazyVMTooling'

    function Invoke-AppScript {
        param([string]$ScriptName, [string[]]$Arguments)
        $resultPath = Join-Path -Path $TestDrive -ChildPath "result-$([guid]::NewGuid()).json"
        & $pwsh -NoProfile -NonInteractive -File (Join-Path -Path $scriptDir -ChildPath $ScriptName) @Arguments -ResultPath $resultPath | Out-Null
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Result   = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            Call     = Get-Content -LiteralPath $calls -Raw | ConvertFrom-Json -AsHashtable
        }
    }
}

Describe 'Start-AppRemove.ps1' {
    BeforeEach { Remove-Item -LiteralPath $calls -ErrorAction SilentlyContinue }

    It 'deletes the VM without asking again, and ends with Completed and exit code 0' {
        $run = Invoke-AppScript -ScriptName 'Start-AppRemove.ps1' -Arguments '-Name', 'DevBox'

        $run.ExitCode | Should -Be 0
        $run.Result.Outcome | Should -Be 'Completed'
        $run.Call.Name | Should -Be 'DevBox'
        $run.Call.Force | Should -BeTrue
    }

    It 'passes a name with quotes and spaces as it is, never as script text' {
        $run = Invoke-AppScript -ScriptName 'Start-AppRemove.ps1' -Arguments '-Name', "Dev 'Box'; calc"

        $run.Call.Name | Should -Be "Dev 'Box'; calc"
    }

    It 'loads modules only from folders administrators control, never from the user''s own' {
        $env:PSModulePath = "$TestDrive\UserModules$([IO.Path]::PathSeparator)$env:PSModulePath"
        try { $null = Invoke-AppScript -ScriptName 'Start-AppRemove.ps1' -Arguments '-Name', 'DevBox' }
        finally { $env:PSModulePath = $env:PSModulePath.Substring("$TestDrive\UserModules$([IO.Path]::PathSeparator)".Length) }

        $folders = (Get-Content -LiteralPath $modulePathFile -Raw).Trim() -split [IO.Path]::PathSeparator
        $folders | Should -Not -Contain "$TestDrive\UserModules"
        $folders | Should -Contain (Join-Path -Path ([Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'LazyVM\Modules')
    }

    It 'ends with Failed, the reason and exit code 1 when only part was deleted' {
        $run = Invoke-AppScript -ScriptName 'Start-AppRemove.ps1' -Arguments '-Name', 'Partly'

        $run.ExitCode | Should -Be 1
        $run.Result.Outcome | Should -Be 'Failed'
        $run.Result.Message | Should -Be "'Partly' was only partly removed."
    }
}

Describe 'Start-AppRestore.ps1' {
    BeforeEach { Remove-Item -LiteralPath $calls -ErrorAction SilentlyContinue }

    It 'restores the VM to the restore point without asking again, and ends with Completed and exit code 0' {
        $run = Invoke-AppScript -ScriptName 'Start-AppRestore.ps1' -Arguments '-Name', 'DevBox', '-RestorePoint', '20261008-193000'

        $run.ExitCode | Should -Be 0
        $run.Result.Outcome | Should -Be 'Completed'
        $run.Call.Name | Should -Be 'DevBox'
        $run.Call.RestorePoint | Should -Be '20261008-193000'
        $run.Call.Force | Should -BeTrue
    }

    It 'loads modules only from folders administrators control, never from the user''s own' {
        $env:PSModulePath = "$TestDrive\UserModules$([IO.Path]::PathSeparator)$env:PSModulePath"
        try { $null = Invoke-AppScript -ScriptName 'Start-AppRestore.ps1' -Arguments '-Name', 'DevBox', '-RestorePoint', '1' }
        finally { $env:PSModulePath = $env:PSModulePath.Substring("$TestDrive\UserModules$([IO.Path]::PathSeparator)".Length) }

        (Get-Content -LiteralPath $modulePathFile -Raw).Trim() -split [IO.Path]::PathSeparator | Should -Not -Contain "$TestDrive\UserModules"
    }

    It 'ends with Failed, the reason and exit code 1 when the restore is refused' {
        $run = Invoke-AppScript -ScriptName 'Start-AppRestore.ps1' -Arguments '-Name', 'Busy', '-RestorePoint', '1'

        $run.ExitCode | Should -Be 1
        $run.Result.Outcome | Should -Be 'Failed'
        $run.Result.Message | Should -Be 'A build of Busy is running, so it was not restored.'
    }
}
