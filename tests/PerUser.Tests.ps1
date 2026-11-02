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
        Mock -ModuleName $module Get-RegisteredRoot { 'C:\LazyVM' } -ParameterFilter { $Key -like 'HKLM:*' }
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
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }

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
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }
        Mock -ModuleName $module Initialize-RootFolder { }
        Mock -ModuleName $module Set-RegisteredRoot { }
        Mock -ModuleName $module Initialize-ConfigFolder { }
        Mock -ModuleName $module Assert-RootFolderUsable { }
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

    It 'fails, rather than stopping the other checks, when the access cannot be read' {
        Mock -ModuleName $module Get-RootAccess { throw 'Access is denied.' }

        $check = InModuleScope $module { Get-RootAccessCheck -Name 'Alpha' -Root 'C:\LazyVM' }

        $check.Status | Should -Be 'FAIL'
        $check.Detail | Should -BeLike '*Access is denied*'
    }

    It 'warns when the folder inherits access from the folder above' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $false; Sids = @('S-1-5-21-1-1001', 'S-1-5-18') } }

        $check = InModuleScope $module { Get-RootAccessCheck -Name 'Alpha' -Root 'C:\LazyVM' }

        $check.Status | Should -Be 'WARN'
        $check.Detail | Should -BeLike '*inherits*'
    }
}

Describe 'Register-LazyVMHostTask (#284)' {
    BeforeAll {
        # Real task parts: Register-ScheduledTask's parameters take only these.
        $parts = @{
            Action   = New-ScheduledTaskAction -Execute 'pwsh.exe'
            Trigger  = New-ScheduledTaskTrigger -AtStartup
            Settings = New-ScheduledTaskSettingsSet
        }
    }

    It 'registers the task as SYSTEM, elevated, with no password, replacing one of the same name' {
        Mock -ModuleName $module Register-ScheduledTask { }

        InModuleScope $module -Parameters @{ Parts = $parts } { param($Parts) Register-LazyVMHostTask -TaskName 'LazyVM-Maintain-Alpha' @Parts }

        Should -Invoke -ModuleName $module Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-Maintain-Alpha' -and $Principal.UserId -eq 'SYSTEM' -and "$($Principal.LogonType)" -eq 'ServiceAccount' -and "$($Principal.RunLevel)" -eq 'Highest' -and $Force
        }
    }
}
Describe 'Get-HostTaskCommand (#284)' {
    It 'is the command <TaskName> runs, naming the LazyVM folder' -ForEach @(
        @{ TaskName = 'LazyVM-Maintain-Alpha'; Expected = "Invoke-LazyVMMaintenance -Name 'Alpha' -Root 'C:\Users\sean\LazyVM'" }
        @{ TaskName = 'LazyVM-ResumeAfterReboot-Alpha'; Expected = "Build-LazyVM -Name 'Alpha' -Root 'C:\Users\sean\LazyVM'" }
        @{ TaskName = 'LazyVM-Something-Else'; Expected = $null }
    ) {
        InModuleScope $module -Parameters @{ TaskName = $TaskName } { param($TaskName) Get-HostTaskCommand -TaskName $TaskName -Root 'C:\Users\sean\LazyVM' } | Should -Be $Expected
    }
}
Describe 'The host tasks (#284)' {
    BeforeAll {
        $testVM = InModuleScope $module {
            $settings = @{
                VMName               = 'Alpha'
                MaintenanceTime      = '02:00'
                RebuildThresholdDays = 10
                ScheduleTaskName     = 'LazyVM-Maintain-Alpha'
                ResumeTaskName       = 'LazyVM-ResumeAfterReboot-Alpha'
                ResumeFile           = 'C:\Users\sean\LazyVM\Alpha\Config\Resume.json'
                Root                 = 'C:\Users\sean\LazyVM'
            }
            [VMContext]::new($settings)
        }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Assert-GuestCredential { }
        Mock -ModuleName $module Register-LazyVMHostTask { }
    }

    It 'registers the daily maintenance, naming the LazyVM folder, without needing a guest credential yet (a build schedules it first)' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Register-RebuildSchedule -VM $VM }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-Maintain-Alpha' -and "$(@($Action)[0].Arguments)" -like "*Invoke-LazyVMMaintenance -Name 'Alpha' -Root 'C:\Users\sean\LazyVM'*"
        }
        Should -Invoke -ModuleName $module Assert-GuestCredential -Times 0
    }

    It 'registers the task that resumes a build after a restart, naming the LazyVM folder' {
        Mock -ModuleName $module Set-ResumePhase { }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Register-ResumeTask -VM $VM -Phase 3 }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-ResumeAfterReboot-Alpha' -and "$(@($Action)[0].Arguments)" -like "*Build-LazyVM -Name 'Alpha' -Root 'C:\Users\sean\LazyVM'*"
        }
    }
}

Describe 'Register-LazyVMMaintenance (#284)' {
    BeforeAll {
        $script:scheduledVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; ScheduleTaskName = 'LazyVM-Maintain-Alpha'; MaintenanceTime = '02:00' }) }
    }

    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-CommandRun { $script:scheduledVM }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Register-RebuildSchedule { }
    }

    It 'refuses to schedule a VM with no stored guest credential, which its runs could not sign in with' {
        Mock -ModuleName $module Assert-GuestCredential { throw 'No guest credential is stored' }
        Mock -ModuleName $module Write-LogError { }

        { Register-LazyVMMaintenance -Name Alpha -Confirm:$false } | Should -Throw -ExpectedMessage '*No guest credential*'

        Should -Invoke -ModuleName $module Register-RebuildSchedule -Times 0
    }
}

Describe 'Build-LazyVM schedules the maintenance first (#284)' {
    BeforeAll {
        $script:builtVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; LogFile = 'x' }) }
        $script:complete = InModuleScope $module { [BuildOutcome]::Complete }
    }

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-BuildTarget { }
        Mock -ModuleName $module Initialize-CommandRun { $script:builtVM }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Sync-VMProfile { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Register-RebuildSchedule { $script:calls.Add('schedule') }
        Mock -ModuleName $module Invoke-VMBuild { $script:calls.Add('build'); $script:complete }
    }

    It 'schedules the maintenance before building, so a restart part-way loses nothing' {
        Build-LazyVM -Name Alpha -Confirm:$false

        $script:calls | Should -Be @('schedule', 'build')
    }

    It 'builds anyway, warning how to schedule it, when scheduling fails' {
        Mock -ModuleName $module Register-RebuildSchedule { throw 'Task Scheduler is not running' }

        Build-LazyVM -Name Alpha -Confirm:$false

        $script:calls | Should -Be @('build')
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*Register-LazyVMMaintenance -Name Alpha*' }
    }

}
Describe 'Write-MaintenanceTaskWarning (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'points out a built VM whose maintenance is not scheduled, with the command that fixes it' {
        Mock -ModuleName $module Test-MaintenanceTaskMissing { $true }

        $warning = InModuleScope $module {
            Write-MaintenanceTaskWarning -VM ([VMContext]::new(@{ VMName = 'Alpha'; ScheduleTaskName = 'LazyVM-Maintain-Alpha' })) 3>&1
        }

        "$warning" | Should -BeLike '*not scheduled*Register-LazyVMMaintenance -Name Alpha*'
    }

    It 'says nothing when the maintenance is scheduled' {
        Mock -ModuleName $module Test-MaintenanceTaskMissing { $false }

        $warning = InModuleScope $module {
            Write-MaintenanceTaskWarning -VM ([VMContext]::new(@{ VMName = 'Alpha'; ScheduleTaskName = 'LazyVM-Maintain-Alpha' })) 3>&1
        }

        $warning | Should -BeNullOrEmpty
    }
}
Describe 'Test-MaintenanceTaskMissing (#284)' {
    It 'is <Expected> when <Case>' -ForEach @(
        @{ Case = 'the VM is built and has no task'; Task = $false; Built = $true; Expected = $true }
        @{ Case = 'the VM has its task'; Task = $true; Built = $true; Expected = $false }
        @{ Case = 'the VM is not built yet'; Task = $false; Built = $false; Expected = $false }
    ) {
        Mock -ModuleName $module Get-ScheduledTask { if ($Task) { [pscustomobject]@{ TaskName = 'LazyVM-Maintain-Alpha' } } }.GetNewClosure()
        Mock -ModuleName $module Get-VM { if ($Built) { [pscustomobject]@{ Name = 'Alpha' } } }.GetNewClosure()

        InModuleScope $module {
            Test-MaintenanceTaskMissing -VM ([VMContext]::new(@{ VMName = 'Alpha'; ScheduleTaskName = 'LazyVM-Maintain-Alpha' }))
        } | Should -Be $Expected
    }
}

Describe 'Assert-RootFolderUsable (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-RegisteredRoot { $null }
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
    }

    It 'accepts <Case>' -ForEach @(
        @{ Case = 'a folder that is not there yet'; Files = $null }
        @{ Case = 'an empty folder'; Files = @() }
        @{ Case = 'a LazyVM folder'; Files = @('Shared/Config/LazyVM.Settings.json', 'DevBox/Config/VM.json') }
    ) {
        if ($null -ne $Files) { New-Item -ItemType Directory -Path $path | Out-Null }
        foreach ($file in $Files) {
            New-Item -ItemType File -Path (Join-Path -Path $path -ChildPath $file) -Force | Out-Null
        }

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Assert-RootFolderUsable -Path $Path } } | Should -Not -Throw
    }

    It 'refuses a folder that holds anything else, since locking it would shut everyone else out of it' {
        New-Item -ItemType File -Path (Join-Path -Path $path -ChildPath 'Documents/report.docx') -Force | Out-Null

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Assert-RootFolderUsable -Path $Path } } |
            Should -Throw -ExpectedMessage '*already holds*lock*you and SYSTEM*'
    }

    It 'accepts the folder LazyVM already uses, <Which>' -ForEach @(
        @{ Which = 'for this user'; Pattern = 'HKCU:*' }
        @{ Which = 'from a machine-wide install'; Pattern = 'HKLM:*' }
    ) {
        New-Item -ItemType File -Path (Join-Path -Path $path -ChildPath 'stray.txt') -Force | Out-Null
        $filter = [scriptblock]::Create("`$Key -like '$Pattern'")
        Mock -ModuleName $module Get-RegisteredRoot { $path }.GetNewClosure() -ParameterFilter $filter

        { InModuleScope $module -Parameters @{ Path = $path } { param($Path) Assert-RootFolderUsable -Path $Path } } | Should -Not -Throw
    }
}

Describe 'Set-LazyVMRoot asks before it locks a folder (#284)' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Assert-NoLegacyInstallation { }
        Mock -ModuleName $module Get-RegisteredRoot { $null }
        Mock -ModuleName $module Initialize-RootFolder { }
        Mock -ModuleName $module Set-RegisteredRoot { }
    }

    It 'checks the folder before asking' {
        Mock -ModuleName $module Assert-RootFolderUsable { throw 'holds other files' }

        { Set-LazyVMRoot -Path 'D:\DevVM' -WhatIf } | Should -Throw -ExpectedMessage '*holds other files*'

        Should -Invoke -ModuleName $module Initialize-RootFolder -Times 0
    }

    It 'confirms by default, as a high-impact change' {
        (Get-Command -Name Set-LazyVMRoot).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            ForEach-Object { "$($_.ConfirmImpact)" } | Should -Be 'High'
    }
}

Describe 'Test-CloudSyncedPath (#284)' {
    BeforeEach {
        $saved = @{ OneDrive = $env:OneDrive; OneDriveConsumer = $env:OneDriveConsumer; OneDriveCommercial = $env:OneDriveCommercial }
        $env:OneDrive = 'C:\Users\sean\OneDrive'
        $env:OneDriveConsumer = $null
        $env:OneDriveCommercial = 'C:\Users\sean\OneDrive - Contoso'
    }

    AfterEach {
        foreach ($name in $saved.Keys) { Set-Item -Path "Env:\$name" -Value $saved[$name] }
    }

    It 'is <Expected> for <Path>' -ForEach @(
        @{ Path = 'C:\Users\sean\OneDrive\LazyVM'; Expected = $true }
        @{ Path = 'C:\Users\sean\OneDrive - Contoso\VMs'; Expected = $true }
        @{ Path = 'C:\Users\sean\LazyVM'; Expected = $false }
        @{ Path = 'D:\DevVM'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Path = $Path } { param($Path) Test-CloudSyncedPath -Path $Path } | Should -Be $Expected
    }

    It 'knows a cloud file by its attributes: <Case>' -ForEach @(
        @{ Case = 'online-only (unpinned)'; Attributes = 0x100000; Expected = $true }
        @{ Case = 'always kept (pinned)'; Attributes = 0x80000; Expected = $true }
        @{ Case = 'recalled when opened'; Attributes = 0x40000; Expected = $true }
        @{ Case = 'an ordinary folder'; Attributes = 0x10; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Attributes = $Attributes } { param($Attributes) Test-CloudFileAttribute -Attributes $Attributes } | Should -Be $Expected
    }
}

Describe 'A LazyVM folder in OneDrive (#284)' {
    It 'is refused before anything is locked' {
        Mock -ModuleName $module Test-CloudSyncedPath { $true }

        { InModuleScope $module { Assert-RootFolderUsable -Path 'C:\Users\sean\OneDrive\LazyVM' } } | Should -Throw -ExpectedMessage '*OneDrive*outside it*'
    }

    It 'is reported by Test-LazyVM, as is a module loaded from OneDrive' {
        Mock -ModuleName $module Get-LazyVMModuleBase { 'C:\Users\sean\OneDrive\Documents\PowerShell\Modules\LazyVM\6.0.0' }
        Mock -ModuleName $module Test-CloudSyncedPath { $Path -like '*OneDrive*' }

        $check = InModuleScope $module { Get-CloudSyncCheck -Name 'Alpha' -Root 'C:\Users\sean\LazyVM' }

        $check.Status | Should -Be 'WARN'
        $check.Detail | Should -BeLike '*Documents\PowerShell\Modules\LazyVM\6.0.0 in OneDrive*Install.ps1*'
    }

    It 'is not reported when neither is in OneDrive' {
        Mock -ModuleName $module Get-LazyVMModuleBase { 'C:\Users\sean\AppData\Local\LazyVM\Modules\LazyVM\6.0.0' }
        Mock -ModuleName $module Test-CloudSyncedPath { $false }

        (InModuleScope $module { Get-CloudSyncCheck -Name 'Alpha' -Root 'C:\Users\sean\LazyVM' }).Status | Should -Be 'OK'
    }
}

Describe 'Assert-RootLocked (#284)' {
    BeforeEach {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType File -Path (Join-Path -Path $root -ChildPath 'Shared/Config/LazyVM.Settings.json') -Force | Out-Null
    }

    It 'accepts a LazyVM folder open to its owner and SYSTEM only' {
        Mock -ModuleName $module Get-RootAccess { [pscustomobject]@{ Protected = $true; Sids = @('S-1-5-21-1-1001', 'S-1-5-18') } }

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Assert-RootLocked -Root $Root } } | Should -Not -Throw
    }

    It 'refuses a folder <Case>' -ForEach @(
        @{ Case = 'open to anyone else'; Protected = $true; Sids = @('S-1-5-21-1-1001', 'S-1-5-18', 'S-1-5-32-545') }
        @{ Case = 'that inherits access'; Protected = $false; Sids = @('S-1-5-21-1-1001', 'S-1-5-18') }
    ) {
        $access = [pscustomobject]@{ Protected = $Protected; Sids = $Sids }
        Mock -ModuleName $module Get-RootAccess { $access }.GetNewClosure()

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Assert-RootLocked -Root $Root } } | Should -Throw -ExpectedMessage '*not locked*Set-LazyVMRoot*'
    }

    It 'refuses a folder that is not a LazyVM folder' {
        $other = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other | Out-Null

        { InModuleScope $module -Parameters @{ Root = $other } { param($Root) Assert-RootLocked -Root $Root } } | Should -Throw -ExpectedMessage '*not a LazyVM folder*'
    }

    It 'is checked for a folder handed to a command with -Root, as the scheduled tasks do' {
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }
        Mock -ModuleName $module Assert-RootLocked { throw 'not locked' }

        { InModuleScope $module { Resolve-LazyVMRoot -Root 'D:\DevVM' } } | Should -Throw -ExpectedMessage '*not locked*'
    }
}

Describe 'The resume point of an interrupted build (#284)' {
    It 'is kept in the VM''s own folder, which the resume task, running as SYSTEM, reads' {
        $file = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid().ToString('N'))/Config/Resume.json"
        $vm = InModuleScope $module -Parameters @{ File = $file } { param($File) [VMContext]::new(@{ VMName = 'Alpha'; ResumeFile = $File; ResumeTaskName = 'LazyVM-ResumeAfterReboot-Alpha' }) }

        $phases = InModuleScope $module -Parameters @{ VM = $vm; File = $file } {
            param($VM, $File)
            $before = Get-ResumePhase -VM $VM
            Set-ResumePhase -Path $File -Phase 3
            $during = Get-ResumePhase -VM $VM
            Mock Get-ScheduledTask { }
            Mock Write-LogEntry { }
            Unregister-ResumeTask -VM $VM
            $before, $during, (Get-ResumePhase -VM $VM)
        }

        $phases | Should -Be @(0, 3, 0)
    }
}

Describe 'Initialize-BuildTarget -Root (#284)' {
    It 'uses the folder handed in as it is, choosing and recording none' {
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType File -Path (Join-Path -Path $root -ChildPath 'DevBox/Config/VM.json') -Force | Out-Null
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'the -Root parameter' } }.GetNewClosure()
        Mock -ModuleName $module Set-RegisteredRoot { }
        Mock -ModuleName $module Initialize-RootFolder { }

        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Initialize-BuildTarget -Name 'DevBox' -Root $Root } 6> $null

        Should -Invoke -ModuleName $module Resolve-LazyVMRoot -Times 1 -Exactly -ParameterFilter { $Root -eq $root }
        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 0
        Should -Invoke -ModuleName $module Initialize-RootFolder -Times 0
    }
}
