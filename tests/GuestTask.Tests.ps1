# GuestTask.Tests.ps1
# Each guest task keeps its files in a folder of its own that only
# administrators and SYSTEM can change, under %ProgramFiles%\LazyVM\Tasks,
# not in the setup folder every guest user can write to (#302). The folder
# is checked before each run and made again when its owner or ACL is wrong.
# Windows ACLs are faked where the runner has none; what only a real guest
# can show (the ACL Windows stores) is checked by hand on a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $system = 'S-1-5-18'
    $administrators = 'S-1-5-32-544'
    $user = 'S-1-5-21-1-2-3-1001'

    function New-TestRule {
        <# An access rule as Get-Acl reads it. #>
        param(
            [Parameter(Mandatory)][string]$Sid,
            [string]$Rights = 'FullControl',
            [string]$Type = 'Allow',
            [string]$Inheritance = 'ContainerInherit, ObjectInherit',
            [string]$Propagation = 'None'
        )

        return [pscustomobject]@{
            IdentityReference = [pscustomobject]@{ Value = $Sid }
            FileSystemRights  = [System.Security.AccessControl.FileSystemRights]$Rights
            AccessControlType = [System.Security.AccessControl.AccessControlType]$Type
            InheritanceFlags  = [System.Security.AccessControl.InheritanceFlags]$Inheritance
            PropagationFlags  = [System.Security.AccessControl.PropagationFlags]$Propagation
        }
    }

    function New-TestAcl {
        <# A folder's ACL as Get-Acl reads it; by default the one a private folder has. #>
        param(
            [string]$Owner = 'S-1-5-32-544',
            [bool]$Protected = $true,
            [object[]]$Rules = @((New-TestRule -Sid 'S-1-5-18'), (New-TestRule -Sid 'S-1-5-32-544'))
        )

        $acl = [pscustomobject]@{ AreAccessRulesProtected = $Protected; OwnerSid = $Owner; Rules = $Rules }
        $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { [pscustomobject]@{ Value = $this.OwnerSid } }
        $acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { $this.Rules }
        return $acl
    }
}

Describe 'Get-GuestFolderAclProblem' {
    It 'finds nothing wrong with full control for SYSTEM and Administrators only, owned by Administrators' {
        Get-GuestFolderAclProblem -Acl (New-TestAcl) | Should -BeExactly ''
    }

    It 'finds nothing wrong when the user a task runs as may also change it' {
        $acl = New-TestAcl -Rules @((New-TestRule -Sid $system), (New-TestRule -Sid $administrators), (New-TestRule -Sid $user -Rights 'Modify, Synchronize'))

        Get-GuestFolderAclProblem -Acl $acl -ModifySid $user | Should -BeExactly ''
    }

    It 'refuses a folder owned by anyone but Administrators' {
        Get-GuestFolderAclProblem -Acl (New-TestAcl -Owner $user) | Should -BeLike "*owned by $user*"
    }

    It 'refuses a folder that inherits access from the folder above' {
        Get-GuestFolderAclProblem -Acl (New-TestAcl -Protected $false) | Should -BeLike '*inherits*'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'access for anyone else'; Extra = @{ Sid = 'S-1-5-11'; Rights = 'ReadAndExecute, Synchronize' } }
        @{ Case = 'a deny entry'; Extra = @{ Sid = 'S-1-5-11'; Type = 'Deny' } }
        @{ Case = 'the task''s user when the task does not run as them'; Extra = @{ Sid = 'S-1-5-21-1-2-3-1001'; Rights = 'Modify, Synchronize' } }
    ) {
        $acl = New-TestAcl -Rules @((New-TestRule -Sid $system), (New-TestRule -Sid $administrators), (New-TestRule @Extra))

        Get-GuestFolderAclProblem -Acl $acl | Should -BeLike "*$($Extra.Sid)*"
    }

    It 'refuses SYSTEM with less than full control' {
        $acl = New-TestAcl -Rules @((New-TestRule -Sid $system -Rights 'Modify, Synchronize'), (New-TestRule -Sid $administrators))

        Get-GuestFolderAclProblem -Acl $acl | Should -BeLike "*$system*"
    }

    It 'refuses an entry that does not reach the files in the folder' {
        $acl = New-TestAcl -Rules @((New-TestRule -Sid $system -Inheritance 'ContainerInherit'), (New-TestRule -Sid $administrators))

        Get-GuestFolderAclProblem -Acl $acl | Should -BeLike "*$system*"
    }

    It 'refuses a folder the task''s user cannot change when the task runs as them' {
        Get-GuestFolderAclProblem -Acl (New-TestAcl) -ModifySid $user | Should -BeLike "*$user*"
    }

    It 'refuses a folder Administrators cannot fully control' {
        Get-GuestFolderAclProblem -Acl (New-TestAcl -Rules @((New-TestRule -Sid $system))) | Should -BeLike "*$administrators*"
    }
}

Describe 'Get-GuestPrivateFolderProblem' {
    BeforeEach {
        Mock Get-Acl { New-TestAcl }
    }

    It 'checks a folder''s owner and ACL' {
        $folder = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'task')

        Get-GuestPrivateFolderProblem -Path $folder.FullName -ModifySid $user | Should -BeLike "*$user*"
        Should -Invoke Get-Acl -Times 1 -Exactly
    }

    It 'refuses a file' {
        $file = New-Item -ItemType File -Path (Join-Path $TestDrive 'task.txt')

        Get-GuestPrivateFolderProblem -Path $file.FullName | Should -BeLike '*not a folder*'
    }

    It 'refuses a link to a folder' {
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'elsewhere')
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $TestDrive 'link') -Target $target.FullName

        Get-GuestPrivateFolderProblem -Path $link.FullName | Should -BeLike '*junction or link*'
        Should -Invoke Get-Acl -Times 0 -Exactly
    }
}

Describe 'Initialize-GuestPrivateFolder' {
    BeforeEach {
        # TestDrive is kept between the tests of a Describe.
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $elsewhere = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock New-GuestPrivateFolder { $null = New-Item -ItemType Directory -Path $Path }
    }

    It 'makes the folder when there is none, with access for the task''s user' {
        Initialize-GuestPrivateFolder -Path $path -ModifySid $user

        Should -Invoke New-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $path -and $ModifySid -eq $user }
    }

    It 'keeps a folder whose owner and ACL are right, and what is in it' {
        $null = New-Item -ItemType Directory -Path $path
        $null = New-Item -ItemType File -Path (Join-Path $path 'bootstrap.exe')
        Mock Get-GuestPrivateFolderProblem { '' }

        Initialize-GuestPrivateFolder -Path $path

        Join-Path $path 'bootstrap.exe' | Should -Exist
        Should -Invoke New-GuestPrivateFolder -Times 0 -Exactly
    }

    It 'deletes a folder whose owner or ACL is wrong, with what is in it, and makes it again' {
        $null = New-Item -ItemType Directory -Path $path
        $null = New-Item -ItemType File -Path (Join-Path $path 'LazyVM-x.work.ps1')
        Mock Get-GuestPrivateFolderProblem { 'it inherits access from the folder above' }

        Initialize-GuestPrivateFolder -Path $path

        Join-Path $path 'LazyVM-x.work.ps1' | Should -Not -Exist
        Should -Invoke New-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
    }

    It 'deletes a link where the folder should be, but not what it points to' {
        $target = New-Item -ItemType Directory -Path $elsewhere
        $kept = New-Item -ItemType File -Path (Join-Path $target 'keep.txt')
        $null = New-Item -ItemType SymbolicLink -Path $path -Target $target.FullName

        Initialize-GuestPrivateFolder -Path $path

        $kept.FullName | Should -Exist
        (Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Be 0
    }

    It 'does not follow a link inside the folder when it deletes it' {
        $target = New-Item -ItemType Directory -Path $elsewhere
        $kept = New-Item -ItemType File -Path (Join-Path $target 'keep.txt')
        $null = New-Item -ItemType Directory -Path $path
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $path 'link') -Target $target.FullName
        Mock Get-GuestPrivateFolderProblem { 'it is owned by S-1-5-21-1-2-3-1001, not Administrators' }

        Initialize-GuestPrivateFolder -Path $path

        $kept.FullName | Should -Exist
    }
}

Describe 'The guest task folder' {
    BeforeAll {
        $programFiles = $env:ProgramFiles
        $env:ProgramFiles = Join-Path $TestDrive 'Program Files'
    }

    AfterAll {
        $env:ProgramFiles = $programFiles
    }

    It 'is the task''s own folder under Program Files\LazyVM\Tasks' {
        Get-GuestTaskFolder -TaskName 'LazyVM-windows-update' |
            Should -Be ([IO.Path]::Combine($env:ProgramFiles, 'LazyVM', 'Tasks', 'LazyVM-windows-update'))
    }

    It 'is made private, for SYSTEM and Administrators only, when the task runs as SYSTEM' {
        Mock Initialize-GuestPrivateFolder { }

        $folder = Initialize-GuestTaskFolder -TaskName 'LazyVM-windows-update'

        $folder | Should -Be (Get-GuestTaskFolder -TaskName 'LazyVM-windows-update')
        Should -Invoke Initialize-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $folder -and -not $ModifySid }
    }

    It 'lets the user a task runs as change it too' {
        Mock Initialize-GuestPrivateFolder { }
        Mock Get-GuestAccountSid { 'S-1-5-21-1-2-3-1001' }

        $null = Initialize-GuestTaskFolder -TaskName 'LazyVM-VSSettings' -UserName 'devadmin'

        Should -Invoke Get-GuestAccountSid -Times 1 -Exactly -ParameterFilter { $UserName -eq 'devadmin' }
        Should -Invoke Initialize-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $ModifySid -eq 'S-1-5-21-1-2-3-1001' }
    }
}

Describe 'Start-GuestTask' {
    BeforeAll {
        $taskFolder = 'C:\Program Files\LazyVM\Tasks\LazyVM-winget'
        # ? for the path separators, which are / where the tests run on Linux.
        $taskFile = 'C:?Program Files?LazyVM?Tasks?LazyVM-winget?LazyVM-winget'
    }

    BeforeEach {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-GuestTaskFolder { $calls.Add('folder'); $taskFolder }
        Mock Remove-Item { }
        Mock Set-Content { $calls.Add("write $LiteralPath") }
        Mock Unregister-ScheduledTask { }
        # The New-ScheduledTask* builders only make objects, so they run for real.
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-31' } }
    }

    It 'writes the wrapper, the work and its arguments into the task''s folder, only once it is ready' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -TimeoutSeconds 60

        $calls[0] | Should -Be 'folder'
        @($calls | Where-Object { $_ -like 'write *' }).Count | Should -Be 3
        @($calls | Where-Object { $_ -like 'write *' -and $_ -notlike "write $taskFile.*" }) | Should -BeNullOrEmpty
    }

    It 'runs the wrapper from the task''s folder' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -TimeoutSeconds 60

        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $Action.Arguments -like "*-File `"$taskFile.ps1`"" -and $Action.WorkingDirectory -eq $taskFolder
        }
    }

    It 'gives no user access to the folder of a task that runs <Case>' -ForEach @(
        @{ Case = 'as SYSTEM'; Run = @{} }
        @{ Case = 'as the user with their full token'; Run = @{ UserName = 'devadmin'; Elevated = $true } }
    ) {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -TimeoutSeconds 60 @Run

        Should -Invoke Initialize-GuestTaskFolder -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LazyVM-winget' -and -not $UserName }
    }

    It 'lets the user change the folder of a task that runs under their limited token' {
        Start-GuestTask -TaskName 'LazyVM-VSSettings' -Work 'return 1' -UserName 'devadmin' -TimeoutSeconds 60

        Should -Invoke Initialize-GuestTaskFolder -Times 1 -Exactly -ParameterFilter { $UserName -eq 'devadmin' }
    }
}

Describe 'The guest task wrapper' {
    It 'writes the result as UTF-8' {
        $writes = @([regex]::Matches($script:GuestTaskWrapper, 'Set-Content[^\r\n]*\.done[^\r\n]*') | ForEach-Object { $_.Value })

        $writes.Count | Should -Be 2
        $writes | ForEach-Object { $_ | Should -Match '-Encoding UTF8' }
    }
}

Describe 'Get-GuestTaskStatus' {
    BeforeAll {
        $programFiles = $env:ProgramFiles
        $env:ProgramFiles = Join-Path $TestDrive 'Program Files'
    }

    AfterAll {
        $env:ProgramFiles = $programFiles
    }

    It 'reads the result from the task''s folder' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-31' } }
        $folder = New-Item -ItemType Directory -Path (Get-GuestTaskFolder -TaskName 'LazyVM-winget') -Force
        Set-Content -LiteralPath (Join-Path $folder 'LazyVM-winget.done') -Value '3010'

        (Get-GuestTaskStatus -TaskName 'LazyVM-winget').Done | Should -Be '3010'
    }
}

Describe 'Remove-GuestLegacyTaskFile' {
    BeforeEach {
        $setupDir = Join-Path $TestDrive 'LazyVMSetup'
        $null = New-Item -ItemType Directory -Path $setupDir -Force
        $taskFiles = foreach ($suffix in '.ps1', '.work.ps1', '.args.json', '.done', '.log') { Join-Path $setupDir "LazyVM-winget$suffix" }
        foreach ($file in $taskFiles) { Set-Content -LiteralPath $file -Value 'x' }
        $other = Join-Path $setupDir 'winstate.zip'
        Set-Content -LiteralPath $other -Value 'x'
    }

    It 'deletes the files a task left in the setup folder, and nothing else' {
        Remove-GuestLegacyTaskFile -SetupDir $setupDir -TaskName 'LazyVM-winget'

        foreach ($file in $taskFiles) { $file | Should -Not -Exist }
        $other | Should -Exist
    }

    It 'does nothing, and does not fail, when there is no setup folder' {
        { Remove-GuestLegacyTaskFile -SetupDir (Join-Path $TestDrive 'none') -TaskName 'LazyVM-winget' } | Should -Not -Throw
    }

    It 'leaves alone a setup folder that is a link' {
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $TestDrive 'linked') -Target $setupDir

        Remove-GuestLegacyTaskFile -SetupDir $link.FullName -TaskName 'LazyVM-winget'

        foreach ($file in $taskFiles) { $file | Should -Exist }
    }
}

Describe 'Files the host copies in for a guest task' {
    BeforeEach {
        Mock -ModuleName $module Invoke-GuestScript { 'C:\Program Files\LazyVM\Tasks\LazyVM-VSSettings' }
    }

    It 'go into the task''s own folder, made ready in the guest first' {
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup' }) }

        $folder = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) New-GuestTaskFolder -VM $VM -TaskName 'LazyVM-install-sqlserver' }

        $folder | Should -Be 'C:\Program Files\LazyVM\Tasks\LazyVM-VSSettings'
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'LazyVM-install-sqlserver' -and -not $ArgumentList[1] -and "$ScriptBlock" -match 'Initialize-GuestTaskFolder'
        }
    }

    It 'are open to the guest account when its task runs as that account' {
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup' }) }
        $vm.Runtime.GuestAdminUser = 'devadmin'

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) New-GuestTaskFolder -VM $VM -TaskName 'LazyVM-VSSettings' -AsGuestUser }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'devadmin' }
    }
}
