<#
.SYNOPSIS
Deletes a VM for the LazyVM app, in a pwsh process of its own.

.DESCRIPTION
The LazyVM app starts this script with pwsh -File and its arguments as a
list, never as script text, so closing the app cannot stop the delete part
way. It imports the LazyVM module from the folder this script is in, runs
Remove-LazyVM -Force, and writes how the delete ended to -ResultPath as JSON:
Outcome (Completed or Failed), ErrorId and Message. The app has already shown
what goes and asked, so -Force skips the question. A delete that removed only
part ends with Failed and the module's reason.

It ends with exit code 0 when the VM was deleted and 1 when it was not, or
only in part.

.PARAMETER Name
The VM to delete.

.PARAMETER ResultPath
The file the outcome is written to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ResultPath
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'AppProcess.ps1')
$work = {
    param($VMName)
    Remove-LazyVM -Name $VMName -Force
}
exit (Invoke-AppProcess -ResultPath $ResultPath -Work $work -ArgumentList $Name)
