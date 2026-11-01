# WingetUpgrade.Tests.ps1
# The nightly winget upgrades in the guest (#235): everything winget can
# upgrade, except Visual Studio and SQL Server, packages pinned with
# winget pin, and programs that are running. The guest is mocked; nothing
# here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $testVM = InModuleScope $module {
        $vm = [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM\Setup' })
        $vm.Runtime.GuestAdminUser = 'lazy'
        $vm
    }
    $winget = 'C:\Users\lazy\AppData\Local\Microsoft\WindowsApps\winget.exe'

    function New-Upgrade {
        <# One package winget can upgrade, as Get-GuestWingetUpgrade reports it. #>
        param([string]$Id, [string[]]$Folders = @("C:\Program Files\$Id"))

        return [pscustomobject]@{ Id = $Id; Name = $Id; Folders = $Folders }
    }
}

Describe 'Test-WingetUpgradeAllowed (#235)' {
    It 'allows <Id>' -ForEach @(
        @{ Id = 'Git.Git' }
        @{ Id = 'Microsoft.VisualStudioCode' }
        @{ Id = 'Microsoft.Sqlcmd' }
        @{ Id = 'Microsoft.DotNet.SDK.10' }
    ) {
        InModuleScope $module -Parameters @{ Id = $Id } { param($Id) Test-WingetUpgradeAllowed -Id $Id } | Should -BeTrue
    }

    It 'never allows <Id>, which its own installer services' -ForEach @(
        @{ Id = 'Microsoft.VisualStudio.Community' }
        @{ Id = 'Microsoft.VisualStudio.2022.Professional' }
        @{ Id = 'Microsoft.SQLServer.2025.Developer' }
        @{ Id = 'Microsoft.SQLServerManagementStudio' }
    ) {
        InModuleScope $module -Parameters @{ Id = $Id } { param($Id) Test-WingetUpgradeAllowed -Id $Id } | Should -BeFalse
    }
}

Describe 'Resolve-GuestWingetId (#235)' {
    BeforeAll {
        $known = @('Git.Git', 'JetBrains.Toolbox', 'Microsoft.DotNet.DesktopRuntime.8', 'Microsoft.DotNet.DesktopRuntime.9')
        $ellipsis = [string][char]0x2026
    }

    It 'returns a whole id as it is' {
        Resolve-GuestWingetId -Id 'Git.Git' -KnownId $known | Should -Be 'Git.Git'
    }

    It 'completes an id winget cut short, from the one known id it starts' {
        Resolve-GuestWingetId -Id "JetBrains.Tool$ellipsis" -KnownId $known | Should -Be 'JetBrains.Toolbox'
    }

    It 'returns nothing when an id cut short could be more than one package' {
        Resolve-GuestWingetId -Id "Microsoft.DotNet.Desktop$ellipsis" -KnownId $known | Should -Be ''
    }
}

Describe 'Get-GuestProgramFolder (#235)' {
    BeforeAll {
        $ellipsis = [string][char]0x2026
        # What Windows sets, for a test runner that is not Windows.
        if (-not $env:windir) { $env:windir = 'C:\Windows' }
    }

    BeforeEach {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = 'Git'; InstallLocation = 'C:\Program Files\Git\'; DisplayIcon = '' }
                [pscustomobject]@{ DisplayName = 'Notepad++ (64-bit x64)'; InstallLocation = ''; DisplayIcon = '"C:\Program Files\Notepad++\notepad++.exe",0' }
                [pscustomobject]@{ DisplayName = 'Node.js'; InstallLocation = ''; DisplayIcon = 'C:\Windows\Installer\{1234}\icon.ico' }
                [pscustomobject]@{ DisplayName = 'Some Tool'; InstallLocation = ''; DisplayIcon = '' }
            )
        }
    }

    It 'returns the install location of the program with that name' {
        Get-GuestProgramFolder -Name 'Git' | Should -Be 'C:\Program Files\Git'
    }

    It 'falls back to the folder of its icon' {
        Get-GuestProgramFolder -Name 'Notepad++ (64-bit x64)' | Should -Be 'C:\Program Files\Notepad++'
    }

    It 'matches a name winget cut short by how it starts' {
        Get-GuestProgramFolder -Name "Notepad++ (64$ellipsis" | Should -Be 'C:\Program Files\Notepad++'
    }

    It 'returns nothing for a program whose only clue is in the Windows folder, or that has none' {
        @(Get-GuestProgramFolder -Name 'Node.js').Count | Should -Be 0
        @(Get-GuestProgramFolder -Name 'Some Tool').Count | Should -Be 0
    }
}

Describe 'Update-GuestWingetPackage (#235)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Invoke-GuestScript { $winget } -ParameterFilter { $Activity -eq 'finding winget' }
        Mock -ModuleName $module Get-GuestSignedInUser { 'lazy' }
        Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Git.Git' }
        Mock -ModuleName $module Invoke-GuestTask { '[{"Level":"OK","Text":"upgraded: Git.Git"}]' }
    }

    It 'upgrades from a task running as the guest account elevated, so per-user packages upgrade too' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -like '*winget-upgrade' -and $AsGuestUser -and $Elevated -and $TimeoutMinutes -gt 0 -and
            "$Work" -match 'winget upgrade|& \$winget upgrade' -and "$Work" -match 'ExecutablePath'
        }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'upgraded: Git.Git' }
    }

    It 'passes the task the packages to upgrade, with the folders that tell whether each is running' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $packages = @($ArgumentList[1])
            $ArgumentList[0] -eq $winget -and $packages.Count -eq 1 -and $packages[0].Id -eq 'Git.Git' -and @($packages[0].Folders) -contains 'C:\Program Files\Git.Git'
        }
    }

    It 'shares the winget exit-code table with the installs' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[2]['-1978335212'] -eq 'no package matched that identifier'
        }
    }

    It 'never upgrades Visual Studio or SQL Server, and says so' {
        Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Microsoft.VisualStudio.Community'; New-Upgrade -Id 'Microsoft.SQLServer.2025.Developer'; New-Upgrade -Id 'Git.Git' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { (@($ArgumentList[1]).Id -join ',') -eq 'Git.Git' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 2 -Exactly -ParameterFilter { $Message -match 'Microsoft\.(VisualStudio|SQLServer)' -and $Message -match 'own installer' }
    }

    It 'skips, and says why, a package when it cannot tell whether its program is running' {
        Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Some.Tool' -Folders @(); New-Upgrade -Id 'Git.Git' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { (@($ArgumentList[1]).Id -join ',') -eq 'Git.Git' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'Some\.Tool' -and $Message -match 'running' }
    }

    It 'starts no task when nothing is to be upgraded' {
        Mock -ModuleName $module Get-GuestWingetUpgrade { }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -match 'up to date' }
    }

    It 'skips tonight, and says why, when the guest account is not signed in to run the upgrades in' {
        Mock -ModuleName $module Get-GuestSignedInUser { 'someoneelse' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestWingetUpgrade -Times 0
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'lazy' -and $Message -match 'not signed in' }
    }

    It 'skips, and says why, when the guest has no winget' {
        Mock -ModuleName $module Invoke-GuestScript { $null } -ParameterFilter { $Activity -eq 'finding winget' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'winget is not available' }
    }
}

Describe 'Get-GuestWingetUpgrade (#235)' {
    It 'lists the upgrades from winget''s own source, which leaves out pinned packages, with each program''s folders' {
        Mock -ModuleName $module Invoke-GuestScript { New-Upgrade -Id 'Git.Git' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM; Winget = $winget } { param($VM, $Winget) Get-GuestWingetUpgrade -VM $VM -Winget $Winget })

        $result.Count | Should -Be 1
        $result[0].Id | Should -Be 'Git.Git'
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            "$ScriptBlock" -match 'upgrade --source winget' -and "$ScriptBlock" -match 'ConvertFrom-GuestWingetTable' -and
            "$ScriptBlock" -match 'Resolve-GuestWingetId' -and "$ScriptBlock" -match 'Get-GuestProgramFolder' -and $ArgumentList[0] -eq $Winget
        }
    }
}
