# CIReport.ps1 - Errors shown on GitHub Actions. Dot-sourced by the scripts at the repository root.

function Write-CIError {
    <# On GitHub Actions, an error shown on the run and the pull request, at the file and line when known. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$File,
        [int]$Line
    )
    if (-not $env:GITHUB_ACTIONS) {
        return
    }
    $location = if ($File) {
        " file=$([IO.Path]::GetRelativePath($env:GITHUB_WORKSPACE, $File)),line=$Line"
    }
    else {
        ''
    }
    $text = $Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::error$location::$text"
}

function Write-CIFailureSummary {
    <#
      On GitHub Actions, every failure in one notice. GitHub shows only the
      first 10 errors of a step, so a long list of failures would otherwise
      be cut off before the messages that explain them.
    #>
    param([AllowEmptyCollection()][string[]]$Failures = @())

    if (-not $env:GITHUB_ACTIONS -or $Failures.Count -eq 0) {
        return
    }
    $text = ($Failures -join "`n") -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::notice title=$($Failures.Count) failure(s)::$text"
}
