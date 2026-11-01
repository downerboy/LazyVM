# WindowsUpdate.Tests.ps1
# Windows updates in the guest at build and nightly (#234): what is
# installed, and when the guest is restarted for them. Also who is signed in
# to the guest, and restarting Windows gracefully. The guest is mocked;
# nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestWaitMinutes = 1 }) }
    $credential = [pscredential]::new('lazy', [securestring]::new())

    function New-UpdateReport {
        <# What the Windows Update guest task reports: its notes as JSON, and whether a restart is needed. #>
        param([bool]$RestartNeeded, [object[]]$Notes = @())

        return (ConvertTo-Json -InputObject @{ Notes = @($Notes); RestartNeeded = $RestartNeeded } -Compress -Depth 3)
    }
}

Describe 'Get-GuestSignedInUser (#234)' {
    It 'returns the accounts that have a desktop in the guest, as plain strings' {
        Mock -ModuleName $module Invoke-GuestScript { @('lazy', 'sean') }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-GuestSignedInUser -VM $VM })

        $result | Should -Be @('lazy', 'sean')
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'explorer\.exe' -and "$ScriptBlock" -match 'GetOwner' }
    }

    It 'returns nothing when nobody is signed in' {
        Mock -ModuleName $module Invoke-GuestScript { }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-GuestSignedInUser -VM $VM })

        $result.Count | Should -Be 0
    }
}

Describe 'Restart-GuestGracefully (#234)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Assert-GuestCredential { $credential }
        Mock -ModuleName $module Invoke-GuestScript { 'boot1' } -ParameterFilter { $Activity -eq 'reading the boot time' }
        Mock -ModuleName $module Invoke-GuestScript { 0 } -ParameterFilter { $Activity -eq 'restarting Windows' }
        Mock -ModuleName $module Remove-GuestSession { }
        Mock -ModuleName $module Invoke-Command { 'boot2' }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Connect-Guest { 'session' }
        Mock -ModuleName $module Restart-VM { }
    }

    It 'restarts Windows from inside the guest, with a neutral message, never with a reset, and reconnects once it is back' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restart-GuestGracefully -VM $VM })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'shutdown\.exe /r' -and "$ScriptBlock" -match "'LazyVM is restarting Windows\.'" }
        Should -Invoke -ModuleName $module Restart-VM -Times 0
        Should -Invoke -ModuleName $module Connect-Guest -Times 1 -Exactly
    }

    It 'waits until the guest reports a new boot time, so a guest still installing updates before it restarts is not taken as restarted' {
        $script:bootTimes = [System.Collections.Generic.Queue[object]]::new([object[]]@('boot1', $null, 'boot2'))
        Mock -ModuleName $module Invoke-Command {
            $next = $script:bootTimes.Dequeue()
            if ($null -eq $next) { throw 'The virtual machine is not running' }
            $next
        }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restart-GuestGracefully -VM $VM }

        Should -Invoke -ModuleName $module Invoke-Command -Times 3 -Exactly -ParameterFilter { $VMName -eq 'Alpha' }
        Should -Invoke -ModuleName $module Connect-Guest -Times 1 -Exactly
    }

    It 'throws when the guest does not come back within the wait' {
        Mock -ModuleName $module Invoke-Command { 'boot1' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restart-GuestGracefully -VM $VM } } | Should -Throw '*restart*'

        Should -Invoke -ModuleName $module Connect-Guest -Times 0
    }

    It 'throws, without waiting, when Windows refuses to restart' {
        Mock -ModuleName $module Invoke-GuestScript { 5 } -ParameterFilter { $Activity -eq 'restarting Windows' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restart-GuestGracefully -VM $VM } } | Should -Throw '*5*'

        Should -Invoke -ModuleName $module Invoke-Command -Times 0
    }
}

Describe 'Install-GuestWindowsUpdate (#234)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'installs quality and security updates through the Windows Update Agent, from a task running as SYSTEM' {
        Mock -ModuleName $module Invoke-GuestTask { New-UpdateReport -RestartNeeded $false }

        $null = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Install-GuestWindowsUpdate -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -like '*windows-update' -and -not $AsGuestUser -and $TimeoutMinutes -ge 60 -and
            "$Work" -match 'Microsoft\.Update\.Session' -and
            "$Work" -match "IsInstalled=0 and IsHidden=0 and Type='Software'"
        }
    }

    It 'leaves out feature updates and optional updates' {
        Mock -ModuleName $module Invoke-GuestTask { New-UpdateReport -RestartNeeded $false }

        $null = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Install-GuestWindowsUpdate -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            # 3689bdc8-... is the Upgrades category, which holds feature updates.
            "$Work" -match '3689bdc8-b205-4af4-8d4a-a63924c5e9d5' -and "$Work" -match 'BrowseOnly'
        }
    }

    It 'installs only the updates that downloaded, and warns about each one that did not' {
        Mock -ModuleName $module Invoke-GuestTask { New-UpdateReport -RestartNeeded $false }

        $null = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Install-GuestWindowsUpdate -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            "$Work" -match '\.IsDownloaded' -and "$Work" -match 'not downloaded: '
        }
    }

    It 'logs what the guest reported and returns whether a restart is needed' {
        Mock -ModuleName $module Invoke-GuestTask {
            New-UpdateReport -RestartNeeded $true -Notes @([pscustomobject]@{ Level = 'OK'; Text = 'installed: 2026-10 Cumulative Update (KB5099999)' })
        }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Install-GuestWindowsUpdate -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeTrue
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -match 'KB5099999' }
    }
}

Describe 'Set-GuestWindowsUpdatePolicy (#234)' {
    It 'sets automatic updates never to restart while someone is signed in' {
        Mock -ModuleName $module Invoke-GuestScript { 'stray' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Set-GuestWindowsUpdatePolicy -VM $VM })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            "$ScriptBlock" -match 'NoAutoRebootWithLoggedOnUsers' -and "$ScriptBlock" -match 'AUOptions'
        }
    }
}

Describe 'Update-GuestWindows (#234)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Set-GuestWindowsUpdatePolicy { 'stray' }
        Mock -ModuleName $module Install-GuestWindowsUpdate { $true }
        Mock -ModuleName $module Get-GuestSignedInUser { }
        Mock -ModuleName $module Restart-GuestGracefully { 'stray' }
    }

    It 'sets the policy, so a VM built before this gets it too, then installs the updates' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWindows -VM $VM })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Set-GuestWindowsUpdatePolicy -Times 1 -Exactly
        Should -Invoke -ModuleName $module Install-GuestWindowsUpdate -Times 1 -Exactly
    }

    It 'does not restart when no restart is needed' {
        Mock -ModuleName $module Install-GuestWindowsUpdate { $false }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWindows -VM $VM }

        Should -Invoke -ModuleName $module Restart-GuestGracefully -Times 0
    }

    It 'restarts when nobody is signed in' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWindows -VM $VM }

        Should -Invoke -ModuleName $module Restart-GuestGracefully -Times 1 -Exactly
    }

    It 'leaves the restart pending, and says who is signed in, when someone is' {
        Mock -ModuleName $module Get-GuestSignedInUser { 'sean' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWindows -VM $VM }

        Should -Invoke -ModuleName $module Restart-GuestGracefully -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'pending' -and $Message -match 'sean' }
    }

    It 'restarts a VM that LazyVM started, whoever automatic sign-in signed in' {
        Mock -ModuleName $module Get-GuestSignedInUser { 'lazy' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWindows -VM $VM -StartedByLazyVM }

        Should -Invoke -ModuleName $module Restart-GuestGracefully -Times 1 -Exactly
    }
}
