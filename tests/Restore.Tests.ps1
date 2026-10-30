# Restore.Tests.ps1
# Restore-GuestState returns exactly one result, so callers can use it as it
# is (#160). The helpers it calls are mocked to write stray output, which
# must not reach the caller. Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Classes defined in a module are only visible inside it.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }
}

Describe 'Restore-GuestState' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-CaptureManifest { [pscustomobject]@{ CapturedAt = '2026-10-29' } }
        Mock -ModuleName $module Open-GuestSession { 'stray' }
        Mock -ModuleName $module Initialize-GuestSqlDisk { 'stray' }
        Mock -ModuleName $module Invoke-IsolatedStep { [pscustomobject]@{ Results = @{}; Failures = @() } }
    }

    It 'returns only $true when every area is restored' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restore-GuestState -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeTrue
    }
}
