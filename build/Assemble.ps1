# Assemble.ps1 - Merges the module source into one .psm1. Dot-sourced by the scripts at the repository root.

function Invoke-Assemble {
    <# Builds src\<ModuleName> into out\<ModuleName>\<version>, then checks it exports exactly the public commands. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ModuleName
    )

    $sourceDir = Join-Path -Path $Root -ChildPath "src/$ModuleName"
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$ModuleName.psd1")
    $version = $manifest.ModuleVersion
    $target = Join-Path -Path $Root -ChildPath "out/$ModuleName/$version"

    # The manifest's command list and the Public folder must agree.
    $public = @(Get-ChildItem -LiteralPath (Join-Path -Path $sourceDir -ChildPath 'Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object)
    $listed = @($manifest.FunctionsToExport | Sort-Object)
    $difference = Compare-Object -ReferenceObject $public -DifferenceObject $listed
    if ($difference) {
        throw "FunctionsToExport and the Public folder differ: $(($difference | ForEach-Object { "$($_.InputObject) ($($_.SideIndicator))" }) -join ', ')"
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    # The source root module, with the loop that dot-sources the function
    # files replaced by the functions themselves.
    $rootModule = Get-Content -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$ModuleName.psm1") -Raw
    $start = $rootModule.IndexOf('# ── Functions')
    $end = $rootModule.IndexOf('# ── Tab completion')
    if ($start -lt 0 -or $end -lt 0) {
        throw "The markers that locate the function loader were not found in $ModuleName.psm1."
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append($rootModule.Substring(0, $start))
    [void]$builder.AppendLine("# ── Functions ────────────────────────────────────────────────────────────────")
    [void]$builder.AppendLine("# Merged from src\$ModuleName by Invoke-Assemble on $(Get-Date -Format 'yyyy-MM-dd').")
    foreach ($folder in 'Classes', 'Private', 'Public') {
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
    [IO.File]::WriteAllText((Join-Path -Path $target -ChildPath "$ModuleName.psm1"), $text, $utf8Bom)
    Copy-Item -LiteralPath (Join-Path -Path $sourceDir -ChildPath "$ModuleName.psd1") -Destination $target
    Copy-Item -LiteralPath (Join-Path -Path $sourceDir -ChildPath 'Data') -Destination $target -Recurse
    Copy-Item -LiteralPath (Join-Path -Path $Root -ChildPath 'LICENSE.md') -Destination $target

    # The built module must load and export exactly the public commands.
    $builtManifest = Join-Path -Path $target -ChildPath "$ModuleName.psd1"
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

    Write-Host "Built $ModuleName $version in $target ($($exported.Count) commands)"
}
