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
        Mock -ModuleName $module Get-UserProfileLocation { [pscustomobject]@{ Profile = 'C:\Users\sean'; ProfilesRoot = 'C:\Users' } }
        Mock -ModuleName $module Add-TrustedHostPath { }

        $ownSettings = $settings.Clone()
        $ownSettings.StateDir = 'D:\State'

        InModuleScope $module -Parameters @{ Settings = $ownSettings } { param($Settings) Register-TrustedHostPath -Settings $Settings -Confirm:$false }

        Should -Invoke -ModuleName $module Add-TrustedHostPath -Times 1 -Exactly -ParameterFilter {
            $OwnerSid -eq 'S-1-5-21-111-222-333-1001' -and @($Path | Sort-Object) -join '|' -eq 'D:\State|E:\Backups'
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

    It 'covers the folders above the module, up to LazyVM in Program Files' {
        Mock -ModuleName $module Get-LazyVMModuleBase { Join-Path -Path $env:ProgramFiles -ChildPath 'LazyVM\Modules\LazyVM\6.0.0' }
        Mock -ModuleName $module Assert-TrustedFolder { }

        InModuleScope $module { Assert-TrustedCode }

        Should -Invoke -ModuleName $module Assert-TrustedFolder -ParameterFilter { $Path -eq (Join-Path -Path $env:ProgramFiles -ChildPath 'LazyVM\Modules') }
        Should -Invoke -ModuleName $module Assert-TrustedFolder -ParameterFilter { $Path -eq (Join-Path -Path $env:ProgramFiles -ChildPath 'LazyVM') }
        Should -Invoke -ModuleName $module Assert-TrustedFolder -Times 0 -ParameterFilter { $Path -eq $env:ProgramFiles }
    }

    It 'refuses a folder owned by anyone but administrators, SYSTEM and TrustedInstaller' {
        Mock -ModuleName $module Get-FolderWriteRule { }
        Mock -ModuleName $module Get-PathOwnerSid { 'S-1-5-21-111-222-333-1001' }
        Mock -ModuleName $module ConvertTo-AccountName { 'MIKEPC\sean' }

        { InModuleScope $module { Assert-TrustedFolder -Path 'C:\Program Files\LazyVM' } } | Should -Throw -ExpectedMessage '*owned by MIKEPC\sean*'
    }

    It 'is reported by Test-LazyVM' {
        Mock -ModuleName $module Assert-TrustedCode { throw 'can be changed by S-1-5-32-545' }

        $check = InModuleScope $module { Get-TrustedCodeCheck -Name 'Alpha' }

        $check.Status | Should -Be 'FAIL'
        $check.Detail | Should -BeLike '*S-1-5-32-545*Install.ps1*'
    }

    It 'is installed in Program Files, where only administrators can change it' {
        Mock -ModuleName $module Get-ProgramFilesFolder { $TestDrive }

        InModuleScope $module { Get-InstalledModuleFolder } | Should -Be (Join-Path -Path $TestDrive -ChildPath 'LazyVM/Modules')
    }

    It 'asks Windows where Program Files is, not the environment, which the user can change' -Skip:(-not $IsWindows) {
        $saved = $env:ProgramFiles
        $env:ProgramFiles = $TestDrive
        try { InModuleScope $module { Get-ProgramFilesFolder } | Should -Be ([Environment]::GetFolderPath('ProgramFiles')) }
        finally { $env:ProgramFiles = $saved }
    }
}

Describe 'A path that climbs out of the LazyVM folder (#284)' {
    It 'is never taken as inside it: <Path>' -ForEach @(
        @{ Path = 'C:\Users\sean\LazyVM\..\..\..\Windows\System32' }
        @{ Path = 'C:\Users\sean\LazyVM\Alpha\..\..\Other' }
    ) {
        InModuleScope $module -Parameters @{ Path = $Path } { param($Path) Test-PathWithin -Path $Path -Folder 'C:\Users\sean\LazyVM' } | Should -BeFalse
    }

    It 'is still inside it when it only looks out and back: C:\Users\sean\LazyVM\Alpha\..\Beta' {
        InModuleScope $module { Test-PathWithin -Path 'C:\Users\sean\LazyVM\Alpha\..\Beta' -Folder 'C:\Users\sean\LazyVM' } | Should -BeTrue
    }

    It 'is refused in a setting, in the <Form> form: <Value>' -ForEach @(
        @{ Form = 'relative'; Name = 'LogFile'; Value = '..\..\Windows\System32\x.log' }
        @{ Form = 'relative'; Name = 'StateDir'; Value = 'Alpha\.\State' }
        @{ Form = 'relative'; Name = 'StateDir'; Value = '.\..\State' }
        @{ Form = 'full'; Name = 'DiskDir'; Value = 'C:\Users\X\LazyVM\..\..\..\Windows' }
    ) {
        $settings = @{ $Name = $Value }
        foreach ($other in @(InModuleScope $module { $script:HostPathSettings } | Where-Object { $_ -ne $Name })) { $settings[$other] = 'Shared\x' }

        { InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Resolve-HostPathSetting -Settings $Settings -Root 'C:\Users\sean\LazyVM' } } |
            Should -Throw -ExpectedMessage "*'$Name'*'.' or '..'*"
    }

    It 'is refused by the settings schema too, as VS Code shows it: <Name> = <Value>' -ForEach @(
        @{ Name = 'LogFile'; Value = '..\\..\\Windows\\x.log' }
        @{ Name = 'DiskDir'; Value = 'C:\\Users\\X\\LazyVM\\..\\..\\Windows' }
        @{ Name = 'BackupDir'; Value = 'F:\\Backup\\..\\..\\Windows' }
        @{ Name = 'StateDir'; Value = '.\\..\\Windows' }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid().ToString('N')).json"
        Set-Content -LiteralPath $path -Value "{ `"$Name`": `"$Value`" }"

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Read-SettingsFile -Path $Path } } | Should -Throw -ExpectedMessage "*$Name*"
    }
}

Describe 'A task name that is not a VM''s (#284)' {
    It 'gets no command: <TaskName>' -ForEach @(
        @{ TaskName = "LazyVM-Maintain-x';Remove-Item C:\;'" }
        @{ TaskName = 'LazyVM-Maintain-Shared' }
    ) {
        { InModuleScope $module -Parameters @{ TaskName = $TaskName; Owner = $owner } { param($TaskName, $Owner) Get-HostTaskCommand -TaskName $TaskName -Root 'C:\LazyVM' -OwnerSid $Owner } } |
            Should -Throw -ExpectedMessage '*not a VM name*'
    }

    It 'is left alone by the migration, which says so' {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Register-LazyVMHostTask { }
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = "LazyVM-Maintain-x';Remove-Item C:\;'"; Triggers = @(); Settings = $null } }

        InModuleScope $module { Update-LegacyTask -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*not a VM name*left as it was*' }
    }
}

Describe 'Allowing a place outside the LazyVM folder (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-CurrentUserSid { [pscustomobject]@{ Value = 'S-1-5-21-111-222-333-1001' } }
        Mock -ModuleName $module Get-UserProfileLocation { [pscustomobject]@{ Profile = 'C:\Users\sean'; ProfilesRoot = 'C:\Users' } } -ParameterFilter { $Sid -eq 'S-1-5-21-111-222-333-1001' }
        Mock -ModuleName $module Get-TrustedHostPath { @() }
        Mock -ModuleName $module Add-TrustedHostPath { }
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'asks first, as a high-impact change, naming each new place' {
        $command = InModuleScope $module { Get-Command -Name Register-TrustedHostPath }
        $binding = $command.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

        "$($binding.ConfirmImpact)" | Should -Be 'High'
        $binding.SupportsShouldProcess | Should -BeTrue
    }

    It 'allows nothing with -WhatIf' {
        InModuleScope $module { Register-TrustedHostPath -Settings @{ VMName = 'Alpha'; Root = 'C:\Users\sean\LazyVM'; BackupDir = 'E:\Backups' } -WhatIf }

        Should -Invoke -ModuleName $module Add-TrustedHostPath -Times 0
    }

    It 'allows a new place once confirmed' {
        InModuleScope $module { Register-TrustedHostPath -Settings @{ VMName = 'Alpha'; Root = 'C:\Users\sean\LazyVM'; BackupDir = 'E:\Backups' } -Confirm:$false }

        Should -Invoke -ModuleName $module Add-TrustedHostPath -Times 1 -Exactly -ParameterFilter { @($Path) -join '|' -eq 'E:\Backups' }
    }

    It 'does not ask again for a place already allowed' {
        Mock -ModuleName $module Get-TrustedHostPath { @('E:\Backups') }

        InModuleScope $module { Register-TrustedHostPath -Settings @{ VMName = 'Alpha'; Root = 'C:\Users\sean\LazyVM'; BackupDir = 'E:\Backups' } -Confirm:$false }

        Should -Invoke -ModuleName $module Add-TrustedHostPath -Times 0
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a drive''s root'; Path = 'E:\' }
        @{ Case = 'the Windows folder'; Path = (Join-Path -Path $env:SystemRoot -ChildPath 'Temp') }
        @{ Case = 'Program Files'; Path = (Join-Path -Path $env:ProgramFiles -ChildPath 'Contoso') }
        @{ Case = 'ProgramData'; Path = (Join-Path -Path $env:ProgramData -ChildPath 'Contoso') }
        @{ Case = 'another user''s profile'; Path = 'C:\Users\kim\Backups' }
    ) {
        $settings = @{ VMName = 'Alpha'; Root = 'D:\DevVM'; BackupDir = $Path }

        { InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Register-TrustedHostPath -Settings $Settings -Confirm:$false } } |
            Should -Throw -ExpectedMessage '*cannot be allowed*'
        Should -Invoke -ModuleName $module Add-TrustedHostPath -Times 0
    }

    It 'refuses <Case> even when the environment names another folder for it' -Skip:(-not $IsWindows) -ForEach @(
        @{ Case = 'the Windows folder'; Variable = 'SystemRoot'; Folder = 'Windows' }
        @{ Case = 'Program Files'; Variable = 'ProgramFiles'; Folder = 'ProgramFiles' }
        @{ Case = 'ProgramData'; Variable = 'ProgramData'; Folder = 'CommonApplicationData' }
    ) {
        $saved = [Environment]::GetEnvironmentVariable($Variable)
        [Environment]::SetEnvironmentVariable($Variable, 'Q:\Elsewhere')
        try {
            $reason = InModuleScope $module -Parameters @{ Path = (Join-Path -Path ([Environment]::GetFolderPath($Folder)) -ChildPath 'Contoso') } { param($Path) Get-ForbiddenHostPathReason -Path $Path -OwnerSid 'S-1-5-21-111-222-333-1001' }
            $reason | Should -Not -BeNullOrEmpty
        }
        finally { [Environment]::SetEnvironmentVariable($Variable, $saved) }
    }

    It 'allows a place in the owner''s own profile, which Windows records for their security identifier' {
        $reason = InModuleScope $module { Get-ForbiddenHostPathReason -Path 'C:\Users\sean\Backups' -OwnerSid 'S-1-5-21-111-222-333-1001' }

        $reason | Should -BeNullOrEmpty
    }

    It 'refuses another user''s profile even when USERPROFILE names it (#311)' {
        $saved = $env:USERPROFILE
        $env:USERPROFILE = 'C:\Users\kim'
        try { $reason = InModuleScope $module { Get-ForbiddenHostPathReason -Path 'C:\Users\kim\Backups' -OwnerSid 'S-1-5-21-111-222-333-1001' } }
        finally { $env:USERPROFILE = $saved }

        $reason | Should -BeLike '*C:\Users*not in your own profile*'
    }
}

Describe 'Get-UserProfileLocation (#311)' {
    It 'reads <Case> from ProfileList, working out <Variable> from the Windows folder' -ForEach @(
        @{ Case = 'the profile'; Variable = '%SystemDrive%'; Image = '%SystemDrive%\Users\sean'; Directory = 'C:\Users'; Profile = 'C:\Users\sean'; Root = 'C:\Users' }
        @{ Case = 'the profiles folder'; Variable = '%SystemRoot%'; Image = 'D:\Profiles\sean'; Directory = '%SystemRoot%\..\Profiles'; Profile = 'D:\Profiles\sean'; Root = 'C:\Windows\..\Profiles' }
    ) {
        Mock -ModuleName $module Get-WindowsFolder { 'C:\Windows' }
        Mock -ModuleName $module Get-RegistryText { $Image } -ParameterFilter { $Key -like '*\ProfileList\S-1-5-21-111-222-333-1001' -and $Name -eq 'ProfileImagePath' }
        Mock -ModuleName $module Get-RegistryText { $Directory } -ParameterFilter { $Key -like '*\ProfileList' -and $Name -eq 'ProfilesDirectory' }

        $location = InModuleScope $module { Get-UserProfileLocation -Sid 'S-1-5-21-111-222-333-1001' }

        $location.Profile | Should -Be $Profile
        $location.ProfilesRoot | Should -Be $Root
    }

    It 'refuses a value that names any other environment variable, which the user could change' {
        Mock -ModuleName $module Get-WindowsFolder { 'C:\Windows' }
        Mock -ModuleName $module Get-RegistryText { '%USERPROFILE%' } -ParameterFilter { $Name -eq 'ProfileImagePath' }
        Mock -ModuleName $module Get-RegistryText { 'C:\Users' } -ParameterFilter { $Name -eq 'ProfilesDirectory' }

        { InModuleScope $module { Get-UserProfileLocation -Sid 'S-1-5-21-111-222-333-1001' } } | Should -Throw -ExpectedMessage '*%USERPROFILE%*'
    }

    It 'refuses an account Windows has no profile for' {
        Mock -ModuleName $module Get-RegistryText { $null }

        { InModuleScope $module { Get-UserProfileLocation -Sid 'S-1-5-21-111-222-333-1001' } } | Should -Throw -ExpectedMessage '*S-1-5-21-111-222-333-1001*'
    }

    It 'finds the signed-in user''s own profile whatever USERPROFILE says' -Skip:(-not $IsWindows) {
        $expected = [Environment]::GetFolderPath('UserProfile')
        $saved = $env:USERPROFILE
        $env:USERPROFILE = 'Q:\Elsewhere'
        try { $location = InModuleScope $module { Get-UserProfileLocation -Sid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) } }
        finally { $env:USERPROFILE = $saved }

        $location.Profile | Should -Be $expected
    }
}

Describe 'Assert-NoReparsePoint fails closed (#284)' {
    It 'refuses, running as SYSTEM, a write that is in neither the LazyVM folder nor an allowed place' {
        Mock -ModuleName $module Test-RunningAsSystem { $true }

        { InModuleScope $module { Assert-NoReparsePoint -Path 'C:\Windows\System32\x.dll' -Root 'C:\Users\sean\LazyVM' -Allowed @('E:\Backups') } } |
            Should -Throw -ExpectedMessage '*not in the LazyVM folder*'
    }

    It 'refuses, running as SYSTEM, when no LazyVM folder is known at all' {
        Mock -ModuleName $module Test-RunningAsSystem { $true }

        { InModuleScope $module { $script:RunRoot = $null; Assert-NoReparsePoint -Path 'C:\Users\sean\LazyVM\Alpha\Config\VM.json' } } |
            Should -Throw -ExpectedMessage '*not in the LazyVM folder*'
    }

    It 'walks from the allowed place a path outside the folder is in' {
        $allowed = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $allowed -ChildPath 'Alpha') -Force | Out-Null
        $script:alphaCopy = Join-Path -Path $allowed -ChildPath 'Alpha'
        Mock -ModuleName $module Test-ReparsePoint { $Path -eq $script:alphaCopy }

        { InModuleScope $module -Parameters @{ Allowed = $allowed } { param($Allowed) Assert-NoReparsePoint -Path (Join-Path -Path $Allowed -ChildPath 'Alpha/Alpha-User.vhdx') -Root 'C:\Users\sean\LazyVM' -Allowed @($Allowed) } } |
            Should -Throw -ExpectedMessage '*Alpha is a reparse point*'
    }

    It 'lets the run''s own temporary folder be written' {
        Mock -ModuleName $module Test-RunningAsSystem { $true }
        Mock -ModuleName $module Test-ReparsePoint { $false }

        { InModuleScope $module { Assert-NoReparsePoint -Path (Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'LazyVM-1/autounattend.xml') -Root 'C:\Users\sean\LazyVM' } } | Should -Not -Throw
    }

    It 'is known to the first build before its command run starts' {
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType File -Path (Join-Path -Path $root -ChildPath 'DevBox/Config/VM.json') -Force | Out-Null
        Mock -ModuleName $module Get-RegisteredRoot { $root }.GetNewClosure() -ParameterFilter { -not $Key }

        $known = InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' 6> $null; $script:RunRoot }

        $known | Should -Be $root
    }
}

Describe 'Deletes, moves and copies under the LazyVM folder (#284)' {
    BeforeEach {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Alpha') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/a.txt') -Value 'a'
        Mock -ModuleName $module Test-ReparsePoint { $true }
    }

    It '<Helper> checks for reparse points first' -ForEach @(
        @{ Helper = 'Remove-CheckedItem' }
        @{ Helper = 'Move-CheckedItem' }
        @{ Helper = 'Copy-CheckedItem' }
    ) {
        { InModuleScope $module -Parameters @{ Root = $root; Helper = $Helper } {
                param($Root, $Helper)
                $script:RunRoot = $Root
                try {
                    $file = Join-Path -Path $Root -ChildPath 'Alpha/a.txt'
                    $other = Join-Path -Path $Root -ChildPath 'Alpha/b.txt'
                    switch ($Helper) {
                        'Remove-CheckedItem' { Remove-CheckedItem -Path $file }
                        'Move-CheckedItem' { Move-CheckedItem -Path $file -Destination $other }
                        'Copy-CheckedItem' { Copy-CheckedItem -Path $file -Destination $other }
                    }
                }
                finally { $script:RunRoot = $null }
            } } | Should -Throw -ExpectedMessage '*reparse point*'
        Join-Path -Path $root -ChildPath 'Alpha/a.txt' | Should -Exist
    }

    It 'are what <File> uses on the host, not Remove-Item, Move-Item or Copy-Item' -ForEach @(
        @{ File = 'Capture/Capture.ps1' }
        @{ File = 'Maintenance/Rebuild.ps1' }
        @{ File = 'Settings/ProfileHistory.ps1' }
        @{ File = 'Settings/ToolingMigration.ps1' }
        @{ File = 'Disks/UserDiskBackup.ps1' }
        @{ File = 'Host/InstallMedia.ps1' }
    ) {
        # Script blocks run in the guest, through Invoke-GuestScript, are not the host's.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $script:LazyVMModuleDir -ChildPath "Private/$File"), [ref]$null, [ref]$null)
        $onHost = @($ast.FindAll({
                    param($node)
                    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.GetCommandName() -notin 'Remove-Item', 'Move-Item', 'Copy-Item') { return $false }
                    for ($parent = $node.Parent; $parent; $parent = $parent.Parent) {
                        if ($parent -is [System.Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -eq 'Invoke-GuestScript') { return $false }
                    }
                    return $true
                }, $true))

        @($onHost | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }) | Should -BeNullOrEmpty
    }
}

Describe 'Initialize-CommandRun checks the settings it ends up with (#284)' {
    It 'checks the paths of the settings as read the last time' {
        InModuleScope $module {
            $text = (Get-Command -Name Initialize-CommandRun).Definition
            ([regex]::Matches($text, 'Read-VMSetting\b')).Count | Should -Be 0
            ([regex]::Matches($text, 'Read-TrustedVMSetting\b')).Count | Should -BeGreaterThan 1
        }
    }

    It 'Read-TrustedVMSetting checks the paths in an unattended run' {
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ Settings = @{ VMName = 'Alpha'; Root = 'C:\LazyVM' } } }
        Mock -ModuleName $module Test-Unattended { $true }
        Mock -ModuleName $module Assert-HostPathTrusted { throw 'outside' }

        { InModuleScope $module -Parameters @{ Owner = $owner } { param($Owner) Read-TrustedVMSetting -Root 'C:\LazyVM' -VMName 'Alpha' -OwnerSid $Owner } } | Should -Throw -ExpectedMessage '*outside*'
    }
}
