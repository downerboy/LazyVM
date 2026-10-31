# SqlServer.Tests.ps1
# SQL Server setup is driven by a ConfigurationFile.ini generated from the
# VM's settings (#135). Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function New-TestVM {
        param([hashtable]$Override = @{})

        $settings = @{
            VMName               = 'Alpha'
            GuestComputerName    = 'ALPHA'
            GuestAdminUser       = 'devadmin'
            GuestDataDriveLetter = 'S'
            SqlDataFolder        = 'SQLData'
            SqlLogFolder         = 'SQLLog'
            SqlBackupFolder      = 'SQLBackup'
        }
        foreach ($key in $Override.Keys) { $settings[$key] = $Override[$key] }
        # Classes defined in a module are only visible inside it.
        return InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }
    }
}

Describe 'ConvertTo-SqlConfigurationFile' {
    It 'starts with the OPTIONS section and installs the engine and full-text' {
        $vm = New-TestVM

        $lines = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) ConvertTo-SqlConfigurationFile -VM $VM }) -split "`r?`n"

        $lines | Should -Contain '[OPTIONS]'
        $lines | Should -Contain 'ACTION="Install"'
        $lines | Should -Contain 'FEATURES=SQLENGINE,FULLTEXT'
    }

    It 'installs the Standard Developer edition' {
        $vm = New-TestVM

        $lines = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) ConvertTo-SqlConfigurationFile -VM $VM }) -split "`r?`n"

        $lines | Should -Contain 'PID="33333-00000-00000-00000-00000"'
    }

    It 'makes the VM''s administrator a sysadmin as well as the Administrators group' {
        $vm = New-TestVM -Override @{ GuestComputerName = 'DEVBOX'; GuestAdminUser = 'sean' }

        $lines = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) ConvertTo-SqlConfigurationFile -VM $VM }) -split "`r?`n"

        $lines | Should -Contain 'SQLSYSADMINACCOUNTS="DEVBOX\sean" "BUILTIN\Administrators"'
    }

    It 'puts the VM''s data, log and backup folders in quotes' {
        $vm = New-TestVM -Override @{ SqlDataFolder = 'SQL Data' }

        $lines = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) ConvertTo-SqlConfigurationFile -VM $VM }) -split "`r?`n"

        $lines | Should -Contain 'SQLUSERDBDIR="S:\SQL Data"'
        $lines | Should -Contain 'SQLUSERDBLOGDIR="S:\SQLLog"'
        $lines | Should -Contain 'SQLBACKUPDIR="S:\SQLBackup"'
    }

    It 'leaves tempdb in the instance''s own folder on C:, since it is recreated at every start (#132)' {
        $vm = New-TestVM

        $lines = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) ConvertTo-SqlConfigurationFile -VM $VM }) -split "`r?`n"

        $lines -like 'SQLTEMPDB*' | Should -BeNullOrEmpty
    }

    It 'throws when a value would break out of its line' -ForEach @(
        @{ Folder = "SQLData`r`nSQLSYSADMINACCOUNTS=""Everyone""" }
        @{ Folder = 'SQL"Data' }
    ) {
        $vm = New-TestVM -Override @{ SqlDataFolder = $Folder }

        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) ConvertTo-SqlConfigurationFile -VM $VM } } |
            Should -Throw -ExpectedMessage '*SQLUSERDBDIR*'
    }
}

Describe 'Install-SqlServer' {
    BeforeEach {
        $stateDir = Join-Path $TestDrive 'state'
        $vm = New-TestVM -Override @{ StateDir = $stateDir; GuestSetupDir = 'C:\LazyVM\Setup'; SQLIsoPath = 'D:\ISO\sql.iso'; SQLInstallMinutes = 60 }

        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Initialize-SqlServerIso { }
        Mock -ModuleName $module Get-VMDvdDrive { [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; Path = $null } }
        Mock -ModuleName $module Set-VMDvdDrive { }
        Mock -ModuleName $module Invoke-GuestScript { 'E:\setup.exe' }
        Mock -ModuleName $module Copy-ToGuest { }
        Mock -ModuleName $module Invoke-GuestInstaller { 0 }
    }

    It 'saves the configuration file with the VM''s state' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-SqlServer -VM $VM }

        Join-Path $stateDir 'sql\ConfigurationFile.ini' | Should -Exist
    }

    It 'runs setup with the configuration file copied into the guest' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-SqlServer -VM $VM }

        Should -Invoke -ModuleName $module Copy-ToGuest -Times 1 -ParameterFilter { $GuestPath -eq 'C:\LazyVM\Setup\ConfigurationFile.ini' }
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -ParameterFilter { $ArgumentList -contains '/CONFIGURATIONFILE="C:\LazyVM\Setup\ConfigurationFile.ini"' }
    }
}

Describe 'SQL Server only when VM.json says so (#36)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        # The boundaries each SQL step reaches when it runs.
        Mock -ModuleName $module Test-IsoFile { $true }
        Mock -ModuleName $module Get-Item { [pscustomobject]@{ Length = 1GB } }
        Mock -ModuleName $module Initialize-DataVhd { }
        Mock -ModuleName $module Add-VMDataDisk { }
        Mock -ModuleName $module Get-DataDiskIdentity { [pscustomobject]@{ Guid = $null; Location = 1; FileLocation = 1 } }
        Mock -ModuleName $module Invoke-GuestScript { throw 'stop here' }
        Mock -ModuleName $module Get-GuestSqlInstance { [pscustomobject]@{ Instance = 'MSSQLSERVER'; Edition = 'Developer' } }
        Mock -ModuleName $module Connect-GuestSqlInstance { $null }
        Mock -ModuleName $module Get-GuestSqlRestore { $null }
    }

    It '<Step> reaches <Boundary> only when InstallSqlServer is <Install>' -ForEach @(
        foreach ($install in $true, $false) {
            @{ Step = 'Initialize-SqlServerIso'; Boundary = 'Test-IsoFile'; Install = $install }
            @{ Step = 'Initialize-SqlDataVhd'; Boundary = 'Initialize-DataVhd'; Install = $install }
            @{ Step = 'Add-SqlDataDisk'; Boundary = 'Add-VMDataDisk'; Install = $install }
            @{ Step = 'Initialize-GuestSqlDisk'; Boundary = 'Get-DataDiskIdentity'; Install = $install }
            @{ Step = 'Install-SqlServerIfMissing'; Boundary = 'Get-GuestSqlInstance'; Install = $install }
            @{ Step = 'Save-GuestSqlState'; Boundary = 'Connect-GuestSqlInstance'; Install = $install }
        }
    ) {
        $vm = New-TestVM -Override @{ InstallSqlServer = $Install; SQLIsoPath = 'D:\ISO\sql.iso'; SQLDiskPath = 'D:\Disks\Alpha-SQL.vhdx'; SQLDiskSizeGB = 10 }

        try { InModuleScope $module -Parameters @{ VM = $vm; Step = $Step } { param($VM, $Step) & $Step -VM $VM } } catch { $null = $_ }

        Should -Invoke -ModuleName $module $Boundary -Times ([int]$Install) -Exactly
    }

    It 'Restore-GuestSqlState reaches the instance only when InstallSqlServer is <Install>' -ForEach @(
        @{ Install = $true }
        @{ Install = $false }
    ) {
        $vm = New-TestVM -Override @{ InstallSqlServer = $Install }
        $manifest = InModuleScope $module { $m = [CaptureManifest]::new(); $m.Sql = [pscustomobject]@{ Databases = @() }; $m }

        InModuleScope $module -Parameters @{ VM = $vm; Manifest = $manifest } { param($VM, $Manifest) Restore-GuestSqlState -VM $VM -Manifest $Manifest }

        Should -Invoke -ModuleName $module Connect-GuestSqlInstance -Times ([int]$Install) -Exactly
    }

    It 'counts the SQL data disk among the persistent disks only when InstallSqlServer is <Install>' -ForEach @(
        @{ Install = $true }
        @{ Install = $false }
    ) {
        $vm = New-TestVM -Override @{ InstallSqlServer = $Install; UseDevDrive = $false; SQLDiskPath = 'D:\Disks\Alpha-SQL.vhdx'; UserDiskPath = 'D:\Disks\Alpha-User.vhdx' }

        $labels = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-PersistentDataDisk -VM $VM } | ForEach-Object { $_.Label })

        ($labels -contains 'SQL data disk') | Should -Be $Install
    }
}
