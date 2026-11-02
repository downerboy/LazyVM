# Security.Tests.ps1
# LazyVM's scheduled tasks run as SYSTEM, and read the user's own folder
# (#284). So: the code they run is in a folder only administrators can
# change; the folder they are handed must be the owner's, locked; every
# path a setting names must be inside it or allowed by an administrator;
# no write goes through a reparse point; and nothing a setting says is
# downloaded or opened. Nothing here changes the host: the registry, ACL
# and Task Scheduler calls are mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $owner = 'S-1-5-21-111-222-333-1001'

    function New-TestRoot {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType File -Path (Join-Path -Path $root -ChildPath 'Shared/Config/LazyVM.Settings.json') -Force | Out-Null
        return $root
    }
}

Describe 'What LazyVM downloads and opens (#284)' {
    It 'is a fixed Microsoft address over https, <Name>' -ForEach @(
        @{ Name = 'WindowsIsoDownloadPage' }
        @{ Name = 'SqlIsoUrl' }
    ) {
        $uri = [uri](InModuleScope $module -Parameters @{ Name = $Name } { param($Name) Get-Variable -Name $Name -Scope Script -ValueOnly })

        $uri.Scheme | Should -Be 'https'
        $uri.Host | Should -Match '(^|\.)microsoft\.com$'
    }

    It 'is no longer a setting: <Setting> is retired' -ForEach @(
        @{ Setting = 'SQLIsoUrl' }
        @{ Setting = 'ISODownloadPage' }
    ) {
        InModuleScope $module { $script:RetiredSettingNames } | Should -Contain $Setting
        (InModuleScope $module { Get-SettingsSchema }).properties.PSObject.Properties.Name | Should -Not -Contain $Setting
    }
}

Describe 'The task command (#284)' {
    It 'quotes the LazyVM folder, doubling any single quote' {
        InModuleScope $module -Parameters @{ Owner = $owner } {
            param($Owner)
            Get-HostTaskCommand -TaskName 'LazyVM-Maintain-Alpha' -Root "C:\Users\o'neil\LazyVM" -OwnerSid $Owner
        } | Should -Be "Invoke-LazyVMMaintenance -Name 'Alpha' -Root 'C:\Users\o''neil\LazyVM' -OwnerSid '$owner'"
    }

    It 'refuses an owner that is not a security identifier' {
        { InModuleScope $module { Get-HostTaskCommand -TaskName 'LazyVM-Maintain-Alpha' -Root 'C:\LazyVM' -OwnerSid "S-1-5'; Remove-Item C:\" } } |
            Should -Throw -ExpectedMessage '*not a security identifier*'
    }

    It 'is never handed a LazyVM folder with a single quote in its name' {
        { InModuleScope $module { Resolve-SettingsRoot -Path "C:\Users\o'neil\LazyVM" -Source 'a test' } } | Should -Throw -ExpectedMessage '*must be a folder on a local drive*'
    }
}

Describe 'Assert-RootLocked, for the folder a task is handed (#284)' {
    BeforeEach {
        $root = New-TestRoot
        Mock -ModuleName $module Test-ReparsePoint { $false }
    }

    It 'accepts the owner''s LazyVM folder, open to the owner and SYSTEM only' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $true; Sids = @('S-1-5-21-111-222-333-1001', 'S-1-5-18') } }

        { InModuleScope $module -Parameters @{ Root = $root; Owner = $owner } { param($Root, $Owner) Assert-RootLocked -Root $Root -OwnerSid $Owner } } | Should -Not -Throw
    }

    It 'refuses a folder locked to another account than the owner named' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $true; Sids = @('S-1-5-21-999-999-999-1002', 'S-1-5-18') } }

        { InModuleScope $module -Parameters @{ Root = $root; Owner = $owner } { param($Root, $Owner) Assert-RootLocked -Root $Root -OwnerSid $Owner } } |
            Should -Throw -ExpectedMessage '*not locked to its owner*'
    }

    It 'refuses a folder that is a reparse point' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $true; Sids = @('S-1-5-21-111-222-333-1001', 'S-1-5-18') } }
        Mock -ModuleName $module Test-ReparsePoint { $true }

        { InModuleScope $module -Parameters @{ Root = $root; Owner = $owner } { param($Root, $Owner) Assert-RootLocked -Root $Root -OwnerSid $Owner } } |
            Should -Throw -ExpectedMessage '*reparse point*'
    }

    It 'checks against the owner named with -OwnerSid, or else the account running LazyVM' -ForEach @(
        @{ Given = 'S-1-5-21-111-222-333-1001'; Expected = 'S-1-5-21-111-222-333-1001' }
        @{ Given = $null; Expected = 'S-1-5-21-5-6-7-1003' }
    ) {
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }
        Mock -ModuleName $module Get-CurrentUserSid { [pscustomobject]@{ Value = 'S-1-5-21-5-6-7-1003' } }
        Mock -ModuleName $module Assert-RootLocked { }

        InModuleScope $module -Parameters @{ Given = $Given } { param($Given) $null = Resolve-LazyVMRoot -Root 'D:\DevVM' -OwnerSid $Given }

        Should -Invoke -ModuleName $module Assert-RootLocked -Times 1 -Exactly -ParameterFilter { $OwnerSid -eq $Expected }
    }
}

Describe 'Assert-NoReparsePoint (#284)' {
    BeforeEach {
        $root = New-TestRoot
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Alpha/Logs') -Force | Out-Null
    }

    It 'goes on when no folder from the LazyVM folder down is a reparse point' {
        Mock -ModuleName $module Test-ReparsePoint { $false }

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Assert-NoReparsePoint -Path (Join-Path -Path $Root -ChildPath 'Alpha/Logs/Alpha.log') -Root $Root } } | Should -Not -Throw
    }

    It 'refuses a path through a reparse point, such as a junction to a system folder' {
        $script:alpha = Join-Path -Path $root -ChildPath 'Alpha'
        Mock -ModuleName $module Test-ReparsePoint { $Path -eq $script:alpha }

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Assert-NoReparsePoint -Path (Join-Path -Path $Root -ChildPath 'Alpha/Logs/Alpha.log') -Root $Root } } |
            Should -Throw -ExpectedMessage '*Alpha is a reparse point*'
    }

    It 'leaves a path outside the LazyVM folder alone' {
        Mock -ModuleName $module Test-ReparsePoint { $true }

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Assert-NoReparsePoint -Path 'E:\Backups\Alpha-User.vhdx' -Root $Root } } | Should -Not -Throw
    }

    It 'guards <Helper>, which every write under the LazyVM folder goes through' -ForEach @(
        @{ Helper = 'New-Folder' }
        @{ Helper = 'Write-TextFileAtomic' }
    ) {
        Mock -ModuleName $module Test-ReparsePoint { $true }

        { InModuleScope $module -Parameters @{ Root = $root; Helper = $Helper } {
                param($Root, $Helper)
                $script:RunRoot = $Root
                try {
                    switch ($Helper) {
                        'New-Folder' { New-Folder -Path (Join-Path -Path $Root -ChildPath 'Alpha/State') }
                        'Write-TextFileAtomic' { Write-TextFileAtomic -Path (Join-Path -Path $Root -ChildPath 'Alpha/Config/VM.json') -Text '{}' }
                    }
                }
                finally { $script:RunRoot = $null }
            } } | Should -Throw -ExpectedMessage '*reparse point*'
    }
}

Describe 'The paths a VM''s settings name (#284)' {
    BeforeAll {
        $settings = @{
            VMName    = 'Alpha'
            Root      = 'C:\Users\sean\LazyVM'
            DiskDir   = 'C:\Users\sean\LazyVM\Alpha\Disks'
            LogFile   = 'C:\Users\sean\LazyVM\Alpha\Logs\Alpha.log'
            BackupDir = 'E:\Backups'
            StateDir  = 'C:\Windows\System32\State'
        }
    }

    It 'lists those outside the LazyVM folder' {
        $outside = @(InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Get-OutsideHostPath -Settings $Settings })

        @($outside.Name | Sort-Object) | Should -Be @('BackupDir', 'StateDir')
    }

    It 'stops an unattended run when one is outside the folder and not allowed by an administrator' {
        Mock -ModuleName $module Get-TrustedHostPath { @('E:\Backups') }

        { InModuleScope $module -Parameters @{ Settings = $settings; Owner = $owner } { param($Settings, $Owner) Assert-HostPathTrusted -Settings $Settings -OwnerSid $Owner } } |
            Should -Throw -ExpectedMessage '*StateDir*C:\Windows\System32\State*Register-LazyVMMaintenance -Name Alpha*'
    }

    It 'lets an unattended run go on when every outside path is allowed' {
        Mock -ModuleName $module Get-TrustedHostPath { @('E:\Backups', 'C:\Windows\System32\State') }

        { InModuleScope $module -Parameters @{ Settings = $settings; Owner = $owner } { param($Settings, $Owner) Assert-HostPathTrusted -Settings $Settings -OwnerSid $Owner } } | Should -Not -Throw
        Should -Invoke -ModuleName $module Get-TrustedHostPath -ParameterFilter { $OwnerSid -eq $owner }
    }

    It 'allows the outside paths for the owner when the owner, elevated, schedules or builds the VM' {
        Mock -ModuleName $module Get-CurrentUserSid { [pscustomobject]@{ Value = 'S-1-5-21-111-222-333-1001' } }
        Mock -ModuleName $module Add-TrustedHostPath { }

        InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Register-TrustedHostPath -Settings $Settings }

        Should -Invoke -ModuleName $module Add-TrustedHostPath -Times 1 -Exactly -ParameterFilter {
            $OwnerSid -eq 'S-1-5-21-111-222-333-1001' -and @($Path | Sort-Object) -join '|' -eq 'C:\Windows\System32\State|E:\Backups'
        }
    }

    It 'keeps the allowed paths where only an administrator can write: HKLM, under the owner' {
        InModuleScope $module -Parameters @{ Owner = $owner } { param($Owner) Get-TrustedHostPathKey -OwnerSid $Owner } |
            Should -Be "HKLM:\SOFTWARE\LazyVM\$owner\HostPaths"
    }
}

Describe 'The code the tasks run (#284)' {
    It 'is trusted only when nobody but administrators, SYSTEM and TrustedInstaller can change it' {
        $rules = @(
            [pscustomobject]@{ Sid = 'S-1-5-32-544'; Rights = 2032127; InheritOnly = $false }
            [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = 2032127; InheritOnly = $false }
            [pscustomobject]@{ Sid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Rights = 2032127; InheritOnly = $false }
            [pscustomobject]@{ Sid = 'S-1-5-21-111-222-333-1001'; Rights = 1179817; InheritOnly = $false }
            [pscustomobject]@{ Sid = 'S-1-3-0'; Rights = 268435456; InheritOnly = $true }
        )

        InModuleScope $module -Parameters @{ Rules = $rules } { param($Rules) Get-UntrustedWriter -Rule $Rules } | Should -BeNullOrEmpty
    }

    It 'is not trusted when <Case> can change it' -ForEach @(
        @{ Case = 'the user (Modify)'; Rule = [pscustomobject]@{ Sid = 'S-1-5-21-111-222-333-1001'; Rights = 1245631; InheritOnly = $false } }
        @{ Case = 'Users (create files)'; Rule = [pscustomobject]@{ Sid = 'S-1-5-32-545'; Rights = 2; InheritOnly = $false } }
        @{ Case = 'Everyone (generic write)'; Rule = [pscustomobject]@{ Sid = 'S-1-1-0'; Rights = 1073741824; InheritOnly = $false } }
    ) {
        InModuleScope $module -Parameters @{ Rule = $Rule } { param($Rule) Get-UntrustedWriter -Rule @($Rule) } | Should -Be $Rule.Sid
    }

    It 'is checked before a task is registered, so SYSTEM never runs code a user could change' {
        Mock -ModuleName $module Assert-TrustedCode { throw 'can be changed by S-1-5-32-545' }
        Mock -ModuleName $module Register-ScheduledTask { }
        # Real task parts: Register-LazyVMHostTask's parameters take only these.
        $parts = @{ Action = New-ScheduledTaskAction -Execute 'pwsh.exe'; Trigger = New-ScheduledTaskTrigger -AtStartup; Settings = New-ScheduledTaskSettingsSet }

        { InModuleScope $module -Parameters @{ Parts = $parts } { param($Parts) Register-LazyVMHostTask -TaskName 'LazyVM-Maintain-Alpha' @Parts } } | Should -Throw -ExpectedMessage '*S-1-5-32-545*'
        Should -Invoke -ModuleName $module Register-ScheduledTask -Times 0
    }

    It 'covers the module, the folder the tasks import it from, and PowerShell itself' {
        Mock -ModuleName $module Get-LazyVMModuleBase { 'C:\Program Files\LazyVM\Modules\LazyVM\6.0.0' }
        Mock -ModuleName $module Assert-TrustedFolder { }

        InModuleScope $module { Assert-TrustedCode }

        Should -Invoke -ModuleName $module Assert-TrustedFolder -ParameterFilter { $Path -eq 'C:\Program Files\LazyVM\Modules\LazyVM\6.0.0' }
        Should -Invoke -ModuleName $module Assert-TrustedFolder -ParameterFilter { $Path -eq 'C:\Program Files\LazyVM\Modules\LazyVM' }
        Should -Invoke -ModuleName $module Assert-TrustedFolder -ParameterFilter { $Path -eq $PSHOME }
    }

    It 'is reported by Test-LazyVM' {
        Mock -ModuleName $module Assert-TrustedCode { throw 'can be changed by S-1-5-32-545' }

        $check = InModuleScope $module { Get-TrustedCodeCheck -Name 'Alpha' }

        $check.Status | Should -Be 'FAIL'
        $check.Detail | Should -BeLike '*S-1-5-32-545*Install.ps1*'
    }

    It 'is installed in Program Files, where only administrators can change it' {
        InModuleScope $module { Get-InstalledModuleFolder } | Should -Be (Join-Path -Path $env:ProgramFiles -ChildPath 'LazyVM/Modules')
    }
}
