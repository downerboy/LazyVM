# Publish.ps1 - Publishes the LazyVM app for the release zip. Dot-sourced by the scripts at the repository root.

function Publish-App {
    <#
      Publishes src\LazyVM.UI.Wpf to out\App: Release, self-contained for
      win-x64, so the host needs no .NET installed and every DLL the app
      loads comes from its own folder (docs\Dashboard.md, section 5, rule 1).
      Not as a single file, which leaves PowerShell's assembly with no
      location, so it finds none of its built-in modules; and not trimmed,
      since PowerShell finds much of what it runs by reflection.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $project = Join-Path -Path $Root -ChildPath 'src/LazyVM.UI.Wpf/LazyVM.UI.Wpf.csproj'
    $output = Join-Path -Path $Root -ChildPath 'out/App'
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
    & dotnet publish $project --configuration Release --runtime win-x64 --self-contained true --output $output -p:PublishSingleFile=false -p:PublishTrimmed=false --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish of the app failed with exit code $LASTEXITCODE."
    }
    Assert-PublishedApp -Path $output
    Write-Host "Published the app in $output"
}

function Assert-PublishedApp {
    <#
      Stops unless $Path holds the app's exe, PowerShell's own assembly
      beside it, and PowerShell's built-in modules in Modules there, where
      PowerShell looks for them: without them the app runs no command.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $parts = 'LazyVM.UI.Wpf.exe', 'System.Management.Automation.dll', 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1'
    $missing = @($parts | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath $_) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        throw "The published app in $Path is missing $($missing -join ', ')."
    }
}
