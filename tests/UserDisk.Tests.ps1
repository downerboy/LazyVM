# UserDisk.Tests.ps1
# The User disk (#137): Documents, Desktop and Downloads are redirected to it,
# and .ssh and source\repos are linked to it, so nothing personal is on the
# OS disk a rebuild replaces. What was already on C: is copied over, never
# deleted, and a rebuilt guest's new account is given its folders. The
# guest-side helpers run here against TestDrive and TestRegistry.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    function New-TestFolder {
        <# A new folder in TestDrive holding $Files, each name => text. #>
        param([hashtable]$Files = @{})

        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        foreach ($name in $Files.Keys) { Set-Content -LiteralPath (Join-Path $path $name) -Value $Files[$name] }
        return $path
    }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

Describe 'Copy-GuestFolderContent' {
    It 'copies every file and keeps the originals' {
        $source = New-TestFolder -Files @{ 'notes.txt' = 'mine' }
        $destination = New-TestFolder

        Copy-GuestFolderContent -Source $source -Destination $destination

        Get-Content -LiteralPath (Join-Path $destination 'notes.txt') | Should -Be 'mine'
        Join-Path $source 'notes.txt' | Should -Exist
    }

    It 'never overwrites a newer file already on the User disk' {
        $source = New-TestFolder -Files @{ 'notes.txt' = 'old' }
        (Get-Item -LiteralPath (Join-Path $source 'notes.txt')).LastWriteTime = (Get-Date).AddDays(-1)
        $destination = New-TestFolder -Files @{ 'notes.txt' = 'new' }

        Copy-GuestFolderContent -Source $source -Destination $destination

        Get-Content -LiteralPath (Join-Path $destination 'notes.txt') | Should -Be 'new'
    }
}

Describe 'Set-GuestFolderLink' {
    It 'copies a real folder onto the User disk, keeps it under another name and links its place there' {
        $profileDir = New-TestFolder
        $link = Join-Path $profileDir '.ssh'
        New-Item -ItemType Directory -Path $link | Out-Null
        Set-Content -LiteralPath (Join-Path $link 'id_ed25519') -Value 'key'
        $target = Join-Path (New-TestFolder) '.ssh'

        $null = Set-GuestFolderLink -Link $link -Target $target

        (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'Junction'
        Get-Content -LiteralPath (Join-Path $target 'id_ed25519') | Should -Be 'key'
        @(Get-ChildItem -LiteralPath $profileDir -Directory -Filter '.ssh.before-user-disk*').Count | Should -Be 1
    }

    It 'links a folder that does not exist yet, making its parent' {
        $link = Join-Path (New-TestFolder) 'source\repos'
        $target = Join-Path (New-TestFolder) 'repos'

        $null = Set-GuestFolderLink -Link $link -Target $target

        (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'Junction'
        Test-Path -LiteralPath $target -PathType Container | Should -BeTrue
    }

    It 'leaves a link that already points at the User disk as it is' {
        $link = Join-Path (New-TestFolder) '.ssh'
        $target = Join-Path (New-TestFolder) '.ssh'
        $null = Set-GuestFolderLink -Link $link -Target $target
        $created = (Get-Item -LiteralPath $link -Force).CreationTimeUtc

        $null = Set-GuestFolderLink -Link $link -Target $target

        (Get-Item -LiteralPath $link -Force).CreationTimeUtc | Should -Be $created
    }

    It 'leaves a link the user pointed somewhere else as it is, and says so' {
        $link = Join-Path (New-TestFolder) 'repos'
        $elsewhere = New-TestFolder
        New-Item -ItemType Junction -Path $link -Value $elsewhere | Out-Null
        $target = Join-Path (New-TestFolder) 'repos'

        $note = Set-GuestFolderLink -Link $link -Target $target

        @((Get-Item -LiteralPath $link -Force).Target) | Should -Contain $elsewhere
        $note.Level | Should -Be 'WARN'
    }
}

Describe 'Set-GuestShellFolder' {
    BeforeEach {
        $key = 'TestRegistry:\User Shell Folders'
        New-Item -Path $key -Force | Out-Null
    }

    It 'copies what the folder holds onto the User disk and points the folder there' {
        $current = New-TestFolder -Files @{ 'report.docx' = 'draft' }
        New-ItemProperty -Path $key -Name 'Personal' -Value $current -PropertyType ExpandString | Out-Null
        $target = Join-Path (New-TestFolder) 'Documents'

        $null = Set-GuestShellFolder -Name 'Personal' -Path $target -Key $key

        (Get-Item -LiteralPath $key).GetValue('Personal') | Should -Be $target
        (Get-Item -LiteralPath $key).GetValueKind('Personal') | Should -Be 'ExpandString'
        Get-Content -LiteralPath (Join-Path $target 'report.docx') | Should -Be 'draft'
        Join-Path $current 'report.docx' | Should -Exist
    }

    It 'points an alias Windows keeps for the folder there too, and adds none it does not have' {
        New-ItemProperty -Path $key -Name 'Personal' -Value '%USERPROFILE%\Documents' -PropertyType ExpandString | Out-Null
        New-ItemProperty -Path $key -Name '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' -Value '%USERPROFILE%\Documents' -PropertyType ExpandString | Out-Null
        $target = Join-Path (New-TestFolder) 'Documents'

        $null = Set-GuestShellFolder -Name 'Personal' -Aliases '{F42EE2D3-909F-4907-8871-4C22FC0BF756}', '{00000000-0000-0000-0000-000000000000}' -Path $target -Key $key

        (Get-Item -LiteralPath $key).GetValue('{F42EE2D3-909F-4907-8871-4C22FC0BF756}') | Should -Be $target
        (Get-Item -LiteralPath $key).GetValueNames() | Should -Not -Contain '{00000000-0000-0000-0000-000000000000}'
    }
}

Describe 'Grant-GuestFolderAccess' {
    It 'gives the account the folder and everything in it, dropping an old install''s account' {
        $folder = New-TestFolder -Files @{ 'a.txt' = 'x' }
        $file = Join-Path $folder 'a.txt'
        # An account from the guest a rebuild replaced: its SID no longer resolves.
        $oldSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $acl = Get-Acl -LiteralPath $file
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($oldSid, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $file -AclObject $acl

        $changed = Grant-GuestFolderAccess -Path $folder -Sid $currentSid

        $changed | Should -BeTrue
        $rules = @((Get-Acl -LiteralPath $file).Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
        $rules | Should -Not -Contain $oldSid.Value
        $rules | Should -Contain $currentSid
    }

    It 'changes nothing once the folder is the account''s alone' {
        $folder = New-TestFolder
        $null = Grant-GuestFolderAccess -Path $folder -Sid $currentSid

        Grant-GuestFolderAccess -Path $folder -Sid $currentSid | Should -BeFalse
    }
}

Describe 'Get-GuestUserFolderProblem' {
    BeforeEach {
        $key = 'TestRegistry:\User Shell Folders'
        New-Item -Path $key -Force | Out-Null
        $disk = New-TestFolder
        $profileDir = New-TestFolder
    }

    It 'finds nothing wrong once every folder is on the User disk' {
        $folders = @(
            @{ Name = 'Documents'; ShellFolder = 'Personal' }
            @{ Name = '.ssh'; Link = '.ssh' }
        )
        New-ItemProperty -Path $key -Name 'Personal' -Value "$disk\Documents" -PropertyType ExpandString | Out-Null
        New-Item -ItemType Directory -Path "$disk\.ssh" | Out-Null
        New-Item -ItemType Junction -Path "$profileDir\.ssh" -Value "$disk\.ssh" | Out-Null

        Get-GuestUserFolderProblem -Folders $folders -Root $disk -ProfileDir $profileDir -Key $key | Should -BeNullOrEmpty
    }

    It 'reports a folder still on the OS disk' {
        $folders = @(@{ Name = 'Documents'; ShellFolder = 'Personal' })
        New-ItemProperty -Path $key -Name 'Personal' -Value '%USERPROFILE%\Documents' -PropertyType ExpandString | Out-Null

        Get-GuestUserFolderProblem -Folders $folders -Root $disk -ProfileDir $profileDir -Key $key | Should -BeLike '*Documents*'
    }

    It 'reports a folder that is not linked' {
        $folders = @(@{ Name = '.ssh'; Link = '.ssh' })
        New-Item -ItemType Directory -Path "$profileDir\.ssh" | Out-Null

        Get-GuestUserFolderProblem -Folders $folders -Root $disk -ProfileDir $profileDir -Key $key | Should -BeLike '*.ssh*'
    }
}
