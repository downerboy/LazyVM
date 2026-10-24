# Test.ps1 - Runs the Pester tests. Dot-sourced by the scripts at the repository root.

function Invoke-Test {
    <# Runs tests\ with Pester and writes out\testResults.xml; any failure fails. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][version]$PesterVersion
    )

    # Not -Force: Pester cannot be loaded twice into one session.
    if (-not (Get-Module -Name Pester | Where-Object { $_.Version -eq $PesterVersion })) {
        Import-Module -Name Pester -RequiredVersion $PesterVersion
    }

    $outDir = Join-Path -Path $Root -ChildPath 'out'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path -Path $Root -ChildPath 'tests'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = Join-Path -Path $outDir -ChildPath 'testResults.xml'

    $result = Invoke-Pester -Configuration $configuration
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($test in $result.Failed) {
        $message = "$($test.ExpandedPath): $($test.ErrorRecord[0].Exception.Message)"
        $failures.Add("$message ($([IO.Path]::GetFileName($test.ScriptBlock.File)):$($test.StartLine))")
        Write-CIError -Message $message -File $test.ScriptBlock.File -Line $test.StartLine
    }
    # A test file is also marked failed when only its tests failed; those are
    # reported above, so only a file that broke on its own is reported here.
    foreach ($container in @($result.Containers | Where-Object { $_.Result -eq 'Failed' -and @($_.ErrorRecord).Count -gt 0 })) {
        $failures.Add("$($container.Item): $(@($container.ErrorRecord)[0])")
        Write-CIError -Message "$($container.Item): $(@($container.ErrorRecord)[0])"
    }
    Write-CIFailureSummary -Failures $failures
    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
        throw "$($result.FailedCount) test(s) and $($result.FailedContainersCount) test file(s) failed."
    }
}
