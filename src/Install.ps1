#Requires -Version 7.4
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs LazyVM from a release download.

.DESCRIPTION
Copies the Massokissed.LazyVM module beside this script to
$env:ProgramFiles\PowerShell\Modules, where PowerShell 7 and LazyVM's
scheduled tasks (which run as SYSTEM) find it. An earlier copy of the same
version is replaced; other versions are left alone.

Files downloaded from the internet are marked as such, and PowerShell will
not load a marked module, so the copies are unblocked as they are installed.

Run it in PowerShell 7 (pwsh), as administrator.

.EXAMPLE
.\Install.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$moduleName = 'Massokissed.LazyVM'

$versionDir = Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath $moduleName) -Directory |
    Sort-Object -Property { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $versionDir) {
    throw "The $moduleName folder is not beside this script. Extract the whole download, then run Install.ps1 from it."
}

$target = Join-Path -Path $env:ProgramFiles -ChildPath "PowerShell\Modules\$moduleName\$($versionDir.Name)"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File

Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue
Write-Information 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox' -InformationAction Continue
