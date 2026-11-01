# Winget.Tests.ps1
# winget packages are installed by a scheduled task in the guest that the
# host checks on, so a dropped session or a guest restart does not lose the
# run or its report (#27). Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM\Setup' }) }
    $packages = @([pscustomobject]@{ Id = 'Git.Git'; Source = 'winget' })
}

Describe 'Install-WingetPackage' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Invoke-GuestScript { 'C:\Users\devadmin\AppData\Local\Microsoft\WindowsApps\winget.exe' }
        Mock -ModuleName $module Invoke-GuestTask { '[{"Level":"OK","Text":"installed: Git.Git"}]' }
    }

    It 'runs the installs as a task in the guest, as the guest account elevated, started again after a restart' {
        InModuleScope $module -Parameters @{ VM = $vm; Packages = $packages } { param($VM, $Packages) Install-WingetPackage -VM $VM -Packages $Packages }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { $AsGuestUser -and $Elevated -and $RestartAttempts -gt 0 }
    }

    It 'shares the winget exit-code table with the upgrades (#235)' {
        InModuleScope $module -Parameters @{ VM = $vm; Packages = $packages } { param($VM, $Packages) Install-WingetPackage -VM $VM -Packages $Packages }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { $ArgumentList[2]['-1978335212'] -eq 'no package matched that identifier' }
    }

    It 'logs the report the task wrote' {
        InModuleScope $module -Parameters @{ VM = $vm; Packages = $packages } { param($VM, $Packages) Install-WingetPackage -VM $VM -Packages $Packages }

        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'installed: Git.Git' }
    }

    It 'starts no task, and says why, when the guest has no winget' {
        Mock -ModuleName $module Invoke-GuestScript { $null }

        InModuleScope $module -Parameters @{ VM = $vm; Packages = $packages } { param($VM, $Packages) Install-WingetPackage -VM $VM -Packages $Packages }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*winget is not available*' }
    }

    It 'does not stop the build when the task fails' {
        Mock -ModuleName $module Invoke-GuestTask { throw 'winget packages stopped before finishing, 4 time(s)' }

        { InModuleScope $module -Parameters @{ VM = $vm; Packages = $packages } { param($VM, $Packages) Install-WingetPackage -VM $VM -Packages $Packages } } | Should -Not -Throw
    }

    Context 'the work the task runs' {
        BeforeEach {
            # A stand-in winget: 'list' finds nothing, 'install' succeeds.
            Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'winget.cmd') -Value '@if "%1"=="list" exit /b 1', '@exit /b 0'
            Mock -ModuleName $module Invoke-GuestScript { Join-Path -Path $TestDrive -ChildPath 'winget.cmd' }
            # Runs the work as the guest's task wrapper does: the script from
            # text, its arguments through JSON, and only its last line kept.
            Mock -ModuleName $module Invoke-GuestTask {
                $arguments = @(ConvertTo-Json -InputObject @($ArgumentList) -Depth 5 | ConvertFrom-Json)
                "$(@(& ([scriptblock]::Create($Work.ToString())) @arguments)[-1])"
            }
        }

        It 'installs what is missing and reports it' {
            InModuleScope $module -Parameters @{ VM = $vm; Packages = $packages } { param($VM, $Packages) Install-WingetPackage -VM $VM -Packages $Packages }

            Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'installed: Git.Git' }
        }
    }
}

Describe 'Start-GuestTask' {
    BeforeEach {
        Mock New-GuestFolder { }
        Mock Set-Content { }
        Mock Unregister-ScheduledTask { }
        # The New-ScheduledTask* builders only make objects, so they run for real.
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-31' } }
    }

    It 'runs as the user with their full token when told to run elevated' {
        Start-GuestTask -TaskName 'LazyVM-winget' -SetupDir 'C:\LazyVM\Setup' -Work 'return 1' -UserName 'devadmin' -Elevated -TimeoutSeconds 60

        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Principal.UserId -eq 'devadmin' -and "$($Principal.RunLevel)" -eq 'Highest' }
    }

    It 'runs as the user with their limited token otherwise' {
        Start-GuestTask -TaskName 'LazyVM-settings' -SetupDir 'C:\LazyVM\Setup' -Work 'return 1' -UserName 'devadmin' -TimeoutSeconds 60

        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Principal.UserId -eq 'devadmin' -and "$($Principal.RunLevel)" -eq 'Limited' }
    }
}
