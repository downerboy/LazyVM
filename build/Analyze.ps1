# Analyze.ps1 - Runs PSScriptAnalyzer. Dot-sourced by the scripts at the repository root.

function Invoke-Analyze {
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
        # Not the .NET build output: the PowerShell SDK the window hosts copies
        # its own modules into bin, and those are not ours to analyze.
        $settings = Join-Path -Path $Root -ChildPath 'PSScriptAnalyzerSettings.psd1'
        Get-ChildItem -Path (Join-Path -Path $Root -ChildPath 'src') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
            ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings }
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $Root -ChildPath 'tests') -Recurse -Settings (Join-Path -Path $Root -ChildPath 'tests/PSScriptAnalyzerSettings.psd1')
    } -ArgumentList $Root, $Version
    $findings = @(Receive-Job -Job $job -Wait -AutoRemoveJob -ErrorAction Stop)

    foreach ($finding in $findings) {
        Write-Host "$($finding.ScriptName):$($finding.Line)  $($finding.RuleName)  $($finding.Message)"
        Write-CIError -Message "$($finding.RuleName): $($finding.Message)" -File $finding.ScriptPath -Line $finding.Line
    }
    if ($findings.Count -gt 0) {
        throw "PSScriptAnalyzer found $($findings.Count) problem(s)."
    }
    Write-Host 'PSScriptAnalyzer: no findings'
}
