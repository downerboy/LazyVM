# Diagnostic.Tests.ps1
# Test-LazyVM: what it reports about a VM, and that it changes nothing.
# Hyper-V, the guest, the credential store and Task Scheduler are mocked; the
# settings and the ISOs are real files in TestDrive.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function New-TestIso {
        <# A file carrying the ISO 9660 signature, which is all Test-IsoFile looks for. #>
        param([Parameter(Mandatory)][string]$Path)

        $bytes = [byte[]]::new(0x8006)
        [Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, 0x8001)
        [IO.File]::WriteAllBytes($Path, $bytes)
    }

    function New-TestRoot {
        <# A root folder with one VM, Alpha, whose Windows ISO is valid and whose SQL Server ISO is missing. #>
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $config = Join-Path -Path $root -ChildPath 'Alpha/Config'
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        $iso = Join-Path -Path $root -ChildPath 'Windows.iso'
        New-TestIso -Path $iso
        $settings = @{ ISOPath = $iso; SQLIsoPath = (Join-Path -Path $root -ChildPath 'Sql.iso') }
        Set-Content -LiteralPath (Join-Path -Path $config -ChildPath 'VM.json') -Value ($settings | ConvertTo-Json)
        return $root
    }

    $guestFacts = [pscustomobject]@{
        LastBootTime  = [datetime]'2026-10-30 08:00'
        OobeState     = 'IMAGE_STATE_COMPLETE'
        Provisioned   = $true
        AutoLogon     = $true
        AutoLogonUser = 'dev'
    }
}

Describe 'Test-LazyVM' {
    BeforeEach {
        $root = New-TestRoot
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'the -Root parameter' } }.GetNewClosure()
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running' } }
        Mock -ModuleName $module Get-VMIntegrationService { [pscustomobject]@{ PrimaryStatusDescription = 'OK' } }
        Mock -ModuleName $module Start-VM { }
        Mock -ModuleName $module Get-GuestCredential {
            [pscredential]::new('dev', [securestring]::new())
        }
        Mock -ModuleName $module Connect-Guest { [pscustomobject]@{ State = 'Opened' } }
        $facts = $guestFacts
        # A real PSSession cannot be made without a guest.
        Mock -ModuleName $module Invoke-Command { $facts }.GetNewClosure() -RemoveParameterType Session
        Mock -ModuleName $module Remove-GuestSession { }
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LazyVM-Maintain-Alpha' } }
        Mock -ModuleName $module Get-ScheduledTaskInfo {
            [pscustomobject]@{ LastRunTime = [datetime]'2026-10-31 03:00'; LastTaskResult = 0 }
        }
    }

    It 'reports the LazyVM folder and where it was found' {
        $result = Test-LazyVM -Name Alpha

        $result.Root | Should -Be $root
        $result.RootSource | Should -Be 'the -Root parameter'
    }

    It 'reports each ISO path and whether it is a valid image' {
        $result = Test-LazyVM -Name Alpha

        $windows = $result.Isos | Where-Object Name -eq 'Windows'
        $sql = $result.Isos | Where-Object Name -eq 'SQL Server'
        $windows.Path | Should -Be (Join-Path -Path $root -ChildPath 'Windows.iso')
        $windows.Valid | Should -BeTrue
        $sql.Exists | Should -BeFalse
        $sql.Valid | Should -BeFalse
    }

    It 'reports the VM state and heartbeat' {
        $result = Test-LazyVM -Name Alpha

        $result.State | Should -Be 'Running'
        $result.Heartbeat | Should -Be 'OK'
    }

    It 'reports that PowerShell Direct works with the stored account, and what the guest says' {
        $result = Test-LazyVM -Name Alpha

        $result.PowerShellDirect | Should -Be 'OK'
        $result.Account | Should -Be 'dev'
        $result.LastBootTime | Should -Be ([datetime]'2026-10-30 08:00')
        $result.OobeState | Should -Be 'IMAGE_STATE_COMPLETE'
        $result.Provisioned | Should -BeTrue
        $result.AutoLogon | Should -BeTrue
        $result.AutoLogonUser | Should -Be 'dev'
    }

    It 'reports why PowerShell Direct failed, and still reports the rest' {
        Mock -ModuleName $module Connect-Guest { throw "The guest refused the account 'dev'." }

        $result = Test-LazyVM -Name Alpha

        $result.PowerShellDirect | Should -BeLike "Failed: The guest refused the account 'dev'.*"
        $result.LastBootTime | Should -BeNullOrEmpty
        $result.MaintenanceLastResult | Should -Be 0
    }

    It 'does not try the guest without a stored account' {
        Mock -ModuleName $module Get-GuestCredential { $null }

        $result = Test-LazyVM -Name Alpha

        $result.PowerShellDirect | Should -BeLike 'Not tried: no guest account is stored*'
        Should -Invoke -ModuleName $module Connect-Guest -Times 0
    }

    It 'neither starts nor enters a VM that is off' {
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Off' } }

        $result = Test-LazyVM -Name Alpha

        $result.State | Should -Be 'Off'
        $result.PowerShellDirect | Should -BeLike 'Not tried: the VM is Off*'
        Should -Invoke -ModuleName $module Start-VM -Times 0
        Should -Invoke -ModuleName $module Connect-Guest -Times 0
    }

    It 'reports a VM that has not been built' {
        Mock -ModuleName $module Get-VM { }

        $result = Test-LazyVM -Name Alpha

        $result.State | Should -Be 'Not built'
        $result.Heartbeat | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Connect-Guest -Times 0
    }

    It "reports the maintenance task's last result" {
        $result = Test-LazyVM -Name Alpha

        $result.MaintenanceTask | Should -Be 'LazyVM-Maintain-Alpha'
        $result.MaintenanceTaskRegistered | Should -BeTrue
        $result.MaintenanceLastRun | Should -Be ([datetime]'2026-10-31 03:00')
        $result.MaintenanceLastResult | Should -Be 0
    }

    It 'reports a maintenance task that is not registered' {
        Mock -ModuleName $module Get-ScheduledTask { }

        $result = Test-LazyVM -Name Alpha

        $result.MaintenanceTaskRegistered | Should -BeFalse
        $result.MaintenanceLastResult | Should -BeNullOrEmpty
    }

    It 'closes the guest session' {
        Test-LazyVM -Name Alpha | Out-Null

        Should -Invoke -ModuleName $module Remove-GuestSession -Times 1
    }

    It 'writes nothing to the LazyVM folder' {
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" })

        Test-LazyVM -Name Alpha | Out-Null

        $after = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" })
        $after | Should -Be $before
    }

    It 'writes a text report with -ReportPath, and still returns the result' {
        $report = Join-Path -Path $TestDrive -ChildPath 'reports/Alpha.txt'

        $result = Test-LazyVM -Name Alpha -ReportPath $report

        $result.Name | Should -Be 'Alpha'
        $text = Get-Content -LiteralPath $report -Raw
        $text | Should -BeLike '*Alpha*'
        $text | Should -BeLike '*Windows.iso*'
        $text | Should -BeLike '*IMAGE_STATE_COMPLETE*'
        $text | Should -BeLike '*LazyVM-Maintain-Alpha*'
    }

    It 'takes Name from the pipeline, by value and by property name' {
        $attribute = (Get-Command -Name Test-LazyVM).Parameters['Name'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }

        $attribute.ValueFromPipeline | Should -BeTrue
        $attribute.ValueFromPipelineByPropertyName | Should -BeTrue
    }
}
