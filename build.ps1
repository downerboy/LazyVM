#Requires -Version 7.4
<#
.SYNOPSIS
Builds, checks and tests the LazyVM module.

.DESCRIPTION
  Build    Merges src\LazyVM into one .psm1 under
           out\LazyVM\<version>, ready to publish or install,
           then imports the result to check it exports the public commands.
  Analyze  Runs PSScriptAnalyzer over the module and the tests. Any finding
           fails the build.
  Test     Runs the Pester tests and writes out\testResults.xml.
  All      All three, in that order (the default).
  Install  Build, Analyze and Test, then, only if they all pass, install
           the module for all users, where PowerShell and the scheduled
           tasks find it. Needs an elevated PowerShell.
  Package  Build, then zip the module with Install.ps1, the README and the
           licence into out\release, ready to attach to a GitHub release.

  Analyze and Test use pinned versions of PSScriptAnalyzer and Pester. When
  one is missing it is installed for the current user from the PowerShell
  Gallery, beside any other versions, which are left alone.

.PARAMETER Task
Which step to run.

.EXAMPLE
./build.ps1

.EXAMPLE
./build.ps1 -Task Test

.EXAMPLE
./build.ps1 -Task Install

Builds and checks LazyVM and installs it, ready to use: Build-LazyVM -Name DevBox.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Build', 'Analyze', 'Test', 'Install', 'Package')]
    [string]$Task = 'All'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$moduleName = 'LazyVM'
$sourceDir = Join-Path -Path $PSScriptRoot -ChildPath "src/$moduleName"
$outDir = Join-Path -Path $PSScriptRoot -ChildPath 'out'

foreach ($step in 'CIReport', 'Tools', 'Compile', 'Analyze', 'Test', 'Package')
{
    . (Join-Path -Path $PSScriptRoot -ChildPath "build/$step.ps1")
}

function Install-BuiltModule
{
    $version = (Import-PowerShellDataFile -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$moduleName.psd1")).ModuleVersion
    $built = Join-Path -Path $outDir -ChildPath "$moduleName/$version"
    $target = Join-Path -Path $env:ProgramFiles -ChildPath "PowerShell/Modules/$moduleName/$version"

    if (Test-Path -LiteralPath $target)
    {
        Remove-Item -LiteralPath $target -Recurse -Force 
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path -Path $built -ChildPath '*') -Destination $target -Recurse -Force

    Write-Host "Installed $moduleName $version in $target"
    Write-Host 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox'
}

try
{
    if ($Task -in 'All', 'Build', 'Install', 'Package')
    {
        Invoke-Compile -Root $PSScriptRoot -ModuleName $moduleName
    }
    # Install checks first, so a module that fails them is never installed.
    if ($Task -in 'All', 'Analyze', 'Install')
    {
        Invoke-Analyze -Root $PSScriptRoot -Version (Install-BuildTool -Name PSScriptAnalyzer)
    }
    if ($Task -in 'All', 'Test', 'Install')
    {
        Invoke-Test -Root $PSScriptRoot -PesterVersion (Install-BuildTool -Name Pester)
    }
    if ($Task -eq 'Install')
    {
        Install-BuiltModule
    }
    if ($Task -eq 'Package')
    {
        New-ReleasePackage -Root $PSScriptRoot -ModuleName $moduleName
    }
}
catch
{
    Write-CIError -Message "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    throw
}