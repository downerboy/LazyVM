# Tools.ps1 - The build tools, pinned so the build behaves the same everywhere
# until these are changed on purpose. Dot-sourced by build.ps1.

$PinnedTools = @{
    Pester           = '5.7.1'
    PSScriptAnalyzer = '1.24.0'
}

function Install-BuildTool
{
    <# Installs the pinned version of a tool if it is missing, beside any others, and returns that version. #>
    param([Parameter(Mandatory)][string]$Name)

    $version = [version]$PinnedTools[$Name]
    if (-not (Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq $version }))
    {
        Write-Host "Installing $Name $version..."
        Install-Module -Name $Name -RequiredVersion $version -Scope CurrentUser -Force -SkipPublisherCheck
    }
    return $version
}
