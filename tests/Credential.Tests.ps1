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
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = 'Alpha'; Settings = @{ GuestCredFile = 'guest.cred' } } }
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

Describe 'Get-LazyVMCredential, as the dashboard''s Password window reads it (#469)' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = 'C:\LazyVM' } }
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = 'Alpha'; Settings = @{ GuestCredFile = 'guest.cred' } } }
        Mock -ModuleName $module Get-StoredCredential { [pscredential]::new('devadmin', [Net.NetworkCredential]::new('', 'Correct-Horse-9').SecurePassword) }
        Mock -ModuleName $module Start-Log { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogWarning { }
        Mock -ModuleName $module Write-LogError { }
    }

    It 'gives the user name with the password still encrypted, then the password as text only with -AsPlainText' {
        $credential = Get-LazyVMCredential -Name Alpha
        $plain = Get-LazyVMCredential -Name Alpha -AsPlainText

        $credential | Should -BeOfType [pscredential]
        $credential.UserName | Should -Be 'devadmin'
        $plain.UserName | Should -Be 'devadmin'
        $plain.Password | Should -Be $secret
    }

    It 'writes nothing to the VM''s log, and no warning or verbose text, when it reads the password' {
        $output = @(Get-LazyVMCredential -Name Alpha -AsPlainText -WarningVariable warnings -Verbose 4>&1)
        $verbose = @($output | Where-Object { $_ -is [Management.Automation.VerboseRecord] })

        Should -Invoke -ModuleName $module Start-Log -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogWarning -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogError -Times 0 -Exactly
        "$warnings $verbose" | Should -Not -BeLike "*$secret*"
    }

    It 'says so when no credential is stored, naming Set-LazyVMCredential' {
        Mock -ModuleName $module Get-StoredCredential { $null }

        { Get-LazyVMCredential -Name Alpha } | Should -Throw -ExpectedMessage '*No credential is stored*Set-LazyVMCredential -Name Alpha*'
    }
}
