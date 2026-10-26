# Tools.ps1 - The build tools, pinned so the build behaves the same everywhere
# until these are changed on purpose. Dot-sourced by the scripts at the repository root.

$PinnedTools = @{
    Pester           = '5.7.1'
    PSScriptAnalyzer = '1.24.0'
}

function Install-BuildTool {
    <# Installs the pinned version of a tool if it is missing, beside any others, and returns that version. #>
    param([Parameter(Mandatory)][string]$Name)

    $version = [version]$PinnedTools[$Name]
    if (-not (Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq $version })) {
        Write-Host "Installing $Name $version..."
        # The PowerShell Gallery sometimes does not answer, and Install-Module
        # then says it found no such module, so try again before failing.
        $retryDelays = 10, 30
        for ($attempt = 1; ; $attempt++) {
            try {
                Install-Module -Name $Name -RequiredVersion $version -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -gt $retryDelays.Count) {
                    throw "Could not install $Name $version from the PowerShell Gallery after $attempt attempts: $($_.Exception.Message)"
                }
                $delay = $retryDelays[$attempt - 1]
                Write-Warning "Installing $Name $version failed on attempt $attempt of $($retryDelays.Count + 1): $($_.Exception.Message) Trying again in $delay seconds."
                Start-Sleep -Seconds $delay
            }
        }
    }
    return $version
}
