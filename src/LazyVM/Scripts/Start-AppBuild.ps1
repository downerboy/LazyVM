<#
.SYNOPSIS
Runs one build of a VM for the LazyVM app, in a pwsh process of its own.

.DESCRIPTION
The LazyVM app starts this script with pwsh -File and its arguments as a
list, never as script text, so the build outlives the app's window. It
imports the LazyVM module from the folder this script is in, runs
Build-LazyVM, from -FromPhase when it is given, and writes how the build
ended to -ResultPath as JSON: Outcome (Completed, Stopped or Failed),
ErrorId and Message. The app
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

.PARAMETER FromPhase
The phase to start at, such as the one a failed or stopped build was in.
Left out, the build starts at the beginning, or where a build waiting for a
restart left off.

.PARAMETER ResultPath
The file the outcome is written to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$ConfigTemplate,
    [string]$UserName,
    [int]$FromPhase,
    [Parameter(Mandatory)][string]$ResultPath
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'AppProcess.ps1')
$build = @{ Name = $Name }
if ($ConfigTemplate) { $build.ConfigTemplate = $ConfigTemplate }
if ($UserName) { $build.UserName = $UserName }
if ($PSBoundParameters.ContainsKey('FromPhase')) { $build.FromPhase = $FromPhase }
$work = {
    param($Parameters)
    Build-LazyVM @Parameters
}
exit (Invoke-AppProcess -ResultPath $ResultPath -Work $work -ArgumentList $build)
