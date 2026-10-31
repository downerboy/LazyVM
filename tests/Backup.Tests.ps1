# Backup.Tests.ps1
# Each user database is checked with DBCC CHECKDB before it is backed up, and
# a backup replaces the last good one only once it has been verified, so a
# corrupt database or a failed backup never costs the one good backup kept
# (#133). The User disk is copied, still encrypted, only when its contents
# changed, from a checkpoint taken while the VM runs (#139). Nothing here
# needs Hyper-V, a guest or SQL Server.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')
}

Describe 'Backup-GuestSqlDatabase' {
    BeforeEach {
        $backupDir = Join-Path $TestDrive 'SQLBackup'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $good = Join-Path $backupDir 'Sales.bak'
        Set-Content -LiteralPath $good -Value 'last good'
        $script:statements = @()
        # BACKUP writes the file it names; everything else just runs.
        Mock Invoke-GuestSql {
            $script:statements += $Sql
            if ($Sql -match "^BACKUP DATABASE .* TO DISK = N'(?<file>[^']+)'") { Set-Content -LiteralPath $Matches.file -Value 'new' }
        }
    }

    It 'checks the database, then backs it up to a new file that replaces the last good one once verified' {
        $file = Backup-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -BackupDir $backupDir

        $file | Should -Be $good
        $script:statements[0] | Should -BeLike 'DBCC CHECKDB (N''Sales'')*'
        $script:statements[1] | Should -BeLike "BACKUP DATABASE [[]Sales] TO DISK = N'$good.new' WITH *CHECKSUM*COMPRESSION*"
        $script:statements[2] | Should -BeLike "RESTORE VERIFYONLY FROM DISK = N'$good.new' WITH CHECKSUM"
        Get-Content -LiteralPath $good | Should -Be 'new'
        "$good.new" | Should -Not -Exist
    }

    It 'backs up nothing and keeps the last good backup when the check finds corruption' {
        Mock Invoke-GuestSql { $script:statements += $Sql; if ($Sql -like 'DBCC CHECKDB*') { throw 'Table error: object ID 5' } }

        { Backup-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -BackupDir $backupDir } | Should -Throw '*Table error*'

        $script:statements -like 'BACKUP*' | Should -BeNullOrEmpty
        Get-Content -LiteralPath $good | Should -Be 'last good'
    }

    It 'keeps the last good backup and removes the new file when the new backup does not verify' {
        Mock Invoke-GuestSql {
            if ($Sql -match "^BACKUP DATABASE .* TO DISK = N'(?<file>[^']+)'") { Set-Content -LiteralPath $Matches.file -Value 'new' }
            if ($Sql -like 'RESTORE VERIFYONLY*') { throw 'The backup set is not valid' }
        }

        { Backup-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -BackupDir $backupDir } | Should -Throw '*not valid*'

        Get-Content -LiteralPath $good | Should -Be 'last good'
        "$good.new" | Should -Not -Exist
    }
}

Describe 'Backup-GuestUserDatabase' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Connect-GuestSqlInstance { [pscustomobject]@{ Instance = 'MSSQLSERVER' } }
        Mock -ModuleName $module Invoke-GuestScript { @('Hr', 'Sales') } -ParameterFilter { $Activity -eq 'SQL user database list' }
        Mock -ModuleName $module Backup-GuestDatabase { if ($Name -eq 'Hr') { throw 'Table error: object ID 5' }; [pscustomobject]@{ Name = $Name; SizeBytes = 10 } }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestDataDriveLetter = 'S'; SqlBackupFolder = 'SQLBackup' }) }
    }

    It 'backs up every user database and carries on past one whose check or backup fails' {
        $backups = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-GuestUserDatabase -VM $VM })

        @($backups).Name | Should -Be @('Sales')
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -ParameterFilter { $Context -like '*Hr*' }
    }

    It 'backs up nothing when the guest has no SQL Server' {
        Mock -ModuleName $module Connect-GuestSqlInstance { $null }

        $backups = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-GuestUserDatabase -VM $VM })

        $backups.Count | Should -Be 0
        Should -Invoke -ModuleName $module Backup-GuestDatabase -Times 0
    }
}

Describe 'Get-UserDiskBackupPath' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $settings = @{ VMName = 'Alpha'; VMRoot = (Join-Path $TestDrive 'Alpha'); BackupDir = $null }
    }

    It 'keeps the copy in the VM''s Backups folder when no BackupDir is set' {
        $vm = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }

        $path = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-UserDiskBackupPath -VM $VM }

        $path | Should -Be (Join-Path $TestDrive 'Alpha\Backups\Alpha-User.vhdx')
    }

    It 'keeps the copy in BackupDir when it is set and present' {
        $settings.BackupDir = Join-Path $TestDrive 'External'
        New-Item -ItemType Directory -Path $settings.BackupDir -Force | Out-Null
        $vm = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }

        $path = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-UserDiskBackupPath -VM $VM }

        $path | Should -Be (Join-Path $TestDrive 'External\Alpha-User.vhdx')
    }

    It 'gives no path, with a warning, when BackupDir is set but missing' {
        $settings.BackupDir = Join-Path $TestDrive 'Unplugged'
        $vm = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }

        $path = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-UserDiskBackupPath -VM $VM }

        $path | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*Unplugged*' }
    }
}

Describe 'Backup-UserDisk' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $root = Join-Path $TestDrive 'Alpha'
        $userDisk = Join-Path $root 'Disks\Alpha-User.vhdx'
        New-Item -ItemType Directory -Path (Split-Path $userDisk) -Force | Out-Null
        Set-Content -LiteralPath $userDisk -Value 'disk'
        $copy = Join-Path $root 'Backups\Alpha-User.vhdx'
        Remove-Item -LiteralPath (Split-Path $copy) -Recurse -Force -ErrorAction SilentlyContinue
        $vm = InModuleScope $module -Parameters @{ Root = $root; UserDisk = $userDisk } {
            param($Root, $UserDisk)
            [VMContext]::new(@{ VMName = 'Alpha'; VMRoot = $Root; UserDiskPath = $UserDisk; UserDiskSizeGB = 20; BackupDir = $null })
        }
        $script:snapshot = [pscustomobject]@{ Files = 3; Bytes = 1000; NewestWrite = '2026-10-30T10:00:00.0000000Z'; Encrypted = $true }
        Mock -ModuleName $module Get-GuestUserDiskSnapshot { $script:snapshot }
        Mock -ModuleName $module Copy-UserDiskVhd { New-Item -ItemType Directory -Path (Split-Path $Destination) -Force | Out-Null; Set-Content -LiteralPath $Destination -Value 'copy' }
    }

    It 'copies the User disk when there is no copy yet' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Copy-UserDiskVhd -Times 1 -Exactly -ParameterFilter { $Destination -eq $copy }
    }

    It 'copies nothing when the User disk has not changed since its copy' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Copy-UserDiskVhd -Times 1 -Exactly
    }

    It 'copies the User disk again when a file on it changed' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }
        $script:snapshot = [pscustomobject]@{ Files = 3; Bytes = 1000; NewestWrite = '2026-10-31T09:00:00.0000000Z'; Encrypted = $true }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Copy-UserDiskVhd -Times 2 -Exactly
    }

    It 'copies the User disk again when its copy is gone' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }
        Remove-Item -LiteralPath $copy

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Copy-UserDiskVhd -Times 2 -Exactly
    }

    It 'copies nothing, with a warning, until BitLocker has encrypted the whole disk' {
        $script:snapshot = [pscustomobject]@{ Files = 3; Bytes = 1000; NewestWrite = '2026-10-30T10:00:00.0000000Z'; Encrypted = $false }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Copy-UserDiskVhd -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*BitLocker*' }
    }

    It 'warns when the files on the User disk come close to its size' {
        $script:snapshot = [pscustomobject]@{ Files = 3; Bytes = 18GB; NewestWrite = '2026-10-30T10:00:00.0000000Z'; Encrypted = $true }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*Downloads*' }
    }

    It 'asks the guest nothing when the copy has nowhere to go' {
        Mock -ModuleName $module Get-UserDiskBackupPath { $null }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Backup-UserDisk -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestUserDiskSnapshot -Times 0
        Should -Invoke -ModuleName $module Copy-UserDiskVhd -Times 0
    }
}

Describe 'Copy-UserDiskVhd' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module New-ToolingCheckpoint { }
        Mock -ModuleName $module Remove-VMSnapshot { }
        # After the checkpoint the VM writes to a new .avhdx; the User disk's
        # contents at the checkpoint are the chain that file differences from.
        Mock -ModuleName $module Get-VMHardDiskDrive { [pscustomobject]@{ Path = 'C:\VM\Alpha-User_3F0A.avhdx' } }
        Mock -ModuleName $module Get-VHD { [pscustomobject]@{ Path = $Path; ParentPath = 'C:\VM\Alpha-User_1B2C.avhdx' } } -ParameterFilter { $Path -eq 'C:\VM\Alpha-User_3F0A.avhdx' }
        Mock -ModuleName $module Get-VHD { [pscustomobject]@{ Path = $Path; ParentPath = 'C:\VM\Alpha-User.vhdx' } } -ParameterFilter { $Path -eq 'C:\VM\Alpha-User_1B2C.avhdx' }
        Mock -ModuleName $module Get-VHD { [pscustomobject]@{ Path = $Path; ParentPath = '' } } -ParameterFilter { $Path -eq 'C:\VM\Alpha-User.vhdx' }
        Mock -ModuleName $module Convert-VHD { Set-Content -LiteralPath $DestinationPath -Value 'new copy' }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; UserDiskPath = 'C:\VM\Alpha-User.vhdx' }) }
        $copy = Join-Path $TestDrive 'Backups\Alpha-User.vhdx'
        New-Item -ItemType Directory -Path (Split-Path $copy) -Force | Out-Null
        Set-Content -LiteralPath $copy -Value 'old copy'
    }

    It 'takes a checkpoint, copies the disk as it was then into one file, and merges the checkpoint' {
        InModuleScope $module -Parameters @{ VM = $vm; Copy = $copy } { param($VM, $Copy) Copy-UserDiskVhd -VM $VM -Destination $Copy }

        Should -Invoke -ModuleName $module New-ToolingCheckpoint -Times 1 -Exactly -ParameterFilter { $Name -like 'User disk backup *' }
        Should -Invoke -ModuleName $module Convert-VHD -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\VM\Alpha-User_1B2C.avhdx' -and "$VHDType" -eq 'Dynamic' }
        Should -Invoke -ModuleName $module Remove-VMSnapshot -Times 1 -Exactly -ParameterFilter { $Name -like 'User disk backup *' }
        Get-Content -LiteralPath $copy | Should -Be 'new copy'
        Join-Path $TestDrive 'Backups\Alpha-User.new.vhdx' | Should -Not -Exist
    }

    It 'keeps the last copy and still merges the checkpoint when the copy fails' {
        Mock -ModuleName $module Convert-VHD { Set-Content -LiteralPath $DestinationPath -Value 'partial'; throw 'There is not enough space on the disk.' }

        { InModuleScope $module -Parameters @{ VM = $vm; Copy = $copy } { param($VM, $Copy) Copy-UserDiskVhd -VM $VM -Destination $Copy } } | Should -Throw '*not enough space*'

        Should -Invoke -ModuleName $module Remove-VMSnapshot -Times 1 -Exactly
        Get-Content -LiteralPath $copy | Should -Be 'old copy'
        Join-Path $TestDrive 'Backups\Alpha-User.new.vhdx' | Should -Not -Exist
    }
}
