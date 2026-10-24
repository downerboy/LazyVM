# Common.Tests.ps1
# The helpers every part of LazyVM uses: waiting for something to happen,
# running steps where one failing must not stop the rest, and telling a
# rejected password from a guest that is not ready yet. Nothing here
# touches Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
}

Describe 'Wait-Until' {
    BeforeEach {
        Mock -ModuleName $module Start-Sleep { }
    }

    It 'returns what the condition returned once it is true' {
        InModuleScope $module {
            $state = @{ Tries = 0 }
            $result = Wait-Until -Timeout ([timespan]::FromMinutes(1)) -Interval ([timespan]::FromSeconds(1)) -State $state -Condition {
                param($s)
                $s.Tries++
                if ($s.Tries -ge 3) { 'ready' }
            }

            $result | Should -Be 'ready'
            $state.Tries | Should -Be 3
        }
    }

    It 'says what did not finish, and within how long, when it runs out of time' {
        {
            InModuleScope $module {
                Wait-Until -Activity 'The shutdown' -Timeout ([timespan]::FromSeconds(30)) -Interval ([timespan]::FromSeconds(10)) -Condition { $false }
            }
        } | Should -Throw -ExpectedMessage 'The shutdown did not finish within 30 second(s).'
    }

    It 'returns nothing instead with -NoThrow' {
        InModuleScope $module {
            Wait-Until -Timeout ([timespan]::FromSeconds(30)) -Interval ([timespan]::FromSeconds(10)) -NoThrow -Condition { $false }
        } | Should -BeNullOrEmpty
    }

    It 'lets the condition see the caller''s variables' {
        InModuleScope $module {
            $expected = 'from the caller'
            Wait-Until -Timeout ([timespan]::FromSeconds(30)) -Condition { $expected }
        } | Should -Be 'from the caller'
    }
}

Describe 'Invoke-IsolatedStep' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
    }

    It 'runs every step even when one fails, and reports which failed' {
        $outcome = InModuleScope $module {
            Invoke-IsolatedStep -What 'test' -Steps @(
                @{ Name = 'first'; Action = { 1 } }
                @{ Name = 'second'; Action = { throw 'broken' } }
                @{ Name = 'third'; Action = { 3 } }
            )
        }

        $outcome.Results['first'] | Should -Be 1
        $outcome.Results['third'] | Should -Be 3
        $outcome.Failures | Should -Be @('second: broken')
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }

    It 'reports no failures when every step works' {
        InModuleScope $module {
            (Invoke-IsolatedStep -What 'test' -Steps @(@{ Name = 'only'; Action = { 'done' } })).Failures
        } | Should -BeNullOrEmpty
    }
}

Describe 'Test-GuestLogonFailure' {
    It "returns <Expected> for '<Message>'" -ForEach @(
        @{ Message = 'The credential is invalid.'; Expected = $true }
        @{ Message = 'The user name or password is incorrect.'; Expected = $true }
        @{ Message = 'The virtual machine is not running.'; Expected = $false }
    ) {
        $record = [System.Management.Automation.ErrorRecord]::new([Exception]::new($Message), 'Test', 'NotSpecified', $null)

        InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            Test-GuestLogonFailure -ErrorRecord $Record
        } | Should -Be $Expected
    }
}
