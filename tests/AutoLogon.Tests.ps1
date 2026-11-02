# AutoLogon.Tests.ps1
# The guest's automatic sign-in stays on for the VM's life (#278): the
# nightly step turns it back on, with no limit, when Windows turned it off
# or a logon count remains, and stores the password as the LSA secret
# Winlogon reads, never in the registry. A VM built with -NoUnattend is
# left alone. The guest is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    function New-TestAutoLogonState {
        <# What Get-GuestAutoLogonState reports: by default, an unattended VM with automatic sign-in on and no limit. #>
        param(
            [bool]$Unattended = $true,
            [string]$AutoAdminLogon = '1',
            [bool]$HasLogonCount = $false,
            [bool]$HasPlainTextPassword = $false
        )

        return [pscustomobject]@{
            Unattended           = $Unattended
            AutoAdminLogon       = $AutoAdminLogon
            HasLogonCount        = $HasLogonCount
            HasPlainTextPassword = $HasPlainTextPassword
        }
    }
}

Describe 'Test-AutoLogonRenewalNeeded' {
    It 'is false when automatic sign-in is on with no limit and no password in the registry' {
        $state = New-TestAutoLogonState

        InModuleScope $module -Parameters @{ State = $state } { param($State) Test-AutoLogonRenewalNeeded -State $State } | Should -BeFalse
    }

    It 'is true when <Case>' -ForEach @(
        @{ Case = 'Windows turned automatic sign-in off'; State = @{ AutoAdminLogon = '0' } }
        @{ Case = 'automatic sign-in was never set'; State = @{ AutoAdminLogon = '' } }
        @{ Case = 'a logon count remains'; State = @{ HasLogonCount = $true } }
        @{ Case = 'the password is in the registry in clear text'; State = @{ HasPlainTextPassword = $true } }
    ) {
        $testState = New-TestAutoLogonState @State

        InModuleScope $module -Parameters @{ State = $testState } { param($State) Test-AutoLogonRenewalNeeded -State $State } | Should -BeTrue
    }
}

Describe 'Repair-GuestAutoLogon' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $password = [securestring]::new()
        foreach ($character in 'S3cret&<pass'.ToCharArray()) { $password.AppendChar($character) }
        $credential = [pscredential]::new('devadmin', $password)
        Mock -ModuleName $module Assert-GuestCredential { $credential }
        Mock -ModuleName $module Invoke-GuestScript { 'stray' } -ParameterFilter { "$ScriptBlock" -match 'Enable-GuestAutoLogon' }
    }

    It 'leaves a VM built without the answer file (-NoUnattend) alone' {
        Mock -ModuleName $module Invoke-GuestScript { New-TestAutoLogonState -Unattended $false -AutoAdminLogon '0' } -ParameterFilter { "$ScriptBlock" -match 'Get-GuestAutoLogonState' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Repair-GuestAutoLogon -VM $VM }

        Should -Invoke -ModuleName $module Assert-GuestCredential -Times 0 -Exactly
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Enable-GuestAutoLogon' }
    }

    It 'changes nothing when automatic sign-in is already on with no limit' {
        Mock -ModuleName $module Invoke-GuestScript { New-TestAutoLogonState } -ParameterFilter { "$ScriptBlock" -match 'Get-GuestAutoLogonState' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Repair-GuestAutoLogon -VM $VM }

        Should -Invoke -ModuleName $module Assert-GuestCredential -Times 0 -Exactly
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Enable-GuestAutoLogon' }
    }

    It 'turns automatic sign-in back on with the stored guest credential when it expired' {
        Mock -ModuleName $module Invoke-GuestScript { New-TestAutoLogonState -AutoAdminLogon '0' } -ParameterFilter { "$ScriptBlock" -match 'Get-GuestAutoLogonState' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Repair-GuestAutoLogon -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            "$ScriptBlock" -match 'Enable-GuestAutoLogon' -and $ArgumentList[0] -eq 'devadmin' -and $ArgumentList[1] -eq 'S3cret&<pass'
        }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -match 'devadmin' }
    }

    It 'reads the marker the answer file''s first sign-in sets' {
        Mock -ModuleName $module Invoke-GuestScript { New-TestAutoLogonState } -ParameterFilter { "$ScriptBlock" -match 'Get-GuestAutoLogonState' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Repair-GuestAutoLogon -VM $VM }

        $markerKey = InModuleScope $module { $script:GuestMarkerKey }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            "$ScriptBlock" -match 'Get-GuestAutoLogonState' -and $ArgumentList[0] -eq $markerKey
        }
    }

    It 'emits nothing' {
        Mock -ModuleName $module Invoke-GuestScript { New-TestAutoLogonState -HasLogonCount $true } -ParameterFilter { "$ScriptBlock" -match 'Get-GuestAutoLogonState' }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Repair-GuestAutoLogon -VM $VM })

        $result.Count | Should -Be 0
    }
}

Describe 'Get-GuestAutoLogonState (guest helper)' {
    BeforeEach {
        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    }

    It 'reports automatic sign-in on, with a count and a clear-text password, on a provisioned VM' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoAdminLogon = '1'; AutoLogonCount = 97; DefaultPassword = 'x' } } -ParameterFilter { $Path -eq $winlogonKey }
        Mock Get-ItemProperty { [pscustomobject]@{ Provisioned = 1 } } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\LazyVM' }

        $state = Get-GuestAutoLogonState -MarkerKey 'HKLM:\SOFTWARE\LazyVM'

        $state.Unattended | Should -BeTrue
        $state.AutoAdminLogon | Should -Be '1'
        $state.HasLogonCount | Should -BeTrue
        $state.HasPlainTextPassword | Should -BeTrue
    }

    It 'reports automatic sign-in off, with no count or password, and no marker' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoAdminLogon = '0' } } -ParameterFilter { $Path -eq $winlogonKey }
        Mock Get-ItemProperty { } -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\LazyVM' }

        $state = Get-GuestAutoLogonState -MarkerKey 'HKLM:\SOFTWARE\LazyVM'

        $state.Unattended | Should -BeFalse
        $state.AutoAdminLogon | Should -Be '0'
        $state.HasLogonCount | Should -BeFalse
        $state.HasPlainTextPassword | Should -BeFalse
    }
}

Describe 'Enable-GuestAutoLogon (guest helper)' {
    BeforeEach {
        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Mock Save-GuestAutoLogonSecret { }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
        Mock Get-ItemProperty { [pscustomobject]@{ AutoAdminLogon = '0'; AutoLogonCount = 0; DefaultPassword = 'old' } } -ParameterFilter { $Path -eq $winlogonKey }
    }

    It 'stores the password as the LSA secret, never in the registry' {
        Enable-GuestAutoLogon -UserName 'devadmin' -Password 'S3cret'

        Should -Invoke Save-GuestAutoLogonSecret -Times 1 -Exactly -ParameterFilter { $Password -eq 'S3cret' }
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -ParameterFilter { $Name -eq 'DefaultPassword' }
    }

    It 'turns automatic sign-in on for the account' {
        Enable-GuestAutoLogon -UserName 'devadmin' -Password 'S3cret'

        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $winlogonKey -and $Name -eq 'AutoAdminLogon' -and $Value -eq '1' }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $winlogonKey -and $Name -eq 'DefaultUserName' -and $Value -eq 'devadmin' }
    }

    It 'removes the logon count, so it never runs out, and any clear-text password' {
        Enable-GuestAutoLogon -UserName 'devadmin' -Password 'S3cret'

        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $winlogonKey -and $Name -eq 'AutoLogonCount' }
        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter { $Path -eq $winlogonKey -and $Name -eq 'DefaultPassword' }
    }

    It 'removes nothing that is not there' {
        Mock Get-ItemProperty { [pscustomobject]@{ AutoAdminLogon = '0' } } -ParameterFilter { $Path -eq $winlogonKey }

        Enable-GuestAutoLogon -UserName 'devadmin' -Password 'S3cret'

        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'stores the secret before turning automatic sign-in on, so a failed store changes nothing' {
        Mock Save-GuestAutoLogonSecret { throw 'LsaStorePrivateData failed: 5' }

        { Enable-GuestAutoLogon -UserName 'devadmin' -Password 'S3cret' } | Should -Throw '*LsaStorePrivateData*'

        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }
}
