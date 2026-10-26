#Requires -Version 7.6
<#
.SYNOPSIS
Claude Code PostToolUse hook: analyzes the PowerShell file Claude just wrote or edited.

.DESCRIPTION
Reads the hook's JSON from standard input. When the file is a .ps1, .psm1 or
.psd1 under src\ or tests\, runs the pinned PSScriptAnalyzer over it with the
same settings Invoke-AnalyzerAndTest.ps1 uses there. Any finding is written to
standard error with exit code 2, which Claude Code hands back to Claude to fix.

Anything else, or a PSScriptAnalyzer that is not installed yet, is let through
silently: Invoke-AnalyzerAndTest.ps1 installs it and remains the real check.
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
$path = $hookInput.tool_input.file_path
if (-not $path -or [IO.Path]::GetExtension($path) -notin '.ps1', '.psm1', '.psd1' -or -not (Test-Path -LiteralPath $path)) {
    exit 0
}

$relative = [IO.Path]::GetRelativePath($root, $path) -replace '\\', '/'
$settings = switch -Wildcard ($relative) {
    'src/*' { Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1' }
    'tests/*' { Join-Path -Path $root -ChildPath 'tests/PSScriptAnalyzerSettings.psd1' }
    default { exit 0 }
}

. (Join-Path -Path $root -ChildPath 'build/Tools.ps1')
$version = [version]$PinnedTools['PSScriptAnalyzer']
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq $version })) {
    exit 0
}
Import-Module -Name PSScriptAnalyzer -RequiredVersion $version

$findings = @(Invoke-ScriptAnalyzer -Path $path -Settings $settings)
if ($findings.Count -eq 0) {
    exit 0
}
foreach ($finding in $findings) {
    [Console]::Error.WriteLine("${relative}:$($finding.Line)  $($finding.RuleName)  $($finding.Message)")
}
exit 2
