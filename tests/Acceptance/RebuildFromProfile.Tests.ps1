# RebuildFromProfile.Tests.ps1
# End-to-end check that VM.json is the VM's complete, living configuration
# (#39, #97): a VM built from the template, changed by hand in the guest,
# captured and then rebuilt from VM.json alone matches the guest it was.
#
# Needs a real Hyper-V host, an elevated PowerShell 7 and a few hours, so it
# is tagged Acceptance and left out of ./Invoke-AnalyzerAndTest.ps1 and CI.
# It also runs only when LAZYVM_ACCEPTANCE_VM names a VM that does not exist
# yet: it builds that VM and never touches any other. The VM is left in
# place afterwards for inspection. README.md here says how to run it.

BeforeDiscovery {
    $script:acceptanceVM = $env:LAZYVM_ACCEPTANCE_VM
}

Describe 'A VM rebuilt from VM.json' -Tag 'Acceptance' -Skip:(-not $script:acceptanceVM) {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'RebuildComparison.ps1')
        Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../../src/LazyVM/LazyVM.psd1') -Force -DisableNameChecking

        $name = $env:LAZYVM_ACCEPTANCE_VM
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {
            throw "LAZYVM_ACCEPTANCE_VM '$name' is not a valid VM name: use 1-15 letters, digits or hyphens."
        }
        # Fail closed: this test builds and rebuilds its own VM, never one that is already there.
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
            throw "A Hyper-V VM named '$name' already exists. Name a VM that does not exist yet in LAZYVM_ACCEPTANCE_VM."
        }
        if (@(Get-LazyVM | Where-Object Name -EQ $name).Count -gt 0) {
            throw "LazyVM already has a profile for '$name'. Name a VM that does not exist yet in LAZYVM_ACCEPTANCE_VM."
        }
        $sqlServer = if ($env:LAZYVM_ACCEPTANCE_SQLSERVER) { $env:LAZYVM_ACCEPTANCE_SQLSERVER } else { '.' }

        # What the test changes by hand in the guest, as each area of the snapshot records it.
        $marker = 'LazyVM acceptance #39'
        $handChange = @{
            Tooling     = @('Winget:7zip.7zip')
            Environment = @(@{ Scope = 'Machine'; Name = 'LAZYVM_ACCEPTANCE'; Value = '39' })
            Firewall    = @(@{ Name = $marker; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = '39039' })
            Databases   = @(@{ Name = 'LazyVMAcceptance'; MarkerRows = 1 })
            UserData    = @(@{ Path = 'LazyVMAcceptance\marker.txt'; Text = $marker })
        }

        function Get-AcceptanceSnapshot {
            <# The guest as the comparison sees it: tooling, settings, SQL state and the User disk's marker data. #>
            param([string]$Name, [pscredential]$Credential, [string]$SqlServer)

            $tooling = Get-LazyVMTooling -Name $Name
            $guest = Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $SqlServer -ScriptBlock {
                param($sqlServer)
                $ErrorActionPreference = 'Stop'
                $environment = @(foreach ($scope in 'Machine', 'User') {
                        $variables = [Environment]::GetEnvironmentVariables($scope)
                        foreach ($key in $variables.Keys) {
                            [pscustomobject]@{ Scope = $scope; Name = "$key"; Value = "$($variables[$key])" }
                        }
                    })
                # Only rules added in the guest: Windows' own rules belong to a group.
                $firewall = @(Get-NetFirewallRule -Enabled True | Where-Object { -not $_.Group } | ForEach-Object {
                        $port = $_ | Get-NetFirewallPortFilter
                        [pscustomobject]@{ Name = $_.DisplayName; Direction = "$($_.Direction)"; Protocol = "$($port.Protocol)"; LocalPort = "$($port.LocalPort)" }
                    })
                $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })

                $databases = @()
                $connection = New-Object System.Data.SqlClient.SqlConnection "Server=$sqlServer;Database=master;Integrated Security=SSPI;TrustServerCertificate=True"
                $connection.Open()
                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = 'SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name'
                    $reader = $command.ExecuteReader()
                    $names = @(while ($reader.Read()) { $reader.GetString(0) })
                    $reader.Close()
                    foreach ($database in $names) {
                        $command.CommandText = "SELECT CASE WHEN OBJECT_ID(N'[$($database -replace '\]', ']]')].dbo.Marker') IS NULL THEN 0 ELSE 1 END"
                        $rows = 0
                        if ([int]$command.ExecuteScalar() -eq 1) {
                            $command.CommandText = "SELECT COUNT(*) FROM [$($database -replace '\]', ']]')].dbo.Marker"
                            $rows = [int]$command.ExecuteScalar()
                        }
                        [pscustomobject]@{ Name = $database; MarkerRows = $rows }
                    }
                }
                finally { $connection.Close() }

                $userData = @()
                $volume = Get-Volume -FileSystemLabel 'User' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($volume -and $volume.DriveLetter) {
                    $root = "$($volume.DriveLetter):\"
                    $folder = Join-Path $root 'LazyVMAcceptance'
                    $userData = @(Get-ChildItem -LiteralPath $folder -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                            [pscustomobject]@{ Path = $_.FullName.Substring($root.Length); Text = (Get-Content -LiteralPath $_.FullName -Raw).Trim() }
                        })
                }

                [pscustomobject]@{ Environment = $environment; Firewall = $firewall; Tasks = $tasks; Databases = $databases; UserData = $userData }
            }

            return @{
                Tooling        = @(@($tooling.WingetPackages | ForEach-Object { "Winget:$($_.Id)" }) + @($tooling.Products | ForEach-Object { "Product:$($_.DisplayName)" }))
                Environment    = @($guest.Environment)
                Firewall       = @($guest.Firewall)
                ScheduledTasks = @($guest.Tasks)
                Databases      = @($guest.Databases)
                UserData       = @($guest.UserData)
            }
        }

        # 1. Build a VM from the template.
        New-LazyVM -Name $name -Confirm:$false | Out-Null
        Build-LazyVM -Name $name
        $credential = Get-LazyVMCredential -Name $name

        # 2. Change it by hand in the guest: tooling, settings, SQL state and user data.
        Invoke-Command -VMName $name -Credential $credential -ArgumentList $marker, $sqlServer -ScriptBlock {
            param($marker, $sqlServer)
            $ErrorActionPreference = 'Stop'
            $winget = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" | Sort-Object FullName | Select-Object -Last 1
            if (-not $winget) { throw 'winget is not available in the guest.' }
            & $winget.FullName install --id 7zip.7zip --exact --silent --accept-source-agreements --accept-package-agreements | Out-Null

            [Environment]::SetEnvironmentVariable('LAZYVM_ACCEPTANCE', '39', 'Machine')
            New-NetFirewallRule -DisplayName $marker -Direction Inbound -Protocol TCP -LocalPort 39039 -Action Allow | Out-Null

            $connection = New-Object System.Data.SqlClient.SqlConnection "Server=$sqlServer;Database=master;Integrated Security=SSPI;TrustServerCertificate=True"
            $connection.Open()
            try {
                $command = $connection.CreateCommand()
                foreach ($sql in 'CREATE DATABASE LazyVMAcceptance', 'CREATE TABLE LazyVMAcceptance.dbo.Marker (Id int NOT NULL)', 'INSERT INTO LazyVMAcceptance.dbo.Marker (Id) VALUES (39)') {
                    $command.CommandText = $sql
                    $null = $command.ExecuteNonQuery()
                }
            }
            finally { $connection.Close() }

            $volume = Get-Volume -FileSystemLabel 'User' | Select-Object -First 1
            $folder = New-Item -ItemType Directory -Path "$($volume.DriveLetter):\LazyVMAcceptance" -Force
            Set-Content -LiteralPath (Join-Path $folder.FullName 'marker.txt') -Value $marker
        }

        # 3. Capture.
        Save-LazyVMTooling -Name $name
        Save-LazyVMState -Name $name
        $before = Get-AcceptanceSnapshot -Name $name -Credential $credential -SqlServer $sqlServer

        # 4. Rebuild from VM.json alone, with no hand edits to any configuration.
        Invoke-LazyVMRebuild -Name $name -SkipCapture -Force
        $credential = Get-LazyVMCredential -Name $name
        $after = Get-AcceptanceSnapshot -Name $name -Credential $credential -SqlServer $sqlServer
    }

    It 'had every hand change in the guest before the rebuild' {
        $missing = @(Find-MissingHandChange -Snapshot $before -HandChange $handChange)

        $missing | Should -BeNullOrEmpty -Because ($missing | Format-Table -AutoSize | Out-String)
    }

    It 'keeps every hand change after the rebuild' {
        $missing = @(Find-MissingHandChange -Snapshot $after -HandChange $handChange)

        $missing | Should -BeNullOrEmpty -Because ($missing | Format-Table -AutoSize | Out-String)
    }

    It 'matches the guest it replaced' {
        $differences = @(Compare-GuestSnapshot -Before $before -After $after)

        $differences | Should -BeNullOrEmpty -Because ($differences | Format-Table -AutoSize -Wrap | Out-String)
    }
}
