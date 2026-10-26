# BuildTools.Tests.ps1
# Installing the pinned build tools from the PowerShell Gallery, which
# sometimes does not answer. Nothing here installs anything: Install-Module,
# the module lookup and the waits are mocked.

BeforeAll {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'build/Tools.ps1')
}

Describe 'Install-BuildTool' {
    BeforeEach {
        Mock Get-Module { } -ParameterFilter { $ListAvailable -and $Name -in $PinnedTools.Keys }
        Mock Start-Sleep { }
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'returns the pinned version without installing when it is already there' {
        Mock Get-Module { [pscustomobject]@{ Name = 'Pester'; Version = [version]$PinnedTools['Pester'] } } -ParameterFilter { $ListAvailable -and $Name -in $PinnedTools.Keys }
        Mock Install-Module { }

        Install-BuildTool -Name Pester | Should -Be ([version]$PinnedTools['Pester'])

        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'tries again after the Gallery does not answer, and installs the pinned version' {
        $script:installAttempts = 0
        Mock Install-Module {
            $script:installAttempts++
            if ($script:installAttempts -lt 3) {
                throw "No match was found for the specified search criteria and module name 'PSScriptAnalyzer'."
            }
        }

        Install-BuildTool -Name PSScriptAnalyzer | Should -Be ([version]$PinnedTools['PSScriptAnalyzer'])

        Should -Invoke Install-Module -Times 3 -Exactly -ParameterFilter {
            $Name -eq 'PSScriptAnalyzer' -and $RequiredVersion -eq $PinnedTools['PSScriptAnalyzer']
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
        Should -Invoke Write-Warning -Times 2 -Exactly
    }

    It 'gives up after the third attempt and says why' {
        Mock Install-Module { throw "No match was found for the specified search criteria and module name 'PSScriptAnalyzer'." }

        { Install-BuildTool -Name PSScriptAnalyzer } |
            Should -Throw "Could not install PSScriptAnalyzer $($PinnedTools['PSScriptAnalyzer']) from the PowerShell Gallery after 3 attempts: No match was found*"

        Should -Invoke Install-Module -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }
}
