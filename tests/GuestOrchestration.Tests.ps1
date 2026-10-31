# GuestOrchestration.Tests.ps1
# Talking to the guest: reopening a dropped PowerShell Direct session,
# seeing a long installer through restarts and timeouts, and the Windows
# clean-up (#28). PowerShell Direct and the guest are mocked, through the
# Hyper-V stubs in TestHelpers.ps1 where the runner has no Hyper-V; nothing
# here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $settings = @{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup' }
    $credential = [pscredential]::new('lazy', [securestring]::new())

    function New-TaskStatus {
        <# What Get-GuestTaskStatus reports from the guest. #>
        param(
            [string]$Done,
            [string]$TaskState = 'Running',
            [string]$BootTime = 'boot1'
        )

        return [pscustomobject]@{ Done = $Done; TaskState = $TaskState; BootTime = $BootTime }
    }
}

Describe 'Restore-GuestSession' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module New-PSSession { [pscustomobject]@{ State = 'Opened'; Name = 'reopened' } }
        Mock -ModuleName $module Remove-PSSession { } -RemoveParameterType Session
        Mock -ModuleName $module Invoke-Command { } -RemoveParameterType Session
    }

    It 'reopens a session the guest dropped, with the stored credential' {
        $vm = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }
        $vm.Runtime.Credential = $credential
        $vm.Runtime.Session = [pscustomobject]@{ State = 'Broken'; Name = 'dropped' }

        $session = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Restore-GuestSession -VM $VM }

        $session.Name | Should -Be 'reopened'
        $vm.Runtime.Session.Name | Should -Be 'reopened'
        $vm.Runtime.Credential | Should -Be $credential
        Should -Invoke -ModuleName $module New-PSSession -Times 1 -Exactly -ParameterFilter { $VMName -eq 'Alpha' -and $Credential.UserName -eq 'lazy' }
    }

    It 'keeps a session that is still open' {
        $vm = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }
        $vm.Runtime.Credential = $credential
        $vm.Runtime.Session = [pscustomobject]@{ State = 'Opened'; Name = 'open' }

        $session = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Restore-GuestSession -VM $VM }

        $session.Name | Should -Be 'open'
        Should -Invoke -ModuleName $module New-PSSession -Times 0 -Exactly
    }

    It 'returns nothing when there is no credential to reconnect with' {
        $vm = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }
        $vm.Runtime.Session = [pscustomobject]@{ State = 'Broken'; Name = 'dropped' }

        $session = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Restore-GuestSession -VM $VM }

        $session | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module New-PSSession -Times 0 -Exactly
    }
}

Describe 'Invoke-GuestInstaller' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Start-Sleep { }

        # The guest: the task starts, then each check takes the next status;
        # the last one repeats.
        $guest = @{ Statuses = [System.Collections.Generic.Queue[object]]::new() }
        Mock -ModuleName $module Invoke-GuestScript {
            switch -Wildcard ($Activity) {
                'starting *' { 'boot1' }
                'restarting *' { 'boot2' }
                'checking on *' {
                    $next = if ($guest.Statuses.Count -gt 1) { $guest.Statuses.Dequeue() } else { $guest.Statuses.Peek() }
                    if ($next -is [scriptblock]) { & $next } else { $next }
                }
            }
        }

        $install = {
            param([int]$TimeoutMinutes = 5)
            InModuleScope $module -Parameters @{ Settings = $settings; TimeoutMinutes = $TimeoutMinutes } {
                param($Settings, $TimeoutMinutes)
                Invoke-GuestInstaller -VM ([VMContext]::new($Settings)) -FilePath 'C:\LazyVMSetup\setup.exe' -Name 'vs' -TimeoutMinutes $TimeoutMinutes
            }
        }
    }

    It 'returns the exit code of an installer that has finished' {
        $guest.Statuses.Enqueue((New-TaskStatus -Done '0' -TaskState 'Ready'))

        $exitCode = & $install

        $exitCode | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'tidying up after *' }
    }

    It 'waits for an installer that is still running' {
        $guest.Statuses.Enqueue((New-TaskStatus))
        $guest.Statuses.Enqueue((New-TaskStatus))
        $guest.Statuses.Enqueue((New-TaskStatus -Done '3010' -TaskState 'Ready'))

        $exitCode = & $install

        $exitCode | Should -Be 3010
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 3 -Exactly -ParameterFilter { $Activity -like 'checking on *' }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { $Activity -like 'restarting *' }
    }

    It 'keeps checking when the session drops during a check' {
        $guest.Statuses.Enqueue({ throw 'The session state is Broken.' })
        $guest.Statuses.Enqueue((New-TaskStatus -Done '0' -TaskState 'Ready'))

        $exitCode = & $install

        $exitCode | Should -Be 0
    }

    It 'starts the installer again when the guest restarted before it finished' {
        $guest.Statuses.Enqueue((New-TaskStatus -TaskState 'Ready' -BootTime 'boot2'))
        $guest.Statuses.Enqueue((New-TaskStatus -Done '0' -TaskState 'Ready' -BootTime 'boot2'))

        $exitCode = & $install

        $exitCode | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'restarting *' }
    }

    It 'gives up after starting the installer again three times' {
        $guest.Statuses.Enqueue((New-TaskStatus -TaskState 'Ready'))

        { & $install } | Should -Throw -ExpectedMessage '*stopped before finishing, 4 time(s)'
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 3 -Exactly -ParameterFilter { $Activity -like 'restarting *' }
    }

    It 'stops waiting when the timeout runs out' {
        $guest.Statuses.Enqueue((New-TaskStatus))

        { & $install -TimeoutMinutes 0 } | Should -Throw -ExpectedMessage 'vs did not finish within*'
    }
}

Describe 'Set-GuestCustomization' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Write-GuestNote { }

        # Every customization setting, turned off, as the settings files give them.
        $plain = $settings + @{
            GuestRemoveApps         = @()
            GuestRemoveOneDrive     = $false
            GuestHideWidgets        = $false
            GuestDarkMode           = $false
            GuestShowFileExtensions = $false
            GuestTaskbarLeft        = $false
            GuestHideTaskbarSearch  = $false
            GuestDeveloperMode      = $false
        }
    }

    It 'does nothing in the guest when nothing is asked for' {
        Mock -ModuleName $module Invoke-GuestScript { }

        InModuleScope $module -Parameters @{ Settings = $plain } { param($Settings) Set-GuestCustomization -VM ([VMContext]::new($Settings)) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
    }

    It 'hands the guest the apps to remove and the per-user settings, and logs what it reports' {
        Mock -ModuleName $module Invoke-GuestScript { @(@{ Level = 'OK'; Text = 'removed Microsoft.BingNews' }) }
        $asking = $plain.Clone()
        $asking.GuestRemoveApps = @('Microsoft.BingNews')
        $asking.GuestDarkMode = $true

        InModuleScope $module -Parameters @{ Settings = $asking } { param($Settings) Set-GuestCustomization -VM ([VMContext]::new($Settings)) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList[0] -join ',') -eq 'Microsoft.BingNews' -and @($ArgumentList[1]).Count -eq 2 -and -not $ArgumentList[2] -and -not $ArgumentList[3]
        }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { $Notes[0].Text -eq 'removed Microsoft.BingNews' }
    }

    It 'asks the guest to turn on Developer Mode when the settings say so (#238)' {
        Mock -ModuleName $module Invoke-GuestScript { }
        $asking = $plain.Clone()
        $asking.GuestDeveloperMode = $true

        InModuleScope $module -Parameters @{ Settings = $asking } { param($Settings) Set-GuestCustomization -VM ([VMContext]::new($Settings)) }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[4] -eq $true }
    }

    It 'logs a guest failure and lets the build carry on' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'Windows clean-up failed in guest: access denied' }
        $asking = $plain.Clone()
        $asking.GuestHideWidgets = $true

        { InModuleScope $module -Parameters @{ Settings = $asking } { param($Settings) Set-GuestCustomization -VM ([VMContext]::new($Settings)) } } | Should -Not -Throw
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }
}
