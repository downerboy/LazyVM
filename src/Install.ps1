#Requires -Version 7.4
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs LazyVM from a release download.

.DESCRIPTION
Copies the LazyVM module beside this script to
$env:ProgramFiles\PowerShell\Modules, where PowerShell 7 and LazyVM's
scheduled tasks (which run as SYSTEM) find it. Any LazyVM versions already
installed there are removed first, so only this one is left.

Files downloaded from the internet are marked as such, and PowerShell will
not load a marked module, so the copies are unblocked as they are installed.

Run it in PowerShell 7 (pwsh), as administrator.

.PARAMETER Path
The folder that holds the LazyVM module folder. By default, this script's
own folder, as in a release download.

.EXAMPLE
.\Install.ps1

Installs from a release download.

.EXAMPLE
./src/Install.ps1 -Path out

Installs the module Invoke-AnalyzerAndTest.ps1 assembled from the repository.
#>
[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$moduleName = 'LazyVM'

$versionDir = Get-ChildItem -LiteralPath (Join-Path -Path $Path -ChildPath $moduleName) -Directory -ErrorAction SilentlyContinue |
    Sort-Object -Property { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $versionDir) {
    throw "There is no $moduleName module folder in $Path. Extract the whole download and run Install.ps1 from it, or, in the repository, run ./Invoke-AnalyzerAndTest.ps1 first."
}

$installDir = Join-Path -Path $env:ProgramFiles -ChildPath "PowerShell\Modules\$moduleName"
$target = Join-Path -Path $installDir -ChildPath $versionDir.Name
if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File

Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue
Write-Information 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox' -InformationAction Continue
