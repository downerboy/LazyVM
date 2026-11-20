#Requires -Version 7.6
<#
.SYNOPSIS
Makes the release zip: out\release\LazyVM-<version>.zip.

.DESCRIPTION
Assembles src\LazyVM into out\LazyVM\<version>, publishes the app
self-contained for win-x64 into out\App, then zips both with Install.ps1, its launchers (Install LazyVM.cmd and
Uninstall LazyVM.cmd),
the README and the licence, ready to attach to a GitHub release. It needs
the .NET 10 SDK. The release workflow runs it after Invoke-AnalyzerAndTest.ps1
passes; it does not analyze or test by itself.

.EXAMPLE
./New-ReleasePackage.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

foreach ($step in 'CIReport', 'Assemble', 'Publish', 'Package') {
    . (Join-Path -Path $PSScriptRoot -ChildPath "build/$step.ps1")
}

try {
    Invoke-Assemble -Root $PSScriptRoot -ModuleName 'LazyVM'
    Publish-App -Root $PSScriptRoot
    New-ReleasePackage -Root $PSScriptRoot -ModuleName 'LazyVM'
}
catch {
    Write-CIError -Message "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    throw
}
