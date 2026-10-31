# TestHelpers.Tests.ps1
# The Hyper-V cmdlet stubs (#28). Pester can only mock a command that
# exists, so on a runner without Hyper-V the helpers define a stub for each
# cmdlet the tests mock, and leave a real cmdlet alone.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Add-MissingCommandStub' {
    AfterEach {
        Remove-Item -Path 'Function:\global:Get-LazyVMTestMissing' -ErrorAction SilentlyContinue
    }

    It 'defines a stub, which throws until it is mocked, for a command that is missing' {
        Add-MissingCommandStub -Stub @{ 'Get-LazyVMTestMissing' = { [CmdletBinding()] param($Name) throw "stub called with $Name" } }

        { Get-LazyVMTestMissing -Name 'Alpha' } | Should -Throw -ExpectedMessage 'stub called with Alpha'
    }

    It 'leaves a command that exists alone' {
        Add-MissingCommandStub -Stub @{ 'Get-Date' = { 'stub' } }

        (Get-Command -Name 'Get-Date').CommandType | Should -Be 'Cmdlet'
    }
}

Describe 'The Hyper-V cmdlet stubs' {
    It 'gives every Hyper-V cmdlet the tests mock a command to mock' {
        $missing = @($script:HyperVCommandStubs.Keys | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })

        $missing | Should -BeNullOrEmpty
    }
}
