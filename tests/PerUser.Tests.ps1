# PerUser.Tests.ps1
# LazyVM installed per user (#284): its registry key is under HKCU, its
# folder is open to the installing user and SYSTEM only, and its scheduled
# tasks run as that user. While a machine-wide install from before is still
# there, nothing but Convert-LazyVMInstallation runs. Nothing here changes
# the host: the registry, ACL and Task Scheduler calls are mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
}

Describe 'Where LazyVM records its folder (#284)' {
    It 'is the current user''s registry, not the machine''s' {
        InModuleScope $module { $script:RootRegistryKey } | Should -Be 'HKCU:\SOFTWARE\LazyVM'
    }

    It 'still marks a provisioned guest under HKLM, inside the guest' {
        InModuleScope $module { $script:GuestMarkerKey } | Should -Be 'HKLM:\SOFTWARE\LazyVM'
    }
}

Describe 'A machine-wide install from before (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-LegacyRoot { 'C:\LazyVM' }
    }

    It 'stops every command that looks for the LazyVM folder, naming the migration' {
        { InModuleScope $module { Resolve-LazyVMRoot } } | Should -Throw -ExpectedMessage '*every user*C:\LazyVM*Convert-LazyVMInstallation*'
    }

    It 'stops a first build from setting up a new folder beside it' {
        Mock -ModuleName $module Get-RegisteredRoot { $null }
        Mock -ModuleName $module Get-DefaultRoot { throw 'must not choose a new folder' }

        { InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' } } | Should -Throw -ExpectedMessage '*Convert-LazyVMInstallation*'
    }

    It 'stops Set-LazyVMRoot' {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Set-RegisteredRoot { }

        { Set-LazyVMRoot -Path 'D:\DevVM' -Confirm:$false } | Should -Throw -ExpectedMessage '*Convert-LazyVMInstallation*'

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 0
    }

    It 'is not there once migrated' {
        Mock -ModuleName $module Get-LegacyRoot { $null }

        { InModuleScope $module { Assert-NoLegacyInstallation } } | Should -Not -Throw
    }
}

Describe 'New-RootFolderSecurity (#284)' {
    BeforeAll {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = InModuleScope $module -Parameters @{ User = $user } { param($User) New-RootFolderSecurity -User $User }
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    }

    It 'gives full control to the user and SYSTEM, and to nobody else' {
        @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @(@($user.Value, 'S-1-5-18') | Sort-Object)
        foreach ($rule in $rules) {
            $rule.FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
            "$($rule.AccessControlType)" | Should -Be 'Allow'
        }
    }

    It 'is inherited by everything inside the folder' {
        foreach ($rule in $rules) {
            "$($rule.InheritanceFlags)" | Should -Be 'ContainerInherit, ObjectInherit'
            "$($rule.PropagationFlags)" | Should -Be 'None'
        }
    }

    It 'inherits nothing from the folder above, and is owned by the user' {
        $security.AreAccessRulesProtected | Should -BeTrue
        $security.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be $user.Value
    }
}

Describe 'Initialize-RootFolder (#284)' {
    It 'creates a missing folder already locked' {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Initialize-RootFolder -Path $Path }

        $path | Should -Exist
        (Get-Acl -LiteralPath $path).AreAccessRulesProtected | Should -BeTrue
    }

    It 'locks a folder that is already there, without touching what is in it' {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $path -ChildPath 'keep.txt') -Value 'kept'
        Mock -ModuleName $module Set-Acl { }

        InModuleScope $module -Parameters @{ Path = $path } { param($Path) Initialize-RootFolder -Path $Path }

        Should -Invoke -ModuleName $module Set-Acl -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $path -and $AclObject.AreAccessRulesProtected }
        Get-Content -LiteralPath (Join-Path -Path $path -ChildPath 'keep.txt') | Should -Be 'kept'
    }
}

Describe 'Where the LazyVM folder is locked (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-LegacyRoot { $null }
        Mock -ModuleName $module Initialize-RootFolder { }
        Mock -ModuleName $module Set-RegisteredRoot { }
        Mock -ModuleName $module Initialize-ConfigFolder { }
        Mock -ModuleName $module Get-ConfigDir { 'TestDrive:\Config' }
        Mock -ModuleName $module Assert-Administrator { }
    }

    It 'locks the folder Set-LazyVMRoot chooses' {
        Mock -ModuleName $module Get-RegisteredRoot { $null }

        $null = Set-LazyVMRoot -Path 'D:\DevVM' -Confirm:$false

        Should -Invoke -ModuleName $module Initialize-RootFolder -Times 1 -Exactly -ParameterFilter { $Path -eq 'D:\DevVM' }
    }

    It 'locks the folder a first build chooses' {
        Mock -ModuleName $module Get-RegisteredRoot { $null }
        Mock -ModuleName $module Get-DefaultRoot { 'C:\Users\sean\LazyVM' }
        Mock -ModuleName $module Get-VMProfileName { 'DevBox' }

        InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' } 6> $null

        Should -Invoke -ModuleName $module Initialize-RootFolder -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Users\sean\LazyVM' }
    }
}

Describe 'Get-DefaultRoot (#284)' {
    It 'is LazyVM in the user''s profile folder' {
        $expected = Join-Path -Path ([Environment]::GetFolderPath('UserProfile')) -ChildPath 'LazyVM'

        InModuleScope $module { Get-DefaultRoot } | Should -Be $expected
    }
}

Describe 'Get-RootAccessCheck (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-CurrentUserSid { [pscustomobject]@{ Value = 'S-1-5-21-1-1001' } }
        Mock -ModuleName $module ConvertTo-AccountName { "name of $Sid" }
    }

    It 'is OK when only the user and SYSTEM have access' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $true; Sids = @('S-1-5-21-1-1001', 'S-1-5-18') } }

        $check = InModuleScope $module { Get-RootAccessCheck -Name 'Alpha' -Root 'C:\Users\sean\LazyVM' }

        $check.Status | Should -Be 'OK'
        $check.Check | Should -Be 'LazyVM folder access'
    }

    It 'warns, naming every other account and how to lock it again' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $true; Sids = @('S-1-5-21-1-1001', 'S-1-5-18', 'S-1-5-32-544') } }

        $check = InModuleScope $module { Get-RootAccessCheck -Name 'Alpha' -Root 'C:\Users\sean\LazyVM' }

        $check.Status | Should -Be 'WARN'
        $check.Detail | Should -BeLike '*name of S-1-5-32-544*Set-LazyVMRoot -Path C:\Users\sean\LazyVM*'
    }

    It 'warns when the folder inherits access from the folder above' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $false; Sids = @('S-1-5-21-1-1001', 'S-1-5-18') } }

        $check = InModuleScope $module { Get-RootAccessCheck -Name 'Alpha' -Root 'C:\LazyVM' }

        $check.Status | Should -Be 'WARN'
        $check.Detail | Should -BeLike '*inherits*'
    }
}
