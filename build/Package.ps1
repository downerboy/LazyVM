# Package.ps1 - Zips the built module for a GitHub release. Dot-sourced by build.ps1.

function New-ReleasePackage
{
    <# Zips the built module with Install.ps1, the README and the licence into out\release\<ModuleName>-<version>.zip. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ModuleName
    )

    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $Root -ChildPath "src/$ModuleName/$ModuleName.psd1")
    $version = $manifest.ModuleVersion
    # The release's version as the tag names it: 2.0.0, or 2.0.0-alpha1 for a prerelease.
    $prerelease = "$($manifest.PrivateData.PSData['Prerelease'])"
    $releaseVersion = if ($prerelease) { "$version-$prerelease" } else { "$version" }

    $outDir = Join-Path -Path $Root -ChildPath 'out'
    $releaseDir = Join-Path -Path $outDir -ChildPath 'release'
    $staging = Join-Path -Path $releaseDir -ChildPath 'staging'
    if (Test-Path -LiteralPath $releaseDir)
    {
        Remove-Item -LiteralPath $releaseDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Join-Path -Path $staging -ChildPath $ModuleName) -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path -Path $outDir -ChildPath "$ModuleName/$version") -Destination (Join-Path -Path $staging -ChildPath $ModuleName) -Recurse
    foreach ($file in 'src/Install.ps1', 'README.md', 'LICENSE.md')
    {
        Copy-Item -LiteralPath (Join-Path -Path $Root -ChildPath $file) -Destination $staging
    }

    $zip = Join-Path -Path $releaseDir -ChildPath "$ModuleName-$releaseVersion.zip"
    Compress-Archive -Path (Join-Path -Path $staging -ChildPath '*') -DestinationPath $zip
    Remove-Item -LiteralPath $staging -Recurse -Force
    Write-Host "Packaged $zip"
}
