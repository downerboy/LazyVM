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
    Mock -ModuleName $module Get-TaskUserName { 'MIKEPC\sean' }

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
    It 're-encrypts a credential for the current user, keeping the account and password' {
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
            (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).Protection | Should -Be 'DPAPI-CurrentUser'
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

Describe 'Move-LegacyTask (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Register-LazyVMHostTask { }
        Mock -ModuleName $module Get-ScheduledTask {
            [pscustomobject]@{ TaskName = 'LazyVM-Maintain-Alpha'; Principal = [pscustomobject]@{ UserId = 'SYSTEM' }; Actions = @('maintain'); Triggers = @('daily'); Settings = 'settings' }
            [pscustomobject]@{ TaskName = 'LazyVM-Maintain-Other'; Principal = [pscustomobject]@{ UserId = 'MIKEPC\kim' }; Actions = @('other'); Triggers = @('daily'); Settings = 'settings' }
        }
    }

    It 're-registers each task that runs as SYSTEM to run as the user, keeping what it does and when' {
        InModuleScope $module { Move-LegacyTask }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-Maintain-Alpha' -and @($Action) -contains 'maintain' -and @($Trigger) -contains 'daily' -and $Settings -eq 'settings'
        }
    }

    It 'leaves another user''s tasks alone' {
        InModuleScope $module { Move-LegacyTask }

        Should -Invoke -ModuleName $module Register-LazyVMHostTask -Times 0 -ParameterFilter { $TaskName -eq 'LazyVM-Maintain-Other' }
    }

    It 'looks only at LazyVM''s tasks' {
        InModuleScope $module { Move-LegacyTask }

        Should -Invoke -ModuleName $module Get-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'LazyVM-*' }
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
        Mock -ModuleName $module Get-FolderSize { 100GB }
        Mock -ModuleName $module Get-FreeSpace { 500GB }
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

    It 'stops before moving anything when the drive has too little free space for the copy' {
        Mock -ModuleName $module Get-FreeSpace { 50GB }

        { InModuleScope $module { Move-LegacyVMStorage -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' } } | Should -Throw -ExpectedMessage '*free space*MSDevBox*'

        Should -Invoke -ModuleName $module Move-VMStorage -Times 0
    }
}

Describe 'The ISOs attached from the old folder (#284)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'MSDevBox' } }
        Mock -ModuleName $module Get-VMDvdDrive {
            [pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 1; Path = 'C:\LazyVM\Shared\ISO\Win11.iso' }
            [pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 2; Path = 'D:\ISO\tools.iso' }
            [pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 3; Path = $null }
        }
        Mock -ModuleName $module Set-VMDvdDrive { }
    }

    It 'are ejected before their files move, and only they' {
        $media = @(InModuleScope $module { Dismount-LegacyDvdMedia -OldRoot 'C:\LazyVM' })

        $media.Count | Should -Be 1
        Should -Invoke -ModuleName $module Set-VMDvdDrive -Times 1 -Exactly -ParameterFilter { $ControllerLocation -eq 1 -and -not $Path }
    }

    It 'are attached again from the new folder' {
        $media = @([pscustomobject]@{ VMName = 'MSDevBox'; ControllerNumber = 0; ControllerLocation = 1; Path = 'C:\LazyVM\Shared\ISO\Win11.iso' })

        InModuleScope $module -Parameters @{ Media = $media } { param($Media) Mount-MovedDvdMedia -Media $Media -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Set-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
            $VMName -eq 'MSDevBox' -and $ControllerLocation -eq 1 -and $Path -eq 'C:\Users\sean\LazyVM\Shared\ISO\Win11.iso'
        }
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

    It 'records the new folder and every interrupted build''s resume phase for the user' {
        InModuleScope $module { Copy-LegacyRegistry -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Users\sean\LazyVM' }
        Should -Invoke -ModuleName $module Set-ResumePhase -Times 1 -Exactly -ParameterFilter { $Key -eq 'HKCU:\SOFTWARE\LazyVM\MSDevBox' -and $Phase -eq 7 }
    }
}

Describe 'Invoke-InstallationMigration (#284)' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Start-Log { }
        Mock -ModuleName $module Stop-Log { }
        Mock -ModuleName $module Assert-NoRunningTask { $script:calls.Add('check tasks') }
        Mock -ModuleName $module Move-LegacyTask { $script:calls.Add('tasks') }
        Mock -ModuleName $module Convert-LegacyCredential { $script:calls.Add('credentials') }
        Mock -ModuleName $module Initialize-RootFolder { $script:calls.Add("lock $Path") }
        Mock -ModuleName $module Move-LegacyVMStorage { $script:calls.Add('vm storage') }
        Mock -ModuleName $module Dismount-LegacyDvdMedia { $script:calls.Add('eject'); 'media' }
        Mock -ModuleName $module Move-LegacyFile { $script:calls.Add('files') }
        Mock -ModuleName $module Mount-MovedDvdMedia { $script:calls.Add('attach') }
        Mock -ModuleName $module Copy-LegacyRegistry { $script:calls.Add('registry') }
        Mock -ModuleName $module Remove-LegacyInstallation { $script:calls.Add('remove legacy') }
        Mock -ModuleName $module Write-LogError { }
    }

    It 'moves everything, then locks the new folder again, and removes the old install last' {
        InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        $script:calls | Should -Be @('check tasks', 'lock C:\Users\sean\LazyVM', 'tasks', 'credentials', 'vm storage', 'eject', 'files', 'attach', 'registry', 'lock C:\Users\sean\LazyVM', 'remove legacy')
    }

    It 'keeps the data where it is when the new folder is the old one, and only locks it' {
        InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'C:\LazyVM' }

        $script:calls | Should -Be @('check tasks', 'lock C:\LazyVM', 'tasks', 'credentials', 'registry', 'lock C:\LazyVM', 'remove legacy')
    }

    It 'removes nothing of the old install when a step fails' {
        Mock -ModuleName $module Move-LegacyFile { throw 'disk full' }

        { InModuleScope $module { Invoke-InstallationMigration -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' } } | Should -Throw -ExpectedMessage '*disk full*'

        $script:calls | Should -Not -Contain 'remove legacy'
        $script:calls | Should -Not -Contain 'registry'
    }

    It 'refuses a new folder inside the old one, or the other way round' -ForEach @(
        @{ New = 'C:\LazyVM\New' }
        @{ New = 'C:\Lazy' ; Old = 'C:\Lazy\VM' }
    ) {
        $oldRoot = if ($Old) { $Old } else { 'C:\LazyVM' }

        { InModuleScope $module -Parameters @{ Old = $oldRoot; New = $New } { param($Old, $New) Invoke-InstallationMigration -OldRoot $Old -NewRoot $New } } |
            Should -Throw -ExpectedMessage '*inside*'

        $script:calls | Should -BeNullOrEmpty
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
        # Not set on a runner that is not Windows.
        $savedProgramFiles = $env:ProgramFiles
        if (-not $env:ProgramFiles) { $env:ProgramFiles = $TestDrive }
    }

    AfterAll {
        $env:ProgramFiles = $savedProgramFiles
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Remove-Item { }
        Mock -ModuleName $module Test-Path { $true }
        Mock -ModuleName $module Get-ChildItem { }
    }

    It 'removes the old folder once it is empty, the machine-wide module copy, and the HKLM key last' {
        $script:removed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Remove-Item { $script:removed.Add($LiteralPath) }

        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        $removed = $script:removed
        $removed[0] | Should -Be 'C:\LazyVM'
        $removed | Should -Contain (Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules\LazyVM')
        $removed[-1] | Should -Be 'HKLM:\SOFTWARE\LazyVM'
    }

    It 'keeps an old folder that still holds something, and says so' {
        Mock -ModuleName $module Get-ChildItem { [IO.FileInfo]::new('C:\LazyVM\stray.txt') } -ParameterFilter { $LiteralPath -eq 'C:\LazyVM' }

        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' -NewRoot 'C:\Users\sean\LazyVM' }

        Should -Invoke -ModuleName $module Remove-Item -Times 0 -ParameterFilter { $LiteralPath -eq 'C:\LazyVM' }
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*C:\LazyVM*still holds*' -and $Level -eq 'WARN' }
    }

    It 'keeps the old folder when it is the new one' {
        InModuleScope $module { Remove-LegacyInstallation -OldRoot 'C:\LazyVM' -NewRoot 'C:\LazyVM' }

        Should -Invoke -ModuleName $module Remove-Item -Times 0 -ParameterFilter { $LiteralPath -eq 'C:\LazyVM' }
    }
}

Describe 'Convert-LazyVMInstallation (#284)' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Get-LegacyRoot { 'C:\LazyVM' }
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

    It 'changes nothing with -WhatIf' {
        Convert-LazyVMInstallation -WhatIf

        Should -Invoke -ModuleName $module Invoke-InstallationMigration -Times 0
    }

    It 'says there is nothing to move when LazyVM is already installed per user' {
        Mock -ModuleName $module Get-LegacyRoot { $null }

        $null = Convert-LazyVMInstallation -Confirm:$false -InformationVariable info 6> $null

        "$info" | Should -BeLike '*nothing to move*'
        Should -Invoke -ModuleName $module Invoke-InstallationMigration -Times 0
    }
}
