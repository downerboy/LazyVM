# Package.ps1 - Zips the built module for a GitHub release. Dot-sourced by the scripts at the repository root.

function New-ReleasePackage {
    <#
      Zips the built module, the app Publish-App published in out\App
      (#489), Install.ps1, the README, the logo the README shows and the
      licence into out\release\<ModuleName>-<version>.zip. Stops without the
      app, so no release ships without it.
    #>
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
    $app = Join-Path -Path $outDir -ChildPath 'App'
    if (-not (Test-Path -LiteralPath $app -PathType Container)) {
        throw "There is no published app in $app. Run Publish-App (build\Publish.ps1) first."
    }
    $releaseDir = Join-Path -Path $outDir -ChildPath 'release'
    $staging = Join-Path -Path $releaseDir -ChildPath 'staging'
    if (Test-Path -LiteralPath $releaseDir) {
        Remove-Item -LiteralPath $releaseDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Join-Path -Path $staging -ChildPath $ModuleName) -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path -Path $outDir -ChildPath "$ModuleName/$version") -Destination (Join-Path -Path $staging -ChildPath $ModuleName) -Recurse
    # Beside the module, where Install.ps1 looks for it.
    Copy-Item -LiteralPath $app -Destination (Join-Path -Path $staging -ChildPath 'App') -Recurse
    foreach ($file in 'src/Install.ps1', 'README.md', 'LICENSE.md') {
        Copy-Item -LiteralPath (Join-Path -Path $Root -ChildPath $file) -Destination $staging
    }
    # The README shows the logo from this path, so it goes in the zip at the same path.
    $logoFolder = Join-Path -Path $staging -ChildPath 'docs/images'
    New-Item -ItemType Directory -Path $logoFolder -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $Root -ChildPath 'docs/images/logo.svg') -Destination $logoFolder

    $zip = Join-Path -Path $releaseDir -ChildPath "$ModuleName-$releaseVersion.zip"
    Compress-Archive -Path (Join-Path -Path $staging -ChildPath '*') -DestinationPath $zip
    Remove-Item -LiteralPath $staging -Recurse -Force
    Write-Host "Packaged $zip"
}
