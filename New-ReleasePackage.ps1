#Requires -Version 7.4
<#
.SYNOPSIS
Makes the release zip: out\release\LazyVM-<version>.zip.

.DESCRIPTION
Assembles src\LazyVM into out\LazyVM\<version>, then zips it with
Install.ps1, the README and the licence, ready to attach to a GitHub
release. The release workflow runs it after Invoke-AnalyzerAndTest.ps1
passes; it does not analyze or test by itself.

.EXAMPLE
./New-ReleasePackage.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

foreach ($step in 'CIReport', 'Assemble', 'Package')
{
    . (Join-Path -Path $PSScriptRoot -ChildPath "build/$step.ps1")
}

try
{
    Invoke-Assemble -Root $PSScriptRoot -ModuleName 'LazyVM'
    New-ReleasePackage -Root $PSScriptRoot -ModuleName 'LazyVM'
}
catch
{
    Write-CIError -Message "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    throw
}
