<#
.SYNOPSIS
What every script the LazyVM app starts in a pwsh process of its own shares.

.DESCRIPTION
Start-AppBuild.ps1, Start-AppRemove.ps1 and Start-AppRestore.ps1 dot-source
this file and call Invoke-AppProcess with the work to do. The app starts each
with pwsh -File and its arguments as a list, never as script text, so the run
outlives the app's window.
#>

function Invoke-AppProcess {
    <#
    .SYNOPSIS
    Runs -Work with the LazyVM module loaded, and writes how it ended to -ResultPath as JSON.

    .DESCRIPTION
    Limits PSModulePath to folders administrators control, imports the LazyVM
    module from the folder the calling script ships in, and runs -Work. The
    result is Outcome (Completed, Stopped or Failed), ErrorId and Message,
    written even when the work fails, so the app can say why. Returns the
    exit code the script ends with: 0 when the work ran to the end, 2 when
    Stop-LazyVMBuild stopped it (the error LazyVM.RunStopped), and 1 when it
    failed.

    .PARAMETER Work
    The work, a script block run with the module loaded.

    .PARAMETER ArgumentList
    What -Work takes as its parameters, in order. Values reach the work only
    this way, never in its text.

    .PARAMETER ResultPath
    The file the outcome is written to.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [object[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$ResultPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = [ordered]@{ Outcome = 'Failed'; ErrorId = $null; Message = $null }
    $exitCode = 1
    try {
        # The run is elevated, so a module the user could change, such as
        # one in Documents\PowerShell\Modules, must never load into it: only
        # folders administrators control, as in the app itself.
        $env:PSModulePath = @(
            Join-Path -Path ([Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'LazyVM\Modules'
            Join-Path -Path ([Environment]::GetFolderPath('Windows')) -ChildPath 'System32\WindowsPowerShell\v1.0\Modules'
            Join-Path -Path $PSHOME -ChildPath 'Modules'
        ) -join [IO.Path]::PathSeparator
        # By full path, from the folder the script ships in, never through PSModulePath.
        Import-Module -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'LazyVM.psd1') -Force
        & $Work @ArgumentList
        $result.Outcome = 'Completed'
        $exitCode = 0
    }
    catch {
        $result.ErrorId = ($_.FullyQualifiedErrorId -split ',')[0]
        $result.Message = $_.Exception.Message
        if ($result.ErrorId -eq 'LazyVM.RunStopped') {
            $result.Outcome = 'Stopped'
            $exitCode = 2
        }
    }
    finally {
        [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    }
    $exitCode
}
