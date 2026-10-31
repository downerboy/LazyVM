# Diagnostic.Tests.ps1
# Test-LazyVM (#33): a read-only report of what a build or maintenance run
# depends on - the LazyVM folder, the ISOs, the VM, PowerShell Direct, the
# guest's set-up state and the maintenance task. It changes nothing and
# starts nothing. Hyper-V, the guest and the Task Scheduler are mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function Get-TestCheck {
        <# Runs the diagnostic for Alpha and returns its checks keyed by name. #>
        $checks = @(InModuleScope $module { Get-LazyVMDiagnostic -Name Alpha })
        $byName = @{}
        foreach ($check in $checks) { $byName[$check.Check] = $check }
        return $byName
    }
}

Describe 'Get-LazyVMDiagnostic' {
    BeforeEach {
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = 'C:\LazyVM'; Source = 'the registry' } }
        Mock -ModuleName $module Read-VMSetting {
            $settings = @{
                ISOPath = 'C:\LazyVM\Shared\ISO\Win11.iso'; SQLIsoPath = 'C:\LazyVM\Shared\ISO\SQL.iso'
                CredKeyFile = 'key'; GuestCredFile = 'guest.cred'; ScheduleTaskName = 'LazyVM Alpha'
            }
            [pscustomobject]@{ VMName = 'Alpha'; Settings = $settings }
        }
        Mock -ModuleName $module Test-IsoFile { $true }
        Mock -ModuleName $module Get-Item { [pscustomobject]@{ Length = 6GB } }
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running'; Heartbeat = 'OkApplicationsHealthy' } }
        Mock -ModuleName $module Start-VM { }
        Mock -ModuleName $module Get-StoredCredential { [pscredential]::new('devadmin', [Net.NetworkCredential]::new('', 'x').SecurePassword) }
        Mock -ModuleName $module Invoke-Command {
            [pscustomobject]@{ BootTime = [datetime]'2026-10-31 08:00'; ImageState = 'IMAGE_STATE_COMPLETE'; OobeInProgress = 0; Provisioned = 1; AutoLogon = '1'; AutoLogonUser = 'devadmin' }
        }
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LazyVM Alpha' } }
        Mock -ModuleName $module Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-10-31 03:00'; LastTaskResult = 0; NextRunTime = [datetime]'2026-11-01 03:00' } }
    }

    It 'reports a healthy VM as OK throughout' {
        $checks = Get-TestCheck

        @($checks.Values | Where-Object { $_.Status -in 'WARN', 'FAIL' }).Count | Should -Be 0
        $checks['LazyVM folder'].Detail | Should -BeLike 'C:\LazyVM*registry*'
        $checks['PowerShell Direct'].Status | Should -Be 'OK'
        $checks['Maintenance task'].Status | Should -Be 'OK'
    }

    It 'fails a Windows ISO that is missing or not an ISO image' {
        Mock -ModuleName $module Test-IsoFile { $false } -ParameterFilter { $Path -like '*Win11.iso' }

        (Get-TestCheck)['Windows ISO'].Status | Should -Be 'FAIL'
    }

    It 'starts nothing and skips the guest checks when the VM is off' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Off'; Heartbeat = $null } }

        $checks = Get-TestCheck

        $checks['PowerShell Direct'].Status | Should -Be 'INFO'
        $checks['PowerShell Direct'].Detail | Should -BeLike '*Off*'
        Should -Invoke -ModuleName $module Invoke-Command -Times 0
        Should -Invoke -ModuleName $module Start-VM -Times 0
    }

    It 'warns when Windows set-up has not finished or the guest was never provisioned' {
        Mock -ModuleName $module Invoke-Command {
            [pscustomobject]@{ BootTime = [datetime]'2026-10-31 08:00'; ImageState = 'IMAGE_STATE_UNDEPLOYABLE'; OobeInProgress = 1; Provisioned = $null; AutoLogon = '0'; AutoLogonUser = '' }
        }

        $checks = Get-TestCheck

        $checks['Windows set-up'].Status | Should -Be 'WARN'
        $checks['Provisioning marker'].Status | Should -Be 'WARN'
    }

    It 'fails PowerShell Direct when the stored account cannot connect, and still checks the rest' {
        Mock -ModuleName $module Invoke-Command { throw 'The credential is invalid.' }

        $checks = Get-TestCheck

        $checks['PowerShell Direct'].Status | Should -Be 'FAIL'
        $checks['PowerShell Direct'].Detail | Should -BeLike '*credential is invalid*'
        $checks.ContainsKey('Maintenance task') | Should -BeTrue
    }

    It 'reports the maintenance task as <Status> when <Case>' -ForEach @(
        @{ Case = 'it is not scheduled'; Task = $false; Result = 0; Status = 'WARN' }
        @{ Case = 'its last run failed'; Task = $true; Result = 2147942402; Status = 'FAIL' }
        @{ Case = 'it has not run yet'; Task = $true; Result = 267011; Status = 'INFO' }
    ) {
        if (-not $Task) { Mock -ModuleName $module Get-ScheduledTask { } }
        Mock -ModuleName $module Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = $null; LastTaskResult = $Result; NextRunTime = [datetime]'2026-11-01 03:00' } }.GetNewClosure()

        (Get-TestCheck)['Maintenance task'].Status | Should -Be $Status
    }
}

Describe 'Test-LazyVM' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Get-LazyVMDiagnostic {
            [pscustomobject]@{ PSTypeName = 'LazyVM.Check'; Name = 'Alpha'; Area = 'Host'; Check = 'LazyVM folder'; Status = 'OK'; Detail = 'C:\LazyVM' }
            [pscustomobject]@{ PSTypeName = 'LazyVM.Check'; Name = 'Alpha'; Area = 'Guest'; Check = 'PowerShell Direct'; Status = 'FAIL'; Detail = 'The credential is invalid.' }
        }
    }

    It 'returns the checks' {
        $checks = @(Test-LazyVM -Name Alpha)

        $checks.Count | Should -Be 2
        $checks[1].Status | Should -Be 'FAIL'
    }

    It 'writes a text report with every check when given -ReportPath' {
        $report = Join-Path $TestDrive 'Alpha-report.txt'

        $null = Test-LazyVM -Name Alpha -ReportPath $report

        $text = Get-Content -LiteralPath $report -Raw
        $text | Should -BeLike '*OK*LazyVM folder*C:\LazyVM*'
        $text | Should -BeLike '*FAIL*PowerShell Direct*credential is invalid*'
    }
}

Describe 'Test-LazyVM against real settings files' {
    BeforeEach {
        # A root with one VM profile and a shared settings file, read for real.
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $vmConfig = Join-Path -Path $root -ChildPath 'Alpha/Config'
        $sharedConfig = Join-Path -Path $root -ChildPath 'Shared/Config'
        New-Item -ItemType Directory -Path $vmConfig, $sharedConfig -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $vmConfig -ChildPath 'VM.json') -Value '{ "vCPU": 6 }'
        Set-Content -LiteralPath (Join-Path -Path $sharedConfig -ChildPath 'LazyVM.Settings.json') -Value '{ "vCPU": 4 }'

        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'a test' } }.GetNewClosure()
        Mock -ModuleName $module Get-VM { }
        Mock -ModuleName $module Get-ScheduledTask { }
    }

    It 'adds or changes no file in the LazyVM folder' {
        $snapshot = { @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) }
        $before = & $snapshot

        $null = Test-LazyVM -Name Alpha

        & $snapshot | Should -Be $before
    }
}
