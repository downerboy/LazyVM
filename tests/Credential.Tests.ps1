# Credential.Tests.ps1
# Get-LazyVMCredential -ToClipboard (#32): VMConnect blocks paste in the
# Windows sign-in box, so the password goes on the clipboard for VMConnect's
# Type clipboard text. It is kept out of clipboard history and cloud sync,
# and never written to the output or the warning. The clipboard itself is
# mocked; nothing here touches it.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $secret = 'Correct-Horse-9'
}

Describe 'Get-LazyVMCredential -ToClipboard' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = 'C:\LazyVM' } }
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = 'Alpha'; Settings = @{ CredKeyFile = 'key'; GuestCredFile = 'guest.cred' } } }
        Mock -ModuleName $module Get-StoredCredential { [pscredential]::new('devadmin', [Net.NetworkCredential]::new('', 'Correct-Horse-9').SecurePassword) }
        Mock -ModuleName $module Set-ClipboardSecret { }
    }

    It 'puts the password on the clipboard and returns nothing' {
        $result = @(Get-LazyVMCredential -Name Alpha -ToClipboard -WarningAction SilentlyContinue)

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Set-ClipboardSecret -Times 1 -Exactly -ParameterFilter { $Text -eq $secret }
    }

    It 'warns to clear the clipboard, without the password in the warning' {
        $null = Get-LazyVMCredential -Name Alpha -ToClipboard -WarningVariable warnings -WarningAction SilentlyContinue

        "$warnings" | Should -BeLike '*clear*'
        "$warnings" | Should -Not -BeLike "*$secret*"
    }

    It 'says so when no credential is stored, and leaves the clipboard alone' {
        Mock -ModuleName $module Get-StoredCredential { $null }

        { Get-LazyVMCredential -Name Alpha -ToClipboard } | Should -Throw -ExpectedMessage '*No credential is stored*'

        Should -Invoke -ModuleName $module Set-ClipboardSecret -Times 0
    }
}
