# Analyze.ps1 - Runs PSScriptAnalyzer. Dot-sourced by build.ps1.

function Invoke-Analyze
{
    <# Analyzes src\ and tests\ with their settings files; any finding fails. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][version]$Version
    )

    # In a process of its own: resolving the commands in the tests loads
    # Pester's assembly into whichever process the analyzer runs in, and
    # that would stop the tests loading Pester themselves.
    $job = Start-Job -ScriptBlock {
        param($Root, $Version)
        Import-Module -Name PSScriptAnalyzer -RequiredVersion $Version
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $Root -ChildPath 'src') -Recurse -Settings (Join-Path -Path $Root -ChildPath 'PSScriptAnalyzerSettings.psd1')
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $Root -ChildPath 'tests') -Recurse -Settings (Join-Path -Path $Root -ChildPath 'tests/PSScriptAnalyzerSettings.psd1')
    } -ArgumentList $Root, $Version
    $findings = @(Receive-Job -Job $job -Wait -AutoRemoveJob -ErrorAction Stop)

    foreach ($finding in $findings)
    {
        Write-Host "$($finding.ScriptName):$($finding.Line)  $($finding.RuleName)  $($finding.Message)"
        Write-CIError -Message "$($finding.RuleName): $($finding.Message)" -File $finding.ScriptPath -Line $finding.Line
    }
    if ($findings.Count -gt 0)
    {
        throw "PSScriptAnalyzer found $($findings.Count) problem(s)."
    }
    Write-Host 'PSScriptAnalyzer: no findings'
}
