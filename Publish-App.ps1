#Requires -Version 7.6
<#
.SYNOPSIS
Publishes the LazyVM app into out\App, for Install.ps1 to install.

.DESCRIPTION
Publishes src\LazyVM.UI.Wpf self-contained for win-x64, in Release, into
out\App, and checks PowerShell's built-in modules are beside it. Then
./src/Install.ps1 -Path out installs the app with the module, as
Install-FromRepository.cmd does. It needs the .NET 10 SDK.
New-ReleasePackage.ps1 does the same for the release zip.

.EXAMPLE
./Invoke-AnalyzerAndTest.ps1 && ./Publish-App.ps1 && ./src/Install.ps1 -Path out
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'build/Publish.ps1')
Publish-App -Root $PSScriptRoot
