# Restore.Tests.ps1
# Restore-GuestState returns exactly one result, so callers can use it as it
# is (#160). The helpers it calls are mocked to write stray output, which
# must not reach the caller. A rebuild attaches the user databases' files
# left on the SQL data disk (#132). Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Classes defined in a module are only visible inside it.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')
}

Describe 'Restore-GuestState' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-CaptureManifest { [pscustomobject]@{ CapturedAt = '2026-10-29' } }
        Mock -ModuleName $module Open-GuestSession { 'stray' }
        Mock -ModuleName $module Initialize-GuestSqlDisk { 'stray' }
        Mock -ModuleName $module Invoke-IsolatedStep { [pscustomobject]@{ Results = @{}; Failures = @() } }
    }

    It 'returns only $true when every area is restored' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restore-GuestState -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeTrue
    }
}

Describe 'Mount-GuestSqlDatabase (#132)' {
    BeforeEach {
        $dataDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'SQLData') -Force
        $primary = Join-Path $dataDir 'Sales.mdf'
        $log = Join-Path $dataDir 'Sales_log.ldf'
        Set-Content -LiteralPath $primary -Value 'data'
        Set-Content -LiteralPath $log -Value 'log'
        $letter = $primary.Substring(0, 1)
        $script:statements = @()
        Mock Get-GuestSqlScalar { 0 }
        Mock Invoke-GuestSql { $script:statements += $Sql }
    }

    It 'attaches the database from its recorded files, primary first, with the name and paths quoted' {
        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sa]les' -Files @($primary, $log) -DriveLetter $letter

        $status | Should -Be 'Attached'
        $script:statements | Should -Be @("CREATE DATABASE [Sa]]les] ON (FILENAME = N'$($primary.Replace("'", "''"))'), (FILENAME = N'$($log.Replace("'", "''"))') FOR ATTACH")
    }

    It 'finds the files on the data disk''s new drive letter when they are not at their recorded paths' {
        $recorded = @($primary, $log) | ForEach-Object { 'Q' + $_.Substring(1) }

        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -Files $recorded -DriveLetter $letter

        $status | Should -Be 'Attached'
        $script:statements[0] | Should -BeLike "*FILENAME = N'$primary'*FILENAME = N'$log'*"
    }

    It 'attaches nothing and says so when a file is on neither drive' {
        Remove-Item -LiteralPath $log

        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -Files @($primary, $log) -DriveLetter $letter

        $status | Should -Be 'Missing'
        $script:statements | Should -BeNullOrEmpty
    }

    It 'leaves a database that already exists alone' {
        Mock Get-GuestSqlScalar { 1 }

        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -Files @($primary, $log) -DriveLetter $letter

        $status | Should -Be 'Exists'
        $script:statements | Should -BeNullOrEmpty
    }
}
