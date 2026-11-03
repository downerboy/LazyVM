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
        Mock -ModuleName $module Get-GuestStagingFolder { 'C:\Program Files\LazyVM\Staging' }
        Mock -ModuleName $module Invoke-GuestInstaller { 0 }
    }

    It 'saves the configuration file with the VM''s state' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-SqlServer -VM $VM }

        Join-Path $stateDir 'sql\ConfigurationFile.ini' | Should -Exist
    }

    It 'runs setup with the configuration file copied into the staging folder, which only administrators can change (#302)' {
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Install-SqlServer -VM $VM }

        # ? for the path separators, which are / where the tests run on Linux.
        $config = 'C:?Program Files?LazyVM?Staging?ConfigurationFile.ini'
        Should -Invoke -ModuleName $module Copy-ToGuest -Times 1 -ParameterFilter { $GuestPath -like $config }
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -ParameterFilter { $Name -eq 'install-sqlserver' -and $ArgumentList -like "/CONFIGURATIONFILE=`"$config`"" }
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

Describe 'Open-GuestSqlConnection waits for SQL Server (#318)' {
    # After a restart the SQL Server service can still be starting when SQL
    # work begins; a connection then fails with error 40. The guest helper
    # starts a stopped service and retries until SQL Server accepts the
    # connection, for a bounded time. A fake clock moves only when the helper
    # sleeps, so the waits take no real time.
    BeforeAll {
        # The guest-side helpers, loaded here as they are into the guest.
        . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')
        Add-MissingCommandStub -Stub @{ 'Get-Service' = { param([string]$Name) throw "Get-Service is a test stub; mock it ($Name)." } }

        function New-TestService {
            <# A service as Get-Service returns it, whose Start() records the call and makes it start. #>
            param([string]$Status, [string]$StartType = 'Automatic')

            $service = [pscustomobject]@{ Name = 'MSSQLSERVER'; Status = $Status; StartType = $StartType }
            $service | Add-Member -MemberType ScriptMethod -Name Start -Value { $script:started++; $script:statuses = @('StartPending', 'Running') }
            return $service
        }
    }

    BeforeEach {
        $script:now = [datetime]'2026-11-02T21:40:40'
        $script:started = 0
        $script:connectionFailures = 0
        Mock Get-Date { $script:now }
        Mock Start-Sleep { $script:now = $script:now.AddSeconds($Seconds) }
        # Each call reports the next status; the last one stays.
        Mock Get-Service {
            $status = $script:statuses[0]
            if ($script:statuses.Count -gt 1) { $script:statuses = @($script:statuses | Select-Object -Skip 1) }
            New-TestService -Status $status -StartType $script:startType
        }
        $script:startType = 'Automatic'
        Mock New-GuestSqlConnection {
            if ($script:connectionFailures -gt 0) {
                $script:connectionFailures--
                throw 'A network-related or instance-specific error occurred (provider: Named Pipes Provider, error: 40 - Could not open a connection to SQL Server)'
            }
            [pscustomobject]@{ Server = $Server }
        }
    }

    It 'starts a stopped service and returns the connection once it runs' {
        $script:statuses = @('Stopped')

        $connection = Open-GuestSqlConnection -Server 'localhost'

        $connection.Server | Should -Be 'localhost'
        $script:started | Should -Be 1
    }

    It 'waits while the service is StartPending, without starting it again' {
        $script:statuses = @('StartPending', 'StartPending', 'Running')

        $connection = Open-GuestSqlConnection -Server 'localhost'

        $connection.Server | Should -Be 'localhost'
        $script:started | Should -Be 0
        Should -Invoke Start-Sleep
    }

    It 'retries a running service until it accepts the connection' {
        $script:statuses = @('Running')
        $script:connectionFailures = 2

        $connection = Open-GuestSqlConnection -Server 'localhost'

        $connection.Server | Should -Be 'localhost'
        Should -Invoke New-GuestSqlConnection -Times 3 -Exactly
    }

    It 'fails at once, without starting it, when the service is disabled' {
        $script:statuses = @('Stopped')
        $script:startType = 'Disabled'

        { Open-GuestSqlConnection -Server 'localhost' } | Should -Throw '*MSSQLSERVER*disabled*'

        $script:started | Should -Be 0
        Should -Invoke New-GuestSqlConnection -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'gives up after the time limit, naming the service state and the ERRORLOG' {
        $script:statuses = @('StartPending')
        $began = $script:now

        { Open-GuestSqlConnection -Server 'localhost' } | Should -Throw '*MSSQLSERVER*StartPending*ERRORLOG*'

        ($script:now - $began) | Should -Be $script:GuestSqlStartLimit
    }

    It 'names the last connection error when the service runs but refuses connections' {
        $script:statuses = @('Running')
        $script:connectionFailures = [int]::MaxValue

        { Open-GuestSqlConnection -Server 'localhost' } | Should -Throw '*Running*error: 40*ERRORLOG*'
    }

    It 'waits for the service of a named instance' {
        $script:statuses = @('Running')

        $null = Open-GuestSqlConnection -Server 'localhost\DEV'

        Should -Invoke Get-Service -ParameterFilter { $Name -eq 'MSSQL$DEV' }
    }

    It 'is called only from guest scripts given longer than the wait to finish' {
        # Otherwise the host gives up first, with a message that hides why.
        $sourceDir = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Private'
        $short = foreach ($file in Get-ChildItem -LiteralPath $sourceDir -Filter '*.ps1' -Recurse) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-GuestScript' }, $true)
            foreach ($call in $calls) {
                if ($call.Extent.Text -notmatch 'Open-GuestSqlConnection') { continue }
                $elements = $call.CommandElements
                $index = [array]::FindIndex([object[]]$elements, [Predicate[object]] { param($e) $e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'TimeoutMinutes' })
                if ([int]$elements[$index + 1].Extent.Text -le $script:GuestSqlStartLimit.TotalMinutes) { "$($file.Name):$($call.Extent.StartLineNumber)" }
            }
        }

        @($short) | Should -BeNullOrEmpty
    }
}
