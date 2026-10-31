# FailedBuildCleanup.Tests.ps1
# What a build leaves behind when it stops, and what it says about why
# (#227): the answer-file disc holds the guest password, a guest task that
# timed out stays registered, and the reason given must be the real one.
# Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $settings = @{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup'; GuestWaitMinutes = 90 }
}

Describe 'Wait-GuestReady' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Get-VMIntegrationService { [pscustomobject]@{ PrimaryStatusDescription = 'OK' } }
        Mock -ModuleName $module Remove-PSSession { } -RemoveParameterType Session
        Mock -ModuleName $module Invoke-Command { $false } -RemoveParameterType Session
        # The first try is refused, as before the account exists; every try
        # after that reaches a guest still in OOBE.
        $tries = @{ Count = 0 }
        Mock -ModuleName $module New-PSSession {
            $tries.Count++
            if ($tries.Count -eq 1) { throw 'The credential is invalid.' }
            [pscustomobject]@{ Name = 'session' }
        }
        # Two tries, then the time is up.
        Mock -ModuleName $module Wait-Until { $null = & $Condition $State; $null = & $Condition $State; $null }
    }

    It 'gives the reason the guest was last not ready, not an older error' {
        $wait = {
            InModuleScope $module -Parameters @{ Settings = $settings } {
                param($Settings)
                Wait-GuestReady -VM ([VMContext]::new($Settings)) -Credential ([pscredential]::new('lazy', [securestring]::new())) -TimeoutMinutes 90 -RequireProvisioned
            }
        }

        $failure = $wait | Should -Throw -ExpectedMessage '*first-logon*' -PassThru
        $failure.Exception.Message | Should -Not -BeLike '*credential is invalid*'
    }
}

Describe 'Install-GuestSoftware when the guest never gets ready' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Assert-GuestCredential { [pscredential]::new('lazy', [securestring]::new()) }
        Mock -ModuleName $module Wait-GuestReady { throw 'The guest did not become ready within 90 minutes.' }
        Mock -ModuleName $module Remove-UnattendSeedDisk { }

        $install = {
            param([switch]$UsedUnattend)
            InModuleScope $module -Parameters @{ Settings = $settings; UsedUnattend = [bool]$UsedUnattend } {
                param($Settings, $UsedUnattend)
                Install-GuestSoftware -VM ([VMContext]::new($Settings)) -UsedUnattend:$UsedUnattend
            }
        }
    }

    It 'still deletes the answer-file disc, which holds the guest password, and stops the build' {
        { & $install -UsedUnattend } | Should -Throw -ExpectedMessage '*did not become ready*'

        Should -Invoke -ModuleName $module Remove-UnattendSeedDisk -Times 1 -Exactly
    }

    It 'touches no answer-file disc when the build did not use one' {
        { & $install } | Should -Throw

        Should -Invoke -ModuleName $module Remove-UnattendSeedDisk -Times 0 -Exactly
    }
}

Describe 'Invoke-GuestTask when it times out' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Start-Sleep { }
        $guest = @{ TidyFails = $false }
        Mock -ModuleName $module Invoke-GuestScript {
            switch -Wildcard ($Activity) {
                'starting *' { 'boot1' }
                'checking on *' { [pscustomobject]@{ Done = $null; TaskState = 'Running'; BootTime = 'boot1' } }
                'tidying up *' { if ($guest.TidyFails) { throw 'The session state is Broken.' } }
            }
        }

        $run = {
            InModuleScope $module -Parameters @{ Settings = $settings } {
                param($Settings)
                Invoke-GuestTask -VM ([VMContext]::new($Settings)) -TaskName 'LazyVM-VSSettings' -Work { 'OK' } -TimeoutMinutes 0 -Activity 'Visual Studio settings restore'
            }
        }
    }

    It 'removes the guest task before reporting the timeout' {
        $run | Should -Throw -ExpectedMessage 'Visual Studio settings restore did not finish within*'

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'tidying up *' }
    }

    It 'still reports the timeout when the guest task cannot be removed' {
        $guest.TidyFails = $true

        $run | Should -Throw -ExpectedMessage 'Visual Studio settings restore did not finish within*'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*LazyVM-VSSettings*' -and $Level -eq 'WARN' }
    }
}
