<#
.SYNOPSIS
Runs one build of a VM for the LazyVM app, in a pwsh process of its own.

.DESCRIPTION
The LazyVM app starts this script with pwsh -File and its arguments as a
list, never as script text, so the build outlives the app's window. It
imports the LazyVM module from the folder this script is in, runs
Build-LazyVM and writes how the build ended to -ResultPath as JSON:
Outcome (Completed, Stopped or Failed), ErrorId and Message. The app
follows the build's progress through Get-LazyVMDashboard; the result file
says what happened when the build ended before it recorded a run, such as
when the Windows ISO is missing.

It ends with exit code 0 when the build ran to the end, 2 when
Stop-LazyVMBuild stopped it (the error LazyVM.RunStopped), and 1 when it
failed.

.PARAMETER Name
The VM to build.

.PARAMETER ConfigTemplate
The config template a new VM's profile is created from.

.PARAMETER UserName
The administrator account the build creates inside a new VM.

.PARAMETER ResultPath
The file the outcome is written to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$ConfigTemplate,
    [string]$UserName,
    [Parameter(Mandatory)][string]$ResultPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$result = [ordered]@{ Outcome = 'Failed'; ErrorId = $null; Message = $null }
$exitCode = 1
try {
    # The build runs elevated, so a module the user could change, such as
    # one in Documents\PowerShell\Modules, must never load into it: only
    # folders administrators control, as in the app itself.
    $env:PSModulePath = @(
        Join-Path -Path ([Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'LazyVM\Modules'
        Join-Path -Path ([Environment]::GetFolderPath('Windows')) -ChildPath 'System32\WindowsPowerShell\v1.0\Modules'
        Join-Path -Path $PSHOME -ChildPath 'Modules'
    ) -join [IO.Path]::PathSeparator
    # By full path, from the folder this script ships in, never through PSModulePath.
    Import-Module -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'LazyVM.psd1') -Force
    $build = @{ Name = $Name }
    if ($ConfigTemplate) { $build.ConfigTemplate = $ConfigTemplate }
    if ($UserName) { $build.UserName = $UserName }
    Build-LazyVM @build
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
exit $exitCode
