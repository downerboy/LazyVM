# GuestTask.Tests.ps1
# What LazyVM runs and stages in the guest stays where no other guest user
# can change or read it (#302): each task in a folder of its own under
# %ProgramFiles%\LazyVM\Tasks, and what LazyVM copies in and out in
# %ProgramFiles%\LazyVM\Staging, never in a folder of C:\, where any user
# can make folders and links. A folder that is not right is moved aside and
# made again, never deleted, and the folders above must already be safe.
# Windows ACLs are faked where the runner has none; the tests that create
# real ones run on Windows only.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $system = 'S-1-5-18'
    $administrators = 'S-1-5-32-544'
    $trustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $creatorOwner = 'S-1-3-0'
    $users = 'S-1-5-32-545'
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

    function New-TestFolder {
        <# A new, empty folder of its own in TestDrive, which is kept between the tests of a Describe. #>
        return (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
    }
}

Describe 'Get-GuestFolderAclProblem' {
    It 'finds nothing wrong with full control for SYSTEM and Administrators only, owned by Administrators' {
        Get-GuestFolderAclProblem -Acl (New-TestAcl) | Should -BeExactly ''
    }

    It 'finds nothing wrong when the user a task runs as may <Access> it' -ForEach @(
        @{ Access = 'read'; Parameter = 'ReadSid'; Rights = 'ReadAndExecute, Synchronize' }
        @{ Access = 'change'; Parameter = 'ModifySid'; Rights = 'Modify, Synchronize' }
    ) {
        $acl = New-TestAcl -Rules @((New-TestRule -Sid $system), (New-TestRule -Sid $administrators), (New-TestRule -Sid $user -Rights $Rights))
        $expected = @{ $Parameter = $user }

        Get-GuestFolderAclProblem -Acl $acl @expected | Should -BeExactly ''
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

    It 'refuses a folder the task''s user can change when they may only read it' {
        $acl = New-TestAcl -Rules @((New-TestRule -Sid $system), (New-TestRule -Sid $administrators), (New-TestRule -Sid $user -Rights 'Modify, Synchronize'))

        Get-GuestFolderAclProblem -Acl $acl -ReadSid $user | Should -BeLike "*$user*"
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
        Get-GuestPrivateFolderProblem -Path (New-TestFolder) -ModifySid $user | Should -BeLike "*$user*"
        Should -Invoke Get-Acl -Times 1 -Exactly
    }

    It 'refuses a file' {
        $file = New-Item -ItemType File -Path (Join-Path $TestDrive 'task.txt') -Force

        Get-GuestPrivateFolderProblem -Path $file.FullName | Should -BeLike '*not a folder*'
    }

    It 'refuses a link to a folder' {
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Target (New-TestFolder)

        Get-GuestPrivateFolderProblem -Path $link.FullName | Should -BeLike '*junction or link*'
        Should -Invoke Get-Acl -Times 0 -Exactly
    }
}

Describe 'New-GuestPrivateFolder' -Skip:(-not $IsWindows) {
    BeforeAll {
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $helpers = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1'

        function Invoke-InGuestPowerShell {
            <# Runs $Script with the guest helpers in Windows PowerShell 5.1, as the guest does, and returns what it wrote. #>
            param([Parameter(Mandatory)][string]$Script)

            $command = ". '$helpers'`n$Script"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            return (@(& powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" }) -join "`n").Trim()
        }
    }

    It 'makes a folder whose owner and ACL are exactly those it checks for, <Case>' -ForEach @(
        @{ Case = 'for SYSTEM and Administrators only'; Access = '' }
        @{ Case = 'readable by a user'; Access = '-ReadSid' }
        @{ Case = 'changeable by a user'; Access = '-ModifySid' }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $access = if ($Access) { "$Access '$me'" } else { '' }

        Invoke-InGuestPowerShell -Script "New-GuestPrivateFolder -Path '$path' $access; Get-GuestPrivateFolderProblem -Path '$path' $access" | Should -BeExactly ''
    }

    It 'fails, and uses nothing, when the folder it made does not have the ACL it gave (#302 SEC-001)' {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $fake = "function Get-GuestPrivateFolderProblem { 'it is owned by S-1-5-21-1-2-3-1001, not Administrators' }"
        $script = "$fake`ntry { New-GuestPrivateFolder -Path '$path'; 'made' } catch { `$_.Exception.Message }"

        Invoke-InGuestPowerShell -Script $script | Should -BeLike '*was not made private: it is owned by S-1-5-21-1-2-3-1001*'
    }

    It 'refuses anything already there' {
        { New-GuestPrivateFolder -Path (New-TestFolder) } | Should -Throw '*already exists*'
    }

    It 'makes a folder above the private ones owned by Administrators, whatever the token''s default owner, and inheriting the access above it (New-GuestAdminFolder)' {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script = "New-GuestAdminFolder -Path '$path'; `$acl = Get-Acl -LiteralPath '$path'; " +
        "'{0} {1}' -f `$acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value, `$acl.AreAccessRulesProtected"

        Invoke-InGuestPowerShell -Script $script | Should -Be 'S-1-5-32-544 False'
    }
}

Describe 'Initialize-GuestPrivateFolder' {
    BeforeEach {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock New-GuestPrivateFolder { $null = New-Item -ItemType Directory -Path $Path }
    }

    It 'makes the folder when there is none, with the access asked for' {
        $result = Initialize-GuestPrivateFolder -Path $path -ReadSid $user

        $result.Path | Should -Be $path
        $result.Replaced | Should -BeFalse
        Should -Invoke New-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $path -and $ReadSid -eq $user -and -not $ModifySid }
    }

    It 'keeps a folder whose owner and ACL are right, and what is in it' {
        $null = New-Item -ItemType Directory -Path $path
        $null = New-Item -ItemType File -Path (Join-Path $path 'bootstrap.exe')
        Mock Get-GuestPrivateFolderProblem { '' }

        (Initialize-GuestPrivateFolder -Path $path).Replaced | Should -BeFalse

        Join-Path $path 'bootstrap.exe' | Should -Exist
        Should -Invoke New-GuestPrivateFolder -Times 0 -Exactly
    }

    It 'moves a folder whose owner or ACL is wrong aside, deleting nothing, and makes it again' {
        $null = New-Item -ItemType Directory -Path $path
        $null = New-Item -ItemType File -Path (Join-Path $path 'LazyVM-x.work.ps1')
        Mock Get-GuestPrivateFolderProblem { 'it inherits access from the folder above' }

        $result = Initialize-GuestPrivateFolder -Path $path

        $result.Replaced | Should -BeTrue
        $result.Reason | Should -Be 'it inherits access from the folder above'
        $result.MovedTo | Should -BeLike "$path.replaced-*"
        Join-Path $result.MovedTo 'LazyVM-x.work.ps1' | Should -Exist
        Join-Path $path 'LazyVM-x.work.ps1' | Should -Not -Exist
        Should -Invoke New-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
    }

    It 'moves a link where the folder should be aside, leaving what it points to alone' {
        $target = New-TestFolder
        $kept = New-Item -ItemType File -Path (Join-Path $target 'keep.txt')
        $null = New-Item -ItemType SymbolicLink -Path $path -Target $target

        $result = Initialize-GuestPrivateFolder -Path $path

        $result.Reason | Should -BeLike '*junction or link*'
        $kept.FullName | Should -Exist
        (Get-Item -LiteralPath $result.MovedTo -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Not -Be 0
        (Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Be 0
    }
}

Describe 'Get-GuestAdminFolderProblem (#302 SEC-006)' {
    It 'finds nothing wrong with <Case>' -ForEach @(
        @{ Case = 'what a folder in Program Files inherits'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Propagation = 'InheritOnly' }
                @{ Sid = 'S-1-5-18' }
                @{ Sid = 'S-1-5-32-544' }
                @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute, Synchronize' }
                @{ Sid = 'S-1-3-0'; Propagation = 'InheritOnly' }
            )
        }
        @{ Case = 'a folder SYSTEM owns'; Owner = 'S-1-5-18'; Rules = @(@{ Sid = 'S-1-5-18' }) }
        @{ Case = 'a folder TrustedInstaller owns'; Owner = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Rules = @(@{ Sid = 'S-1-5-18' }) }
    ) {
        $acl = New-TestAcl -Owner $Owner -Protected $false -Rules @($Rules | ForEach-Object { New-TestRule @_ })
        Mock Get-Acl { $acl }.GetNewClosure()

        Get-GuestAdminFolderProblem -Path (New-TestFolder) | Should -BeExactly ''
    }

    It 'refuses a folder owned by a user, who can change its permissions' {
        Mock Get-Acl { New-TestAcl -Owner $user }

        Get-GuestAdminFolderProblem -Path (New-TestFolder) | Should -BeLike "*owned by $user*"
    }

    It 'refuses a folder anyone but administrators, SYSTEM and TrustedInstaller can <Case>' -ForEach @(
        @{ Case = 'write to'; Rights = 'Write, Synchronize' }
        @{ Case = 'append to'; Rights = 'AppendData, Synchronize' }
        @{ Case = 'delete in'; Rights = 'DeleteSubdirectoriesAndFiles, Synchronize' }
        @{ Case = 'change the permissions of'; Rights = 'ChangePermissions, Synchronize' }
    ) {
        $acl = New-TestAcl -Protected $false -Rules @((New-TestRule -Sid $system), (New-TestRule -Sid $users -Rights $Rights))
        Mock Get-Acl { $acl }.GetNewClosure()

        Get-GuestAdminFolderProblem -Path (New-TestFolder) | Should -BeLike "*$users*"
    }

    It 'refuses a link' {
        Mock Get-Acl { New-TestAcl }
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Target (New-TestFolder)

        Get-GuestAdminFolderProblem -Path $link.FullName | Should -BeLike '*junction or link*'
    }
}

Describe 'Initialize-GuestAdminFolder (#302 SEC-006)' {
    It 'makes a missing folder owned by Administrators, and checks it' {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock New-GuestAdminFolder { $null = New-Item -ItemType Directory -Path $Path }
        Mock Get-GuestAdminFolderProblem { '' }

        Initialize-GuestAdminFolder -Path $path

        Should -Invoke New-GuestAdminFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
        Should -Invoke Get-GuestAdminFolderProblem -Times 1 -Exactly -ParameterFilter { $Path -eq $path }
    }

    It 'makes nothing when the folder is there' {
        Mock New-GuestAdminFolder { }
        Mock Get-GuestAdminFolderProblem { '' }

        Initialize-GuestAdminFolder -Path (New-TestFolder)

        Should -Invoke New-GuestAdminFolder -Times 0 -Exactly
    }

    It 'stops, and changes nothing, when a folder others could change is there' {
        $path = New-TestFolder
        $kept = New-Item -ItemType File -Path (Join-Path $path 'keep.txt')
        Mock Get-GuestAdminFolderProblem { 'S-1-5-32-545 can change it' }

        { Initialize-GuestAdminFolder -Path $path } | Should -Throw "*$path*S-1-5-32-545 can change it*administrator*"

        $kept.FullName | Should -Exist
    }
}

Describe 'Get-GuestSystemFolder (#317)' {
    BeforeAll {
        $saved = @{ ProgramFiles = $env:ProgramFiles; SystemRoot = $env:SystemRoot }
    }

    AfterEach {
        $env:ProgramFiles = $saved.ProgramFiles
        $env:SystemRoot = $saved.SystemRoot
    }

    It 'asks Windows where <Name> is, whatever $env:<Variable> says' -ForEach @(
        @{ Name = 'ProgramFiles'; Variable = 'ProgramFiles' }
        @{ Name = 'Windows'; Variable = 'SystemRoot' }
    ) {
        # The guest admin's HKCU\Environment, which that account can change
        # without elevating, can set any of these in its sessions.
        Set-Item -Path "env:$Variable" -Value (Join-Path $TestDrive 'Elsewhere')

        Get-GuestSystemFolder -Name $Name | Should -Be ([Environment]::GetFolderPath($Name))
    }

    It 'keeps LazyVM''s guest folder in the Program Files Windows reports, not one $env:ProgramFiles names' {
        $env:ProgramFiles = Join-Path $TestDrive 'Elsewhere'

        Get-GuestLazyVMFolder | Should -Be ([IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), 'LazyVM'))
    }

    It 'gives the drive Windows is on as <Drive>' -ForEach @(
        @{ Windows = 'C:\Windows'; Drive = 'C:' }
        @{ Windows = 'D:\Windows'; Drive = 'D:' }
    ) {
        Mock Get-GuestSystemFolder { $Windows } -ParameterFilter { $Name -eq 'Windows' }

        Get-GuestSystemDrive | Should -Be $Drive
    }

    It 'finds <Case> in the system folders' -ForEach @(
        @{ Case = 'Windows PowerShell'; Command = 'Get-GuestWindowsPowerShell'; Expected = 'C:\Windows\System32?WindowsPowerShell?v1.0?powershell.exe' }
        @{ Case = 'the hosts file'; Command = 'Get-GuestHostsFile'; Expected = 'C:\Windows\System32?drivers?etc?hosts' }
        @{ Case = 'the Visual Studio Installer'; Command = 'Get-GuestVisualStudioInstallerFolder'; Expected = 'C:\Program Files (x86)?Microsoft Visual Studio?Installer' }
    ) {
        Mock Get-GuestSystemFolder { 'C:\Windows\System32' } -ParameterFilter { $Name -eq 'System' }
        Mock Get-GuestSystemFolder { 'C:\Program Files (x86)' } -ParameterFilter { $Name -eq 'ProgramFilesX86' }

        & $Command | Should -BeLike $Expected
    }
}

Describe 'The guest''s LazyVM folders' {
    BeforeAll {
        $programFiles = Join-Path $TestDrive 'Program Files'
        $lazyVM = [IO.Path]::Combine($programFiles, 'LazyVM')
    }

    AfterEach {
        $env:ProgramFiles = $saved
    }

    BeforeEach {
        $saved = $env:ProgramFiles
        Mock Get-GuestSystemFolder { $programFiles } -ParameterFilter { $Name -eq 'ProgramFiles' }
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock Get-GuestAdminFolderProblem { $calls.Add("check $Path"); '' }
        Mock Initialize-GuestAdminFolder { $calls.Add("admin $Path") }
        Mock Initialize-GuestPrivateFolder { $calls.Add("private $Path"); [pscustomobject]@{ Path = $Path; Replaced = $false; Reason = ''; MovedTo = '' } }
        Mock Get-GuestAccountSid { 'S-1-5-21-1-2-3-1001' }
    }

    It 'keep a task in Program Files\LazyVM\Tasks, with its Output folder inside' {
        Get-GuestTaskFolder -TaskName 'LazyVM-windows-update' | Should -Be ([IO.Path]::Combine($lazyVM, 'Tasks', 'LazyVM-windows-update'))
        Get-GuestTaskOutputFolder -TaskName 'LazyVM-windows-update' | Should -Be ([IO.Path]::Combine($lazyVM, 'Tasks', 'LazyVM-windows-update', 'Output'))
    }

    It 'are checked from the top down before a task''s folder is made' {
        $folder = Initialize-GuestTaskFolder -TaskName 'LazyVM-windows-update'

        $folder | Should -Be (Get-GuestTaskFolder -TaskName 'LazyVM-windows-update')
        $calls -join '|' | Should -Be ("check $programFiles|admin $lazyVM|admin $([IO.Path]::Combine($lazyVM, 'Tasks'))|private $folder|private $([IO.Path]::Combine($folder, 'Output'))")
    }

    It 'stop, and make nothing, when Program Files itself is not safe; it is only checked, never changed' {
        Mock Get-GuestAdminFolderProblem { 'S-1-5-32-545 can change it' }

        { Initialize-GuestTaskFolder -TaskName 'LazyVM-windows-update' } | Should -Throw "*$programFiles*S-1-5-32-545 can change it*"

        Should -Invoke Initialize-GuestAdminFolder -Times 0 -Exactly
        Should -Invoke Initialize-GuestPrivateFolder -Times 0 -Exactly
    }

    It 'give no user access to the folder of a task that runs <Case>' -ForEach @(
        @{ Case = 'as SYSTEM'; Run = @{} }
        @{ Case = 'as the user with their full token'; Run = @{ UserName = 'devadmin'; Elevated = $true } }
    ) {
        $null = Initialize-GuestTaskFolder -TaskName 'LazyVM-winget' @Run

        Should -Invoke Initialize-GuestPrivateFolder -Times 2 -Exactly -ParameterFilter { -not $ReadSid -and -not $ModifySid }
        Should -Invoke Get-GuestAccountSid -Times 0 -Exactly
    }

    It 'let the user of a task under their limited token read its inputs and change only its Output folder (#302 SEC-005)' {
        $folder = Initialize-GuestTaskFolder -TaskName 'LazyVM-VSSettings' -UserName 'devadmin'

        Should -Invoke Get-GuestAccountSid -Times 1 -Exactly -ParameterFilter { $UserName -eq 'devadmin' }
        Should -Invoke Initialize-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -eq $folder -and $ReadSid -eq 'S-1-5-21-1-2-3-1001' -and -not $ModifySid }
        Should -Invoke Initialize-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { $Path -like '*Output' -and $ModifySid -eq 'S-1-5-21-1-2-3-1001' -and -not $ReadSid }
    }

    It 'stage files in Program Files\LazyVM\Staging, for SYSTEM and Administrators only' {
        $staging = Initialize-GuestStagingFolder

        $staging.Path | Should -Be ([IO.Path]::Combine($lazyVM, 'Staging'))
        $calls -join '|' | Should -Be "check $programFiles|admin $lazyVM|private $($staging.Path)"
        Should -Invoke Initialize-GuestPrivateFolder -Times 1 -Exactly -ParameterFilter { -not $ReadSid -and -not $ModifySid }
    }

    It 'check and use the Program Files Windows reports, even when $env:ProgramFiles names another folder (#317)' {
        $env:ProgramFiles = Join-Path $TestDrive 'Elsewhere'

        $staging = Initialize-GuestStagingFolder

        $staging.Path | Should -Be ([IO.Path]::Combine($lazyVM, 'Staging'))
        $calls -join '|' | Should -Be "check $programFiles|admin $lazyVM|private $($staging.Path)"
    }
}

Describe 'Start-GuestTask' {
    BeforeAll {
        Mock Get-GuestSystemFolder { 'C:\Program Files' } -ParameterFilter { $Name -eq 'ProgramFiles' }
        Mock Get-GuestSystemFolder { 'C:\Windows\System32' } -ParameterFilter { $Name -eq 'System' }
        $taskFolder = Get-GuestTaskFolder -TaskName 'LazyVM-winget'
        # ? for the path separators, which are / where the tests run on Linux.
        $taskFile = 'C:?Program Files?LazyVM?Tasks?LazyVM-winget?LazyVM-winget'
    }

    BeforeEach {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-GuestTaskFolder { $calls.Add('folder'); $taskFolder }
        Mock Remove-Item { $calls.Add("remove $LiteralPath") }
        Mock Set-Content { $calls.Add("write $LiteralPath") }
        Mock Unregister-ScheduledTask { }
        # The New-ScheduledTask* builders only make objects, so they run for real.
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-31' } }
    }

    It 'writes the wrapper, the work and its arguments into the task''s folder, only once it is ready' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -Nonce 'n1' -TimeoutSeconds 60

        $calls[0] | Should -Be 'folder'
        @($calls | Where-Object { $_ -like 'write *' }).Count | Should -Be 3
        @($calls | Where-Object { $_ -like 'write *' -and $_ -notlike "write $taskFile.*" }) | Should -BeNullOrEmpty
    }

    It 'writes the start''s nonce beside the arguments, so a result from an earlier start is not taken for this one' {
        $written = @{}
        Mock Set-Content { $written["$LiteralPath"] = "$Value" }

        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -ArgumentList @('a', @('b', 'c')) -Nonce 'n1' -TimeoutSeconds 60

        $task = $written[@($written.Keys | Where-Object { $_ -like '*.args.json' })[0]] | ConvertFrom-Json
        $task.Nonce | Should -Be 'n1'
        $task.Arguments[0] | Should -Be 'a'
        @($task.Arguments[1]) | Should -Be @('b', 'c')
    }

    It 'deletes nothing, so nothing in Output, which the task''s user may change, is deleted as an administrator (#302 SEC-008)' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -Nonce 'n1' -TimeoutSeconds 60

        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'runs the wrapper from the task''s folder' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -Nonce 'n1' -TimeoutSeconds 60

        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $Action.Arguments -like "*-File `"$taskFile.ps1`"" -and $Action.WorkingDirectory -eq $taskFolder
        }
    }

    It 'runs the wrapper with the Windows PowerShell in the system folder, not one found on the PATH (#317)' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -Nonce 'n1' -TimeoutSeconds 60

        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $Action.Execute -like 'C:\Windows\System32?WindowsPowerShell?v1.0?powershell.exe'
        }
    }

    It 'leaves the folder''s access to Initialize-GuestTaskFolder, giving it the user and token the task runs with' {
        Start-GuestTask -TaskName 'LazyVM-winget' -Work 'return 1' -Nonce 'n1' -UserName 'devadmin' -Elevated -TimeoutSeconds 60

        Should -Invoke Initialize-GuestTaskFolder -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LazyVM-winget' -and $UserName -eq 'devadmin' -and $Elevated }
    }
}

Describe 'The guest task wrapper' {
    BeforeAll {
        $folder = New-TestFolder
        $output = New-Item -ItemType Directory -Path (Join-Path $folder 'Output')
        $base = Join-Path $folder 'LazyVM-test'
        Set-Content -LiteralPath "$base.ps1" -Value $script:GuestTaskWrapper
        Set-Content -LiteralPath "$base.work.ps1" -Value 'param($value) "$value|$TaskFolder|$TaskOutput"'
        Set-Content -LiteralPath "$base.args.json" -Value '{ "Nonce": "n1", "Arguments": ["x"] }'
        $pwsh = Join-Path $PSHOME 'pwsh'
        & $pwsh -NoProfile -NonInteractive -File "$base.ps1"
    }

    It 'gives the work its arguments, its folder and its Output folder, and writes the result, after the start''s nonce, and the transcript in Output' {
        Get-Content -LiteralPath (Join-Path $output 'LazyVM-test.done') -Raw | Should -Be "n1 x|$folder|$($output.FullName)$([Environment]::NewLine)"
        Join-Path $output 'LazyVM-test.log' | Should -Exist
        Join-Path $folder 'LazyVM-test.done' | Should -Not -Exist
    }

    It 'writes the result as UTF-8' {
        $writes = @([regex]::Matches($script:GuestTaskWrapper, 'Set-Content[^\r\n]*\$done[^\r\n]*') | ForEach-Object { $_.Value })

        $writes.Count | Should -Be 2
        $writes | ForEach-Object { $_ | Should -Match '-Encoding UTF8' }
    }
}

Describe 'Get-GuestTaskStatus' {
    BeforeEach {
        Mock Get-GuestSystemFolder { Join-Path $TestDrive 'Program Files' } -ParameterFilter { $Name -eq 'ProgramFiles' }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [datetime]'2026-10-31' } }
        $taskName = 'LazyVM-' + [guid]::NewGuid().ToString('N')
        $output = Get-GuestTaskOutputFolder -TaskName $taskName
        $done = Join-Path $output "$taskName.done"
    }

    It 'reads this start''s result from the task''s Output folder' {
        $null = New-Item -ItemType Directory -Path $output -Force
        Set-Content -LiteralPath $done -Value 'n1 3010'

        (Get-GuestTaskStatus -TaskName $taskName -Nonce 'n1').Done | Should -Be '3010'
    }

    It 'takes a result written for another start, or with no nonce, as no result yet' -ForEach @(
        @{ Written = 'n0 0' }
        @{ Written = '0' }
    ) {
        $null = New-Item -ItemType Directory -Path $output -Force
        Set-Content -LiteralPath $done -Value $Written

        (Get-GuestTaskStatus -TaskName $taskName -Nonce 'n1').Done | Should -BeNullOrEmpty
    }

    It 'reads nothing through a link in <Case>, which the task''s user may have made (#302 SEC-008)' -ForEach @(
        @{ Case = 'place of the Output folder'; LinkOutput = $true }
        @{ Case = 'place of the result'; LinkOutput = $false }
    ) {
        $elsewhere = New-TestFolder
        Set-Content -LiteralPath (Join-Path $elsewhere "$taskName.done") -Value 'n1 0'
        if ($LinkOutput) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $output -Parent) -Force
            $null = New-Item -ItemType SymbolicLink -Path $output -Target $elsewhere
        }
        else {
            $null = New-Item -ItemType Directory -Path $output -Force
            $null = New-Item -ItemType SymbolicLink -Path $done -Target (Join-Path $elsewhere "$taskName.done")
        }
        Mock Get-Content { 'n1 0' }

        (Get-GuestTaskStatus -TaskName $taskName -Nonce 'n1').Done | Should -BeNullOrEmpty
        Should -Invoke Get-Content -Times 0 -Exactly
    }
}

Describe 'Get-GuestTaskOutputFile (#330)' {
    BeforeEach {
        $output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-GuestTaskOutputFolder { $output }
        $null = New-Item -ItemType Directory -Path $output -Force
        $file = Join-Path $output 'NuGet.Config'
        $elsewhere = New-TestFolder
        Set-Content -LiteralPath (Join-Path $elsewhere 'NuGet.Config') -Value 'secret'
    }

    It 'gives the place of a file the task wrote in its Output folder' {
        Set-Content -LiteralPath $file -Value 'nuget'

        Get-GuestTaskOutputFile -TaskName 'LazyVM-VSUserFilesCapture' -Name 'NuGet.Config' | Should -Be $file
        Should -Invoke Get-GuestTaskOutputFolder -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LazyVM-VSUserFilesCapture' }
    }

    It 'refuses, naming it, a link in the place of <Case>, which the task''s user may have made' -ForEach @(
        @{ Case = 'the Output folder'; LinkOutput = $true }
        @{ Case = 'the file'; LinkOutput = $false }
    ) {
        if ($LinkOutput) {
            Remove-Item -LiteralPath $output
            $null = New-Item -ItemType SymbolicLink -Path $output -Target $elsewhere
            $link = $output
        }
        else {
            $null = New-Item -ItemType SymbolicLink -Path $file -Target (Join-Path $elsewhere 'NuGet.Config')
            $link = $file
        }

        { Get-GuestTaskOutputFile -TaskName 'LazyVM-VSUserFilesCapture' -Name 'NuGet.Config' } | Should -Throw "*$link*junction or link*"
    }

    It 'says so when the file is not there' {
        { Get-GuestTaskOutputFile -TaskName 'LazyVM-VSUserFilesCapture' -Name 'NuGet.Config' } | Should -Throw "*$file*not there*"
    }
}

Describe 'What administrators do in a task''s Output folder (#302 SEC-008)' {
    It 'is never a write, move or delete: <Function> only reads there' -ForEach @(
        # Found at discovery, before BeforeAll has set the module's folder.
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'src/LazyVM') -Recurse -Filter '*.ps1')) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                if ($function.Name -ne 'Get-GuestTaskOutputFolder' -and $function.Body.Extent.Text -match 'Get-GuestTaskOutput(Folder|File)\b') {
                    @{ Function = $function.Name; Body = $function.Body.Extent.Text }
                }
            }
        }
    ) {
        # Initialize-GuestTaskFolder may move the Output folder itself aside, never what is in it.
        $Body | Should -Not -Match '(?i)\b(Remove-Item|Set-Content|Add-Content|Out-File|Move-Item|Copy-Item|New-Item|Rename-Item|Clear-Content)\b|::(Delete|Move|Write\w*|Create\w*)\('
    }
}

Describe 'Get-GuestStagingFolder' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Path = 'C:\Program Files\LazyVM\Staging'; Replaced = $false; Reason = ''; MovedTo = '' } }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup' }) }
    }

    It 'makes the staging folder private in the guest once, and then gives the same path' {
        $paths = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) (Get-GuestStagingFolder -VM $VM), (Get-GuestStagingFolder -VM $VM) }

        $paths | Should -Be @('C:\Program Files\LazyVM\Staging', 'C:\Program Files\LazyVM\Staging')
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Initialize-GuestStagingFolder' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -Exactly
    }

    It 'logs that it moved a staging folder that was not right aside, and goes on' {
        Mock -ModuleName $module Invoke-GuestScript {
            [pscustomobject]@{ Path = 'C:\Program Files\LazyVM\Staging'; Replaced = $true; Reason = 'it inherits access from the folder above'; MovedTo = 'C:\Program Files\LazyVM\Staging.replaced-1' }
        }

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-GuestStagingFolder -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'INFO' -and $Message -like '*inherits access*Staging.replaced-1*'
        }
    }

    It 'says once that a GuestSetupDir other than the default is no longer used' {
        $custom = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'D:\Setup' }) }

        $null = InModuleScope $module -Parameters @{ VM = $custom } { param($VM) (Get-GuestStagingFolder -VM $VM), (Get-GuestStagingFolder -VM $VM) }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -like '*GuestSetupDir*D:\Setup*no longer used*' }
    }
}

Describe 'What LazyVM stages in the guest (#302)' {
    BeforeEach {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Get-GuestStagingFolder { $calls.Add('staging'); 'C:\Program Files\LazyVM\Staging' }
        Mock -ModuleName $module Write-LogEntry { }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVMSetup'; ToolingWingetCheck = @() }) }
    }

    It 'goes in the staging folder, never in GuestSetupDir, which no code uses any more' {
        $private = Join-Path $script:LazyVMModuleDir 'Private'
        $uses = @(Get-ChildItem -LiteralPath $private -Recurse -Filter '*.ps1' |
                Select-String -Pattern 'GuestSetupDir' |
                Where-Object { $_.Line -notmatch '^\s*#' } |
                ForEach-Object { "$($_.Filename): $($_.Line.Trim())" })

        # Only Get-GuestStagingFolder, to say that it is no longer used.
        $uses | Should -Not -BeNullOrEmpty
        $uses | ForEach-Object { $_ | Should -BeLike 'GuestScript.ps1:*' }
    }

    It 'copies a file into the guest without making any folder for it' {
        # Copy-Item -ToSession needs a real session, so this reads what Copy-ToGuest does.
        $body = InModuleScope $module { ${function:Copy-ToGuest}.ToString() }

        $body | Should -Match 'Copy-Item'
        $body | Should -Not -Match 'New-GuestFolder|New-Item|Invoke-GuestScript'
    }

    It 'copies a capture archive into the staging folder' {
        $archive = Join-Path $TestDrive 'winstate.zip'
        Set-Content -LiteralPath $archive -Value 'zip'
        Mock -ModuleName $module Copy-ToGuest { $calls.Add("copy $GuestPath") }

        $guestZip = InModuleScope $module -Parameters @{ VM = $vm; Archive = $archive } {
            param($VM, $Archive)
            Send-CaptureArchive -VM $VM -Area ([pscustomobject]@{ Archive = $Archive }) -What 'Windows environment'
        }

        $calls[0] | Should -Be 'staging'
        $calls[1] | Should -BeLike 'copy C:?Program Files?LazyVM?Staging?winstate.zip'
        $guestZip | Should -BeLike 'C:?Program Files?LazyVM?Staging?winstate.zip'
    }

    It 'takes the tooling inventory in the staging folder' {
        Mock -ModuleName $module Invoke-GuestScript { $calls.Add("inventory $($ArgumentList[0])") }

        $null = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-GuestToolingInventory -VM $VM }

        ($calls -join ',') | Should -Be 'staging,inventory C:\Program Files\LazyVM\Staging'
    }
}

Describe 'Files a guest task is given (Invoke-GuestTask -InputFile)' {
    BeforeEach {
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Copy-ToGuest { $calls.Add("copy $HostPath -> $GuestPath") }
        Mock -ModuleName $module Invoke-GuestScript {
            switch -Wildcard ($Activity) {
                'preparing the files of *' { $calls.Add("prepare $($ArgumentList -join ',')"); 'C:\Program Files\LazyVM\Tasks\LazyVM-VSSettings' }
                'starting *' { $calls.Add('start'); 'boot1' }
                'checking on *' { [pscustomobject]@{ Done = 'OK'; TaskState = 'Ready'; BootTime = 'boot1' } }
            }
        }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }
        $vm.Runtime.GuestAdminUser = 'devadmin'
    }

    It 'go into the task''s folder, made ready with the access the task runs with, before the task starts' {
        InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            Invoke-GuestTask -VM $VM -TaskName 'LazyVM-VSSettings' -Work { 'OK' } -InputFile @{ 'VisualStudio.vssettings' = 'C:\host\VisualStudio.vssettings' } -AsGuestUser -TimeoutMinutes 5 -Activity 'test'
        }

        $calls[0] | Should -Be 'prepare LazyVM-VSSettings,devadmin,False'
        $calls[1] | Should -BeLike 'copy C:\host\VisualStudio.vssettings -> C:?Program Files?LazyVM?Tasks?LazyVM-VSSettings?VisualStudio.vssettings'
        $calls[2] | Should -Be 'start'
    }

    It 'prepare nothing when there are none' {
        InModuleScope $module -Parameters @{ VM = $vm } {
            param($VM)
            Invoke-GuestTask -VM $VM -TaskName 'LazyVM-windows-update' -Work { 'OK' } -TimeoutMinutes 5 -Activity 'test'
        }

        $calls -join ',' | Should -Be 'start'
    }
}
