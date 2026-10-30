# HyperV.Tests.ps1
# Repair-HyperVService and Enable-HyperVFeature each return exactly one
# result, so the build phases can use it as it is (#160). The helpers they
# call are mocked to write stray output, which must not reach the caller.
# Nothing here changes the host: every service, feature, task and restart
# cmdlet is mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Classes defined in a module are only visible inside it.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }
}

Describe 'Repair-HyperVService' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-Service {
            $startType = if ($Name -eq 'vmms') { 'Automatic' } else { 'Manual' }
            [pscustomobject]@{ Name = $Name; StartType = $startType; Status = 'Running' }
        }
        Mock -ModuleName $module Set-Service { throw 'must not change a service' }
        Mock -ModuleName $module Start-Service { throw 'must not start a service' }
    }

    It 'returns only $false when the services are healthy' {
        $result = @(InModuleScope $module { Repair-HyperVService })

        $result.Count | Should -Be 1
        $result[0] | Should -BeFalse
    }
}

Describe 'Enable-HyperVFeature' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-CimInstance { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26100' } }
        Mock -ModuleName $module Get-WindowsOptionalFeature { [pscustomobject]@{ FeatureName = $FeatureName; State = 'Disabled' } }
        Mock -ModuleName $module Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
        Mock -ModuleName $module Register-ResumeTask { 'stray' }
        Mock -ModuleName $module Unregister-ResumeTask { 'stray' }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Restart-Computer { throw 'must not restart the host' }
    }

    It 'returns only $false when Hyper-V is turned on without a restart' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Enable-HyperVFeature -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeFalse
    }
}
