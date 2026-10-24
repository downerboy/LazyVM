#Requires -Version 7.4
<#
.SYNOPSIS
Checks a change to LazyVM: assembles the module, analyzes the code and runs the tests.

.DESCRIPTION
Run it after changing code, before pushing; CI runs the same on every pull
request. It stops at the first failure.

  1. Assembles src\LazyVM into out\LazyVM\<version> and checks the result
     exports exactly the public commands.
  2. Runs PSScriptAnalyzer over src\ and tests\. Any finding fails.
  3. Runs the Pester tests and writes out\testResults.xml. Any failure fails.

The first time, it installs the pinned versions of PSScriptAnalyzer and
Pester it uses, for the current user, beside any other versions.

.PARAMETER AnalyzerOnly
Only run PSScriptAnalyzer.

.PARAMETER TestOnly
Only run the Pester tests.

.EXAMPLE
./Invoke-AnalyzerAndTest.ps1

.EXAMPLE
./Invoke-AnalyzerAndTest.ps1 -TestOnly
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(ParameterSetName = 'AnalyzerOnly')][switch]$AnalyzerOnly,
    [Parameter(ParameterSetName = 'TestOnly')][switch]$TestOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

foreach ($step in 'CIReport', 'Tools', 'Assemble', 'Analyze', 'Test')
{
    . (Join-Path -Path $PSScriptRoot -ChildPath "build/$step.ps1")
}

try
{
    if ($PSCmdlet.ParameterSetName -eq 'All')
    {
        Invoke-Assemble -Root $PSScriptRoot -ModuleName 'LazyVM'
    }
    if (-not $TestOnly)
    {
        Invoke-Analyze -Root $PSScriptRoot -Version (Install-BuildTool -Name PSScriptAnalyzer)
    }
    if (-not $AnalyzerOnly)
    {
        Invoke-Test -Root $PSScriptRoot -PesterVersion (Install-BuildTool -Name Pester)
    }
}
catch
{
    Write-CIError -Message "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    throw
}
