# CIReport.ps1 - Errors shown on GitHub Actions. Dot-sourced by the scripts at the repository root.

function Write-CIError
{
    <# On GitHub Actions, an error shown on the run and the pull request, at the file and line when known. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$File,
        [int]$Line
    )
    if (-not $env:GITHUB_ACTIONS)
    {
        return
    }
    $location = if ($File)
    {
        " file=$([IO.Path]::GetRelativePath($env:GITHUB_WORKSPACE, $File)),line=$Line"
    }
    else
    {
        ''
    }
    $text = $Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::error$location::$text"
}
