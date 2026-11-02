#Requires -Version 7.6
<#
.SYNOPSIS
Installs LazyVM from a release download.

.DESCRIPTION
Copies the LazyVM module beside this script to your own module folder,
Documents\PowerShell\Modules, where PowerShell 7 and LazyVM's scheduled
tasks (which run as you) find it. Only you can use it: LazyVM is installed
per user. An earlier copy of the same version is replaced; other versions
are left alone.

Files downloaded from the internet are marked as such, and PowerShell will
not load a marked module, so the copies are unblocked as they are installed.

Run it in PowerShell 7 (pwsh), signed in as the Windows user who will use
LazyVM. It does not need to run as administrator; LazyVM itself does.

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

# Only version folders, as a release download and the assembled module have
# them: in the repository, src\LazyVM holds the module's source instead (#90).
$versionDir = Get-ChildItem -LiteralPath (Join-Path -Path $Path -ChildPath $moduleName) -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -as [version] } |
    Sort-Object -Property { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $versionDir) {
    throw "There is no $moduleName module folder in $Path. Extract the whole download and run Install.ps1 from it, or, from the repository's root folder, run: ./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out"
}

$modulesDir = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'PowerShell\Modules'
$target = Join-Path -Path $modulesDir -ChildPath "$moduleName\$($versionDir.Name)"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File

Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue
# Before #284, LazyVM was installed for every user, in Program Files.
$machineWide = Join-Path -Path $env:ProgramFiles -ChildPath "PowerShell\Modules\$moduleName"
if (Test-Path -LiteralPath $machineWide) {
    Write-Warning "An earlier LazyVM is installed for every user in $machineWide. Open a new PowerShell 7 window as administrator and run Convert-LazyVMInstallation: it moves your VMs, passwords and tasks to your account and then removes that copy."
}
Write-Information 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox' -InformationAction Continue
