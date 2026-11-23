<#
.SYNOPSIS
Returns a VM to a restore point for the LazyVM app, in a pwsh process of its own.

.DESCRIPTION
The LazyVM app starts this script with pwsh -File and its arguments as a
list, never as script text, so closing the app cannot stop the restore part
way. It imports the LazyVM module from the folder this script is in, runs
Restore-LazyVMTooling -Force, and writes how the restore ended to
-ResultPath as JSON: Outcome (Completed or Failed), ErrorId and Message. The
app has already asked, so -Force skips the question.

It ends with exit code 0 when the VM was restored and 1 when it was not.

.PARAMETER Name
The VM to restore.

.PARAMETER RestorePoint
The restore point to return it to, such as 20261008-193000.

.PARAMETER ResultPath
The file the outcome is written to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$RestorePoint,
    [Parameter(Mandatory)][string]$ResultPath
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'AppProcess.ps1')
$work = {
    param($VMName, $Stamp)
    Restore-LazyVMTooling -Name $VMName -RestorePoint $Stamp -Force
}
exit (Invoke-AppProcess -ResultPath $ResultPath -Work $work -ArgumentList $Name, $RestorePoint)
