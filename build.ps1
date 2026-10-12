#Requires -Version 7.4
<#
.SYNOPSIS
Builds, checks and tests the Massokissed.LazyVM module.

.DESCRIPTION
  Build    Merges src\Massokissed.LazyVM into one .psm1 under
           out\Massokissed.LazyVM\<version>, ready to publish or install,
           then imports the result to check it exports the public commands.
  Analyze  Runs PSScriptAnalyzer over the module and the tests. Any finding
           fails the build.
  Test     Runs the Pester tests and writes out\testResults.xml.
  All      All three, in that order (the default).

.PARAMETER Task
Which step to run.

.PARAMETER Bootstrap
Install the versions of Pester and PSScriptAnalyzer the build uses, for
the current user, if they are missing.

.EXAMPLE
./build.ps1

.EXAMPLE
./build.ps1 -Task Test

.EXAMPLE
./build.ps1 -Bootstrap
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Build', 'Analyze', 'Test')]
    [string]$Task = 'All',

    [switch]$Bootstrap
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$moduleName = 'Massokissed.LazyVM'
$sourceDir = Join-Path -Path $PSScriptRoot -ChildPath "src/$moduleName"
$outDir = Join-Path -Path $PSScriptRoot -ChildPath 'out'

# Pinned, so the build behaves the same everywhere until these are changed on purpose.
$tools = @(
    @{ Name = 'Pester'; Version = '5.7.1' }
    @{ Name = 'PSScriptAnalyzer'; Version = '1.24.0' }
)

function Import-BuildTool {
    param([Parameter(Mandatory)][hashtable]$Tool)

    $installed = Get-Module -ListAvailable -Name $Tool.Name | Where-Object { $_.Version -eq [version]$Tool.Version }
    if (-not $installed) {
        if (-not $Bootstrap) {
            throw "$($Tool.Name) $($Tool.Version) is not installed. Run ./build.ps1 -Bootstrap to install it."
        }
        Write-Host "Installing $($Tool.Name) $($Tool.Version)..."
        Install-Module -Name $Tool.Name -RequiredVersion $Tool.Version -Scope CurrentUser -Force -SkipPublisherCheck
    }
    Import-Module -Name $Tool.Name -RequiredVersion $Tool.Version -Force
}

function Invoke-Build {
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$moduleName.psd1")
    $version = $manifest.ModuleVersion
    $target = Join-Path -Path $outDir -ChildPath "$moduleName/$version"

    # The manifest's command list and the Public folder must agree.
    $public = @(Get-ChildItem -LiteralPath (Join-Path -Path $sourceDir -ChildPath 'Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object)
    $listed = @($manifest.FunctionsToExport | Sort-Object)
    $difference = Compare-Object -ReferenceObject $public -DifferenceObject $listed
    if ($difference) {
        throw "FunctionsToExport and the Public folder differ: $(($difference | ForEach-Object { "$($_.InputObject) ($($_.SideIndicator))" }) -join ', ')"
    }

    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    # The source root module, with the loop that dot-sources the function
    # files replaced by the functions themselves.
    $rootModule = Get-Content -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$moduleName.psm1") -Raw
    $start = $rootModule.IndexOf('# ── Functions')
    $end = $rootModule.IndexOf('# ── Tab completion')
    if ($start -lt 0 -or $end -lt 0) { throw "The markers that locate the function loader were not found in $moduleName.psm1." }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append($rootModule.Substring(0, $start))
    [void]$builder.AppendLine("# ── Functions ────────────────────────────────────────────────────────────────")
    [void]$builder.AppendLine("# Merged from src\$moduleName by build.ps1 on $(Get-Date -Format 'yyyy-MM-dd').")
    foreach ($folder in 'Private', 'Public') {
        $files = Get-ChildItem -LiteralPath (Join-Path -Path $sourceDir -ChildPath $folder) -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($sourceDir, $file.FullName)
            [void]$builder.AppendLine()
            [void]$builder.AppendLine("#region $relative")
            [void]$builder.AppendLine((Get-Content -LiteralPath $file.FullName -Raw).TrimEnd())
            [void]$builder.AppendLine("#endregion $relative")
        }
    }
    [void]$builder.AppendLine()
    [void]$builder.Append($rootModule.Substring($end))

    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $text = $builder.ToString() -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path -Path $target -ChildPath "$moduleName.psm1"), $text, $utf8Bom)
    Copy-Item -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$moduleName.psd1") -Destination $target
    Copy-Item -LiteralPath (Join-Path -Path $sourceDir -ChildPath 'Data') -Destination $target -Recurse
    Copy-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'LICENSE.md') -Destination $target

    # The built module must load and export exactly the public commands.
    $builtManifest = Join-Path -Path $target -ChildPath "$moduleName.psd1"
    $null = Test-ModuleManifest -Path $builtManifest
    $check = Start-Job -ScriptBlock {
        param($Path)
        $module = Import-Module -Name $Path -PassThru -Force
        @(Get-Command -Module $module.Name | ForEach-Object { $_.Name } | Sort-Object)
    } -ArgumentList $builtManifest
    $exported = @(Receive-Job -Job $check -Wait -AutoRemoveJob -ErrorAction Stop)
    if (Compare-Object -ReferenceObject $public -DifferenceObject $exported) {
        throw "The built module exports $($exported -join ', ') instead of $($public -join ', ')."
    }

    Write-Host "Built $moduleName $version in $target ($($exported.Count) commands)"
}

function Invoke-Analyze {
    $findings = @(
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $PSScriptRoot -ChildPath 'src') -Recurse -Settings (Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1')
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $PSScriptRoot -ChildPath 'tests') -Recurse -Settings (Join-Path -Path $PSScriptRoot -ChildPath 'tests/PSScriptAnalyzerSettings.psd1')
    )
    foreach ($finding in $findings) {
        Write-Host "$($finding.ScriptName):$($finding.Line)  $($finding.RuleName)  $($finding.Message)"
        Write-CIError -Message "$($finding.RuleName): $($finding.Message)" -File $finding.ScriptPath -Line $finding.Line
    }
    if ($findings.Count -gt 0) { throw "PSScriptAnalyzer found $($findings.Count) problem(s)." }
    Write-Host 'PSScriptAnalyzer: no findings'
}

function Invoke-Test {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path -Path $PSScriptRoot -ChildPath 'tests'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = Join-Path -Path $outDir -ChildPath 'testResults.xml'

    $result = Invoke-Pester -Configuration $configuration
    foreach ($test in $result.Failed) {
        Write-CIError -Message "$($test.ExpandedPath): $($test.ErrorRecord[0].Exception.Message)" -File $test.ScriptBlock.File -Line $test.StartLine
    }
    foreach ($container in @($result.Containers | Where-Object Result -eq 'Failed')) {
        Write-CIError -Message "$($container.Item): $(@($container.ErrorRecord)[0])"
    }
    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
        throw "$($result.FailedCount) test(s) and $($result.FailedContainersCount) test file(s) failed."
    }
}

function Write-CIError {
    <# On GitHub Actions, an error shown on the run and the pull request, at the file and line when known. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$File,
        [int]$Line
    )
    if (-not $env:GITHUB_ACTIONS) { return }
    $location = if ($File) { " file=$([IO.Path]::GetRelativePath($PSScriptRoot, $File)),line=$Line" } else { '' }
    $text = $Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::error$location::$text"
}

try {
    if ($Task -in 'All', 'Build') { Invoke-Build }
    if ($Task -in 'All', 'Analyze') {
        Import-BuildTool -Tool ($tools | Where-Object Name -eq 'PSScriptAnalyzer')
        Invoke-Analyze
    }
    if ($Task -in 'All', 'Test') {
        Import-BuildTool -Tool ($tools | Where-Object Name -eq 'Pester')
        Invoke-Test
    }
}
catch {
    Write-CIError -Message "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    throw
}
