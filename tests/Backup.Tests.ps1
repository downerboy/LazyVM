# Backup.Tests.ps1
# Each user database is checked with DBCC CHECKDB before it is backed up, and
# a backup replaces the last good one only once it has been verified, so a
# corrupt database or a failed backup never costs the one good backup kept
# (#133). Nothing here needs Hyper-V, a guest or SQL Server.

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
