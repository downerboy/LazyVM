# Migration.Tests.ps1
# Convert-LazyVMInstallation (#284): moves a machine-wide install (C:\LazyVM,
# the HKLM key, SYSTEM tasks, credentials encrypted with a key file) to the
# current user, one step at a time, each of which can be run again after an
# interruption. Hyper-V, Task Scheduler and the registry are mocked; files
# are real, under TestDrive.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    Mock -ModuleName $module Get-CurrentUserName { 'MIKEPC\sean' }

    function New-LegacyKey {
        <# A key file as LazyVM 5 made it, under $Root\Shared\Credentials. Returns the key. #>
        param([Parameter(Mandatory)][string]$Root)
        $key = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($key)
        $folder = Join-Path -Path $Root -ChildPath 'Shared/Credentials'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path -Path $folder -ChildPath '.lazyvm.key'), $key)
        return , $key
    }

    function New-LegacyCredential {
        <# A credential file as LazyVM 5 wrote it, encrypted with $Key. #>
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][byte[]]$Key,
            [string]$UserName = 'devadmin',
            [string]$Secret = 'Old-Secret-1'
        )
        New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
        $secure = [Net.NetworkCredential]::new('', $Secret).SecurePassword
        $blob = [pscustomobject]@{ UserName = $UserName; Password = ConvertFrom-SecureString -SecureString $secure -Key $Key }
        Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject $blob)
    }

    function New-TestFolder {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path | Out-Null
        return $path
    }
}

Describe 'Get-LegacyCredentialKeyPath (#284)' {
    It 'is Shared\Credentials\.lazyvm.key in the old folder by default' {
        $root = New-TestFolder

        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Get-LegacyCredentialKeyPath -Root $Root -VMName 'Alpha' } |
            Should -Be ([IO.Path]::Combine($root, 'Shared', 'Credentials', '.lazyvm.key'))
    }

    It 'follows CredStoreDir from <Source>' -ForEach @(
        @{ Source = 'the VM''s VM.json'; File = 'Alpha/Config/VM.json' }
        @{ Source = 'the shared settings'; File = 'Shared/Config/LazyVM.Settings.json' }
    ) {
        $root = New-TestFolder
        $path = Join-Path -Path $root -ChildPath $File
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value '{ "CredStoreDir": "Keys\\{VM}" }'

        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Get-LegacyCredentialKeyPath -Root $Root -VMName 'Alpha' } |
            Should -Be ([IO.Path]::Combine($root, 'Keys', 'Alpha', '.lazyvm.key'))
    }

    It 'keeps a CredStoreDir that is a full path' {
        $root = New-TestFolder
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Shared/Config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Shared/Config/LazyVM.Settings.json') -Value '{ "CredStoreDir": "E:\\Keys" }'

        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Get-LegacyCredentialKeyPath -Root $Root -VMName 'Alpha' } |
            Should -Be 'E:\Keys\.lazyvm.key'
    }
}

Describe 'Convert-LegacyCredentialFile (#284)' {
    It 're-encrypts a credential for this computer, keeping the account and password' {
        $root = New-TestFolder
        $key = New-LegacyKey -Root $root
        $cred = Join-Path -Path $root -ChildPath 'Alpha/Credentials/guest.cred'
        New-LegacyCredential -Path $cred -Key $key

        $converted = InModuleScope $module -Parameters @{ Root = $root; File = $cred } {
            param($Root, $File)
            Convert-LegacyCredentialFile -KeyPath "$Root/Shared/Credentials/.lazyvm.key" -Path $File
        }

        $converted | Should -BeTrue
        $stored = InModuleScope $module -Parameters @{ File = $cred } { param($File) Get-StoredCredential -Path $File }
        $stored.UserName | Should -Be 'devadmin'
        $stored.GetNetworkCredential().Password | Should -Be 'Old-Secret-1'
    }

    It 'leaves a credential that is already re-encrypted alone' {
        $root = New-TestFolder
        $cred = Join-Path -Path $root -ChildPath 'Alpha/Credentials/guest.cred'
        InModuleScope $module -Parameters @{ File = $cred } {
            param($File)
            Save-StoredCredential -Path $File -UserName 'devadmin' -Password ([Net.NetworkCredential]::new('', 'New-Secret-2').SecurePassword)
        }
        $before = Get-Content -LiteralPath $cred -Raw

        $converted = InModuleScope $module -Parameters @{ Root = $root; File = $cred } {
            param($Root, $File)
            Convert-LegacyCredentialFile -KeyPath "$Root/Shared/Credentials/.lazyvm.key" -Path $File
        }

        $converted | Should -BeFalse
        Get-Content -LiteralPath $cred -Raw | Should -Be $before
    }

    It 'stops, leaving the file as it was, when <Case>' -ForEach @(
        @{ Case = 'the key is missing'; KeyBytes = 0; Message = '*key*is missing*' }
        @{ Case = 'the key is damaged'; KeyBytes = 5; Message = '*damaged*' }
    ) {
        $root = New-TestFolder
        $cred = Join-Path -Path $root -ChildPath 'Alpha/Credentials/guest.cred'
        New-LegacyCredential -Path $cred -Key ([byte[]]::new(32))
        if ($KeyBytes) {
            New-Item -ItemType Directory -Path "$root/Shared/Credentials" -Force | Out-Null
            [IO.File]::WriteAllBytes("$root/Shared/Credentials/.lazyvm.key", [byte[]]::new($KeyBytes))
        }
        $before = Get-Content -LiteralPath $cred -Raw

        {
            InModuleScope $module -Parameters @{ Root = $root; File = $cred } {
                param($Root, $File)
                Convert-LegacyCredentialFile -KeyPath "$Root/Shared/Credentials/.lazyvm.key" -Path $File
            }
        } | Should -Throw -ExpectedMessage $Message
        Get-Content -LiteralPath $cred -Raw | Should -Be $before
    }
}

Describe 'Convert-LegacyCredential (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 're-encrypts every VM''s credentials, then deletes the key nobody needs any more' {
        $root = New-TestFolder
        $key = New-LegacyKey -Root $root
        New-LegacyCredential -Path "$root/Alpha/Credentials/guest.cred" -Key $key
        New-LegacyCredential -Path "$root/Alpha/Credentials/bitlocker.cred" -Key $key -UserName 'bitlocker' -Secret '{"D:":"111111-222222"}'
        New-LegacyCredential -Path "$root/Beta/Credentials/guest.cred" -Key $key

        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Convert-LegacyCredential -Root $Root }

        foreach ($file in "$root/Alpha/Credentials/guest.cred", "$root/Alpha/Credentials/bitlocker.cred", "$root/Beta/Credentials/guest.cred") {
            (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).Protection | Should -Be 'DPAPI-LocalMachine'
        }
        "$root/Shared/Credentials/.lazyvm.key" | Should -Not -Exist
    }

    It 'keeps the key, and every file it still opens, when one credential cannot be re-encrypted' {
        $root = New-TestFolder
        $key = New-LegacyKey -Root $root
        New-LegacyCredential -Path "$root/Alpha/Credentials/guest.cred" -Key $key
        New-LegacyCredential -Path "$root/Beta/Credentials/guest.cred" -Key ([byte[]]::new(32))

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Convert-LegacyCredential -Root $Root } } | Should -Throw

        "$root/Shared/Credentials/.lazyvm.key" | Should -Exist
        (Get-Content -LiteralPath "$root/Beta/Credentials/guest.cred" -Raw | ConvertFrom-Json).PSObject.Properties['Protection'] | Should -BeNullOrEmpty
    }

    It 'does nothing the second time' {
        $root = New-TestFolder
        $key = New-LegacyKey -Root $root
        New-LegacyCredential -Path "$root/Alpha/Credentials/guest.cred" -Key $key
        InModuleScope $module -Parameters @{ Root = $root } { param($Root) Convert-LegacyCredential -Root $Root }
        $before = Get-Content -LiteralPath "$root/Alpha/Credentials/guest.cred" -Raw

        { InModuleScope $module -Parameters @{ Root = $root } { param($Root) Convert-LegacyCredential -Root $Root } } | Should -Not -Throw

        Get-Content -LiteralPath "$root/Alpha/Credentials/guest.cred" -Raw | Should -Be $before
    }
}

Describe 'Update-LegacyTask (#284)' {
    BeforeAll {
        # Real task parts, as Get-ScheduledTask returns them.
        $script:oldTrigger = New-ScheduledTaskTrigger -Daily -At '02:00'
        $script:oldSettings = New-ScheduledTaskSettingsSet
        $script:oldAction = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "Import-Module -Name 'LazyVM'; Invoke-LazyVMMaintenance -Name 'Alpha'"
    }

    BeforeEach {
        $script:oldRoot = New-TestFolder
        $script:newRoot = New-TestFolder
        New-Item -ItemType File -Path (Join-Path -Path $script:oldRoot -ChildPath 'Alpha/Config/VM.json') -Force | Out-Null
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Register-LazyVMHostTask { }
        Mock -ModuleName $module Get-ScheduledTask {
            foreach ($name in 'LazyVM-Maintain-Alpha', 'LazyVM-Maintain-Other', 'LazyVM-Unknown') {
                [pscustomobject]@{ TaskName = $name; Principal = [pscustomobject]@{ UserId = 'SYSTEM' }; Actions = @($script:oldAction); Triggers = @($script:oldTrigger); Settings = $script:oldSettings }
            }
        }
    }

    It 'registers this install''s tasks again, keeping when they run, with an action naming the new folder' {
        InModuleScope $module -Parameters @{ Old = $script:oldRoot; New = $script:newRoot } { param($Old, $New) Update-LegacyTask -OldRoot $Old -NewRoot $New }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-Maintain-Alpha' -and
            "$(@($Action)[0].Arguments)" -like "*Invoke-LazyVMMaintenance -Name 'Alpha' -Root '$script:newRoot'*" -and
            @($Trigger)[0] -eq $script:oldTrigger -and $Settings -eq $script:oldSettings
        }
    }

    It 'leaves the tasks of VMs that are not in this install alone' {
        InModuleScope $module -Parameters @{ Old = $script:oldRoot; New = $script:newRoot } { param($Old, $New) Update-LegacyTask -OldRoot $Old -NewRoot $New }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 0 -ParameterFilter { $TaskName -eq 'LazyVM-Maintain-Other' }
    }

    It 'leaves a task LazyVM does not make as it was, and says so' {
        InModuleScope $module -Parameters @{ Old = $script:oldRoot; New = $script:newRoot } { param($Old, $New) Update-LegacyTask -OldRoot $Old -NewRoot $New }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 0 -ParameterFilter { $TaskName -eq 'LazyVM-Unknown' }
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*LazyVM-Unknown*left as it was*' -and $Level -eq 'WARN' }
    }

    It 'finds a VM already moved to the new folder, when it runs again' {
        Move-Item -LiteralPath (Join-Path -Path $script:oldRoot -ChildPath 'Alpha') -Destination $script:newRoot

        InModuleScope $module -Parameters @{ Old = $script:oldRoot; New = $script:newRoot } { param($Old, $New) Update-LegacyTask -OldRoot $Old -NewRoot $New }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LazyVM-Maintain-Alpha' }
    }
}

Describe 'ConvertTo-NewRootPath (#284)' {
    It 'maps <Path> to <Expected>' -ForEach @(
        @{ Path = 'C:\LazyVM\Alpha\Disks\Alpha-OS.vhdx'; Expected = 'C:\Users\sean\LazyVM\Alpha\Disks\Alpha-OS.vhdx' }
        @{ Path = 'c:\lazyvm\Alpha'; Expected = 'C:\Users\sean\LazyVM\Alpha' }
        @{ Path = 'C:\LazyVM'; Expected = 'C:\Users\sean\LazyVM' }
        @{ Path = 'E:\VMs\Alpha-OS.vhdx'; Expected = $null }
        @{ Path = 'C:\LazyVMOther\x.vhdx'; Expected = $null }
    ) {
        InModuleScope $module -Parameters @{ Path = $Path } {
            param($Path)
            ConvertTo-NewRootPath -Path $Path -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM'
        } | Should -Be $Expected
    }
}

Describe 'Move-LegacyVMStorage (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM {
            [pscustomobject]@{ Name = 'MSDevBox'; ConfigurationLocation = 'C:\LazyVM\MSDevBox'; SnapshotFileLocation = 'C:\LazyVM\MSDevBox\Checkpoints'; SmartPagingFilePath = 'C:\LazyVM\MSDevBox' }
            [pscustomobject]@{ Name = 'Elsewhere'; ConfigurationLocation = 'D:\Hyper-V\Elsewhere'; SnapshotFileLocation = 'D:\Hyper-V\Elsewhere'; SmartPagingFilePath = 'D:\Hyper-V\Elsewhere' }
        }
        Mock -ModuleName $module Get-VMHardDiskDrive {
            if ($VMName -eq 'MSDevBox') {
                [pscustomobject]@{ Path = 'C:\LazyVM\MSDevBox\Disks\MSDevBox-OS_8A1B.avhdx' }
                [pscustomobject]@{ Path = 'C:\LazyVM\MSDevBox\Disks\MSDevBox-SQL.vhdx' }
            }
            else { [pscustomobject]@{ Path = 'D:\Hyper-V\Elsewhere\disk.vhdx' } }
        }
        Mock -ModuleName $module Get-Item { [pscustomobject]@{ Length = 40GB } }
        Mock -ModuleName $module Get-FolderSize { 1GB }
        Mock -ModuleName $module Get-FreeSpaceGB { 500 }
        Mock -ModuleName $module Move-VMStorage { }
    }

    It 'moves a VM''s files with Hyper-V while it runs, keeping their layout under the new folder' {
        InModuleScope $module { Move-LegacyVMStorage -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Move-VMStorage -Times 1 -Exactly -ParameterFilter {
            $VMName -eq 'MSDevBox' -and
            $VirtualMachinePath -eq 'C:\Users\sean\LazyVM\MSDevBox' -and
            $SnapshotFilePath -eq 'C:\Users\sean\LazyVM\MSDevBox\Checkpoints' -and
            $SmartPagingFilePath -eq 'C:\Users\sean\LazyVM\MSDevBox' -and
            @($Vhds).Count -eq 2 -and
            @($Vhds | Where-Object { $_.SourceFilePath -eq 'C:\LazyVM\MSDevBox\Disks\MSDevBox-OS_8A1B.avhdx' -and $_.DestinationFilePath -eq 'C:\Users\sean\LazyVM\MSDevBox\Disks\MSDevBox-OS_8A1B.avhdx' }).Count -eq 1
        }
    }

    It 'leaves VMs whose files are not in the old folder alone, so a second run moves nothing again' {
        InModuleScope $module { Move-LegacyVMStorage -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Move-VMStorage -Times 0 -ParameterFilter { $VMName -eq 'Elsewhere' }
    }

    It 'counts the disks it moves and Hyper-V''s own folders, and nothing else, towards the free space it needs' {
        InModuleScope $module { Move-LegacyVMStorage -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Get-Item -Times 2 -Exactly -ParameterFilter { $LiteralPath -like 'C:\LazyVM\MSDevBox\Disks\*' }
        Should -Invoke -ModuleName $module Get-FolderSize -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\LazyVM\MSDevBox\Virtual Machines' }
        Should -Invoke -ModuleName $module Get-FolderSize -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\LazyVM\MSDevBox\Checkpoints\Snapshots' }
    }

    It 'stops before moving anything when the drive has too little free space for the copy' {
        Mock -ModuleName $module Get-FreeSpaceGB { 50 }

        { InModuleScope $module { Move-LegacyVMStorage -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' } } | Should -Throw -ExpectedMessage '*free space*MSDevBox*'

        Should -Invoke -ModuleName $module Move-VMStorage -Times 0
    }
}

Describe 'Assert-NoVMFileLeft (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'MSDevBox'; ConfigurationLocation = 'C:\Users\sean\LazyVM\MSDevBox'; SnapshotFileLocation = 'C:\Users\sean\LazyVM\MSDevBox\Checkpoints'; SmartPagingFilePath = 'C:\Users\sean\LazyVM\MSDevBox' } }
        Mock -ModuleName $module Get-VMSnapshot { }
        Mock -ModuleName $module Get-VMHardDiskDrive { [pscustomobject]@{ Path = 'C:\Users\sean\LazyVM\MSDevBox\Disks\MSDevBox-OS_8A1B.avhdx' } }
        Mock -ModuleName $module Get-VHD { [pscustomobject]@{ Path = $Path; ParentPath = $null } }
    }

    It 'goes on when no VM uses a file in the old folder any more' {
        { InModuleScope $module { Assert-NoVMFileLeft -OldRoot 'C:\LazyVM' } } | Should -Not -Throw
    }

    It 'stops when the VM still keeps its <Location> in the old folder' -ForEach @(
        @{ Location = 'configuration'; Property = 'ConfigurationLocation' }
        @{ Location = 'checkpoints'; Property = 'SnapshotFileLocation' }
        @{ Location = 'smart paging file'; Property = 'SmartPagingFilePath' }
    ) {
        $machine = [pscustomobject]@{ Name = 'MSDevBox'; ConfigurationLocation = 'C:\Users\sean\LazyVM\MSDevBox'; SnapshotFileLocation = 'C:\Users\sean\LazyVM\MSDevBox\Checkpoints'; SmartPagingFilePath = 'C:\Users\sean\LazyVM\MSDevBox' }
        $machine.$Property = 'C:\LazyVM\MSDevBox'
        Mock -ModuleName $module Get-VM { $machine }.GetNewClosure()

        { InModuleScope $module { Assert-NoVMFileLeft -OldRoot 'C:\LazyVM' } } | Should -Throw -ExpectedMessage '*MSDevBox*C:\LazyVM\MSDevBox*'
    }

    It 'stops, before any file moves, when a checkpoint''s parent disk is still in the old folder' {
        Mock -ModuleName $module Get-VHD {
            if ($Path -like '*.avhdx') { [pscustomobject]@{ Path = $Path; ParentPath = 'C:\LazyVM\MSDevBox\Disks\MSDevBox-OS.vhdx' } }
            else { [pscustomobject]@{ Path = $Path; ParentPath = $null } }
        }

        { InModuleScope $module { Assert-NoVMFileLeft -OldRoot 'C:\LazyVM' } } | Should -Throw -ExpectedMessage '*MSDevBox*C:\LazyVM\MSDevBox\Disks\MSDevBox-OS.vhdx*'
    }

    It 'stops when a checkpoint still has a disk in the old folder' {
        Mock -ModuleName $module Get-VMSnapshot {
            [pscustomobject]@{ VMName = 'MSDevBox'; Name = 'Tooling 20261001-020000'; HardDrives = @([pscustomobject]@{ Path = 'C:\LazyVM\MSDevBox\Disks\MSDevBox-SQL_1.avhdx' }) }
        }

        { InModuleScope $module { Assert-NoVMFileLeft -OldRoot 'C:\LazyVM' } } | Should -Throw -ExpectedMessage '*MSDevBox-SQL_1.avhdx*'
    }
}

Describe 'The ISOs attached from the old folder (#284)' {
    BeforeEach {
        $script:newRoot = New-TestFolder
        $script:noted = Join-Path -Path $script:newRoot -ChildPath 'Shared/Migration.EjectedMedia.json'
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'MSDevBox' } }
        Mock -ModuleName $module Get-VMDvdDrive {
            [pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 1; Path = 'C:\LazyVM\Shared\ISO\Win11.iso' }
            [pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 2; Path = 'D:\ISO\tools.iso' }
            [pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 3; Path = $null }
        }
        $script:notedWhenEjected = $null
        Mock -ModuleName $module Set-VMDvdDrive { if (-not $Path) { $script:notedWhenEjected = Test-Path -LiteralPath $script:noted } }
    }

    It 'are noted in the new folder before they are ejected, and only they are ejected' {
        InModuleScope $module -Parameters @{ NewRoot = $script:newRoot } { param($NewRoot) Dismount-LegacyDvdMedia -OldRoot 'C:\LazyVM' -NewRoot $NewRoot }

        Should -Invoke -ModuleName $module Set-VMDvdDrive -Times 1 -Exactly -ParameterFilter { $ControllerLocation -eq 1 -and -not $Path }
        $script:notedWhenEjected | Should -BeTrue
        @(Get-Content -LiteralPath $script:noted -Raw | ConvertFrom-Json).Path | Should -Be @('C:\LazyVM\Shared\ISO\Win11.iso')
    }

    It 'are attached again from the new folder, on any later run, and then forgotten' {
        InModuleScope $module -Parameters @{ NewRoot = $script:newRoot } { param($NewRoot) Dismount-LegacyDvdMedia -OldRoot 'C:\LazyVM' -NewRoot $NewRoot }

        InModuleScope $module -Parameters @{ NewRoot = $script:newRoot } { param($NewRoot) Mount-MovedDvdMedia -OldRoot 'C:\LazyVM' -NewRoot $NewRoot }

        Should -Invoke -ModuleName $module Set-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
            $VMName -eq 'MSDevBox' -and $ControllerLocation -eq 1 -and $Path -like '*Shared?ISO?Win11.iso' -and $Path -notlike 'C:\LazyVM*'
        }
        $script:noted | Should -Not -Exist
    }

    It 'keeps the note when one cannot be attached again, for the next run' {
        InModuleScope $module -Parameters @{ NewRoot = $script:newRoot } { param($NewRoot) Dismount-LegacyDvdMedia -OldRoot 'C:\LazyVM' -NewRoot $NewRoot }
        Mock -ModuleName $module Set-VMDvdDrive { throw 'The file is in use' } -ParameterFilter { $Path }

        { InModuleScope $module -Parameters @{ NewRoot = $script:newRoot } { param($NewRoot) Mount-MovedDvdMedia -OldRoot 'C:\LazyVM' -NewRoot $NewRoot } } | Should -Throw

        $script:noted | Should -Exist
    }

    It 'does nothing when none were ejected' {
        InModuleScope $module -Parameters @{ NewRoot = $script:newRoot } { param($NewRoot) Mount-MovedDvdMedia -OldRoot 'C:\LazyVM' -NewRoot $NewRoot }

        Should -Invoke -ModuleName $module Set-VMDvdDrive -Times 0
    }
}
Describe 'Move-LegacyFile (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'moves every file to the same place under the new folder and leaves the old folder empty' {
        $old = New-TestFolder
        $new = New-TestFolder
        foreach ($file in 'Shared/Config/LazyVM.Settings.json', 'MSDevBox/Config/VM.json', 'MSDevBox/State/Captures/1/manifest.json') {
            $path = Join-Path -Path $old -ChildPath $file
            New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
            Set-Content -LiteralPath $path -Value $file
        }

        InModuleScope $module -Parameters @{ Old = $old; New = $new } { param($Old, $New) Move-LegacyFile -OldRoot $Old -NewRoot $New }

        Get-Content -LiteralPath (Join-Path -Path $new -ChildPath 'MSDevBox/State/Captures/1/manifest.json') | Should -Be 'MSDevBox/State/Captures/1/manifest.json'
        Get-Content -LiteralPath (Join-Path -Path $new -ChildPath 'Shared/Config/LazyVM.Settings.json') | Should -Be 'Shared/Config/LazyVM.Settings.json'
        @(Get-ChildItem -LiteralPath $old -Recurse -Force) | Should -BeNullOrEmpty
    }

    It 'replaces what an interrupted move left at the new place, since the old file is still the whole one' {
        $old = New-TestFolder
        $new = New-TestFolder
        New-Item -ItemType Directory -Path (Join-Path -Path $old -ChildPath 'MSDevBox/Logs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path -Path $new -ChildPath 'MSDevBox/Logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $old -ChildPath 'MSDevBox/Logs/MSDevBox.log') -Value 'the whole log'
        Set-Content -LiteralPath (Join-Path -Path $new -ChildPath 'MSDevBox/Logs/MSDevBox.log') -Value 'half'

        InModuleScope $module -Parameters @{ Old = $old; New = $new } { param($Old, $New) Move-LegacyFile -OldRoot $Old -NewRoot $New }

        Get-Content -LiteralPath (Join-Path -Path $new -ChildPath 'MSDevBox/Logs/MSDevBox.log') | Should -Be 'the whole log'
    }
}

Describe 'Copy-LegacyRegistry (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-LegacyResumePhase { @{ MSDevBox = 7 } }
        Mock -ModuleName $module Set-ResumePhase { }
        Mock -ModuleName $module Set-RegisteredRoot { }
    }

    It 'records the new folder for the user, and every interrupted build''s resume phase in its VM''s folder' {
        InModuleScope $module { Copy-LegacyRegistry -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Users\sean\LazyVM' }
        Should -Invoke -ModuleName $module Set-ResumePhase -Times 1 -Exactly -ParameterFilter { $Path -like 'C:\Users\sean\LazyVM?MSDevBox?Config?Resume.json' -and $Phase -eq 7 }
    }
}

Describe 'Invoke-InstallationMigration (#284)' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Start-Log { }
        Mock -ModuleName $module Stop-Log { }
        Mock -ModuleName $module Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\LazyVM' }
        Mock -ModuleName $module Update-LegacyTask { $script:calls.Add('tasks') }
        Mock -ModuleName $module Convert-LegacyCredential { $script:calls.Add('credentials') }
        Mock -ModuleName $module Initialize-RootFolder { $script:calls.Add("lock $Path") }
        Mock -ModuleName $module Move-LegacyVMStorage { $script:calls.Add('vm storage') }
        Mock -ModuleName $module Assert-NoVMFileLeft { $script:calls.Add('check vm files') }
        Mock -ModuleName $module Dismount-LegacyDvdMedia { $script:calls.Add('eject') }
        Mock -ModuleName $module Move-LegacyFile { $script:calls.Add('files') }
        Mock -ModuleName $module Mount-MovedDvdMedia { $script:calls.Add('attach') }
        Mock -ModuleName $module Copy-LegacyRegistry { $script:calls.Add('registry') }
        Mock -ModuleName $module Remove-LegacyInstallation { $script:calls.Add("remove legacy$(if ($InPlace) { ' in place' })") }
    }

    It 'moves everything, then locks the new folder again, and removes the old install last' {
        InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        $script:calls | Should -Be @('lock C:\Users\sean\LazyVM', 'tasks', 'credentials', 'vm storage', 'check vm files', 'eject', 'files', 'attach', 'registry', 'lock C:\Users\sean\LazyVM', 'remove legacy')
    }

    It 'keeps the data where it is when the new folder is the old one, and only locks it' {
        InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'c:\lazyvm\' }

        $script:calls | Should -Be @('lock c:\lazyvm\', 'tasks', 'credentials', 'registry', 'lock c:\lazyvm\', 'remove legacy in place')
    }

    It 'goes straight to the registry and the leftovers when a run again finds the old folder gone' {
        Mock -ModuleName $module Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\LazyVM' }

        InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        $script:calls | Should -Be @('lock C:\Users\sean\LazyVM', 'tasks', 'credentials', 'attach', 'registry', 'lock C:\Users\sean\LazyVM', 'remove legacy')
    }

    It 'removes nothing of the old install when a step fails' {
        Mock -ModuleName $module Move-LegacyFile { throw 'disk full' }

        { InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' } } | Should -Throw -ExpectedMessage '*disk full*'

        $script:calls | Should -Not -Contain 'remove legacy'
        $script:calls | Should -Not -Contain 'registry'
    }
}

Describe 'Assert-MigrationTarget (#284)' {
    BeforeEach {
        Mock -ModuleName $module Assert-RootFolderUsable { }
        Mock -ModuleName $module Assert-NoRunningTask { }
    }

    It 'refuses a new folder inside the old one, or the other way round' -ForEach @(
        @{ Old = 'C:\LazyVM'; New = 'C:\LazyVM\New' }
        @{ Old = 'C:\Lazy\VM'; New = 'C:\Lazy' }
    ) {
        { InModuleScope $module -Parameters @{ Old = $Old; New = $New } { param($Old, $New) Assert-MigrationTarget -OldRoot $Old -NewRoot $New } } |
            Should -Throw -ExpectedMessage '*inside*'
    }

    It 'checks the new folder holds nothing else and that no LazyVM task is running' {
        InModuleScope $module { Assert-MigrationTarget -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Assert-RootFolderUsable -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Users\sean\LazyVM' }
        Should -Invoke -ModuleName $module Assert-NoRunningTask -Times 1 -Exactly
    }

    It 'accepts the old folder itself, for a move in place' {
        { InModuleScope $module { Assert-MigrationTarget -OldRoot 'C:\LazyVM' -NewRoot 'C:\LazyVM' } } | Should -Not -Throw
    }
}
Describe 'Assert-NoRunningTask (#284)' {
    It 'stops while a LazyVM task is running, naming it' {
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LazyVM-Maintain-MSDevBox'; State = 'Running' } }

        { InModuleScope $module { Assert-NoRunningTask } } | Should -Throw -ExpectedMessage '*LazyVM-Maintain-MSDevBox*running*'
    }

    It 'goes on when none is running' {
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LazyVM-Maintain-MSDevBox'; State = 'Ready' } }

        { InModuleScope $module { Assert-NoRunningTask } } | Should -Not -Throw
    }
}

Describe 'Remove-LegacyInstallation (#284)' {
    BeforeAll {
        # A folder that is there on any runner, for the module copy's path.
        $savedProgramFiles = $env:ProgramFiles
        $env:ProgramFiles = $TestDrive
    }

    AfterAll {
        $env:ProgramFiles = $savedProgramFiles
    }

    BeforeEach {
        $script:removed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Remove-Item { $script:removed.Add($LiteralPath) }
        Mock -ModuleName $module Test-Path { $true }
        Mock -ModuleName $module Get-ChildItem { }
        Mock -ModuleName $module Test-MachineWideModuleRemovable { $true }
        Mock -ModuleName $module Get-UserModuleFolder { 'C:\Users\sean\AppData\Local\LazyVM\Modules' }
    }

    It 'removes the old folder once it is empty, the machine-wide module copy, and the HKLM key last' {
        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' }

        $script:removed[0] | Should -Be 'C:\LazyVM'
        $script:removed | Should -Contain (Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules\LazyVM')
        $script:removed[-1] | Should -Be 'HKLM:\SOFTWARE\LazyVM'
    }

    It 'keeps an old folder that still holds something, and says so' {
        Mock -ModuleName $module Get-ChildItem { [IO.FileInfo]::new('C:\LazyVM\stray.txt') } -ParameterFilter { $LiteralPath -eq 'C:\LazyVM' }

        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' }

        $script:removed | Should -Not -Contain 'C:\LazyVM'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*C:\LazyVM*still holds*' -and $Level -eq 'WARN' }
    }

    It 'keeps the old folder when the data stayed in it' {
        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' -InPlace }

        $script:removed | Should -Not -Contain 'C:\LazyVM'
    }

    It 'keeps the machine-wide module copy, and says why, when it cannot go yet' {
        Mock -ModuleName $module Test-MachineWideModuleRemovable { $false }

        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' }

        $script:removed | Should -Not -Contain (Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules\LazyVM')
        $script:removed[-1] | Should -Be 'HKLM:\SOFTWARE\LazyVM'
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*Kept the copy of LazyVM installed for every user*' -and $Level -eq 'WARN' }
    }
}

Describe 'Test-MachineWideModuleRemovable (#284)' {
    BeforeEach {
        Mock -ModuleName $module Get-UserModuleFolder { 'C:\Users\sean\AppData\Local\LazyVM\Modules' }
        Mock -ModuleName $module Get-LazyVMModuleBase { 'C:\Users\sean\AppData\Local\LazyVM\Modules\LazyVM\6.0.0' }
        Mock -ModuleName $module Get-Module {
            [pscustomobject]@{ Name = 'LazyVM'; ModuleBase = 'C:\Program Files\PowerShell\Modules\LazyVM\5.2.4' }
            [pscustomobject]@{ Name = 'LazyVM'; ModuleBase = 'C:\Users\sean\AppData\Local\LazyVM\Modules\LazyVM\6.0.0' }
        } -ParameterFilter { $ListAvailable }
    }

    It 'is true when LazyVM runs from the user''s own copy' {
        InModuleScope $module { Test-MachineWideModuleRemovable -Path 'C:\Program Files\PowerShell\Modules\LazyVM' } | Should -BeTrue
    }

    It 'is false while LazyVM runs from the machine-wide copy' {
        Mock -ModuleName $module Get-LazyVMModuleBase { 'C:\Program Files\PowerShell\Modules\LazyVM\6.0.0' }

        InModuleScope $module { Test-MachineWideModuleRemovable -Path 'C:\Program Files\PowerShell\Modules\LazyVM' } | Should -BeFalse
    }

    It 'is false when the user has no copy of their own' {
        Mock -ModuleName $module Get-Module { [pscustomobject]@{ Name = 'LazyVM'; ModuleBase = 'C:\Program Files\PowerShell\Modules\LazyVM\5.2.4' } } -ParameterFilter { $ListAvailable }
        Mock -ModuleName $module Get-LazyVMModuleBase { 'S:\Source\LazyVM\out\LazyVM\6.0.0' }

        InModuleScope $module { Test-MachineWideModuleRemovable -Path 'C:\Program Files\PowerShell\Modules\LazyVM' } | Should -BeFalse
    }
}
Describe 'Convert-LazyVMInstallation (#284)' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Get-RegisteredRoot { 'C:\LazyVM' } -ParameterFilter { $Key -like 'HKLM:*' }
        Mock -ModuleName $module Assert-MigrationTarget { }
        Mock -ModuleName $module Invoke-InstallationMigration { }
        Mock -ModuleName $module Get-DefaultRoot { 'C:\Users\sean\LazyVM' }
    }

    It 'moves the old install to LazyVM in the user''s profile by default' {
        Convert-LazyVMInstallation -Confirm:$false

        Should -Invoke -ModuleName $module Invoke-InstallationMigration -Times 1 -Exactly -ParameterFilter { $OldRoot -eq 'C:\LazyVM' -and $NewRoot -eq 'C:\Users\sean\LazyVM' }
    }

    It 'moves it to the folder given' {
        Convert-LazyVMInstallation -Path 'D:\DevVM' -Confirm:$false

        Should -Invoke -ModuleName $module Invoke-InstallationMigration -Times 1 -Exactly -ParameterFilter { $NewRoot -eq 'D:\DevVM' }
    }

    It 'checks the folders and the tasks before asking, so -WhatIf reports a problem, and changes nothing with -WhatIf' {
        Convert-LazyVMInstallation -WhatIf

        Should -Invoke -ModuleName $module Assert-MigrationTarget -Times 1 -Exactly -ParameterFilter { $OldRoot -eq 'C:\LazyVM' -and $NewRoot -eq 'C:\Users\sean\LazyVM' }
        Should -Invoke -ModuleName $module Invoke-InstallationMigration -Times 0
    }

    It 'stops before asking when the new folder cannot be used' {
        Mock -ModuleName $module Assert-MigrationTarget { throw 'already holds other files' }

        { Convert-LazyVMInstallation -WhatIf } | Should -Throw -ExpectedMessage '*already holds other files*'
    }

    It 'refuses a default folder that is not a usable LazyVM folder, as it would a -Path' {
        Mock -ModuleName $module Get-DefaultRoot { 'C:\Users\sean "quoted"\LazyVM' }

        { Convert-LazyVMInstallation -Confirm:$false } | Should -Throw -ExpectedMessage '*must be a folder on a local drive*'
    }

    It 'says there is nothing to move when LazyVM is already installed per user' {
        Mock -ModuleName $module Get-RegisteredRoot { $null } -ParameterFilter { $Key -like 'HKLM:*' }

        $null = Convert-LazyVMInstallation -Confirm:$false -InformationVariable info 6> $null

        "$info" | Should -BeLike '*nothing to move*'
        Should -Invoke -ModuleName $module Invoke-InstallationMigration -Times 0
    }
}
