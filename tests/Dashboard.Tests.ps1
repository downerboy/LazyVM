# Dashboard.Tests.ps1
# Get-LazyVMDashboard (#305): one object per VM with everything the
# dashboard shows. Hyper-V and Task Scheduler are mocked; the settings,
# findings and template files are real files in a test LazyVM folder.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Add-MissingCommandStub -Stub ([ordered]@{
            'Get-ScheduledTask'     = { [CmdletBinding()] param([string]$TaskName) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
            'Get-ScheduledTaskInfo' = { [CmdletBinding()] param([string]$TaskName) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
        })
    Import-LazyVMModule

    $module = 'LazyVM'
    $created = [datetime]'2026-10-01 09:30'

    function New-TestRoot {
        <# A LazyVM folder with one VM profile per name given. #>
        param([string[]]$VMs = @())

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($vm in $VMs) {
            $folder = Join-Path -Path $root -ChildPath $vm | Join-Path -ChildPath 'Config'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'VM.json') -Value '{ "vCPU": 6 }'
        }
        return $root
    }

    function Use-TestRoot {
        <# Points LazyVM at $Root, with every VM off and no maintenance task, unless a test mocks otherwise. #>
        param([Parameter(Mandatory)][string]$Root)

        $rootPath = $Root
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $rootPath; Source = 'a test' } }.GetNewClosure()
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ State = 'Off'; CreationTime = [datetime]'2026-10-01 09:30'; MemoryAssigned = 0 } }.GetNewClosure()
        Mock -ModuleName $module Get-VMHardDiskDrive { }
        Mock -ModuleName $module Get-ScheduledTask { }
    }
}

Describe 'Get-LazyVMDashboard' {
    It 'lists each VM with what Get-LazyVM says about it' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha', 'Beta')

        $rows = @(Get-LazyVMDashboard)

        $rows.Name | Should -Be @('Alpha', 'Beta')
        $rows[0].PSObject.TypeNames[0] | Should -Be 'LazyVM.Dashboard'
        $rows[0].State | Should -Be 'Off'
        $rows[0].MaintenanceTask | Should -Be 'Not registered'
        $rows[0].Settings | Should -Be 'OK'
        $rows[0].Problems | Should -BeNullOrEmpty
    }

    It 'lists only the VMs matching -Name' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha', 'Beta')

        (Get-LazyVMDashboard -Name 'B*').Name | Should -Be 'Beta'
    }

    It 'gives when the VM was created and the memory it is using, from Hyper-V' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha')
        Mock -ModuleName $module Get-VM { [pscustomobject]@{ Name = 'Alpha'; State = 'Running'; CreationTime = [datetime]'2026-10-01 09:30'; MemoryAssigned = 8GB } }.GetNewClosure()

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.Created | Should -Be $created
        $row.MemoryAssigned | Should -Be 8GB
    }

    It 'gives each disk once, counting its checkpoint files, and the total' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha')
        Mock -ModuleName $module Get-VMHardDiskDrive { @([pscustomobject]@{ Path = 'D:\DevVM\Alpha\Disks\Alpha-OS_1.avhdx' }, [pscustomobject]@{ Path = 'D:\DevVM\Alpha\Disks\Alpha-SQL.vhdx' }) }
        Mock -ModuleName $module Get-VHD {
            switch ($Path[0]) {
                'D:\DevVM\Alpha\Disks\Alpha-OS_1.avhdx' { [pscustomobject]@{ Path = $_; FileSize = 2GB; Size = 127GB; ParentPath = 'D:\DevVM\Alpha\Disks\Alpha-OS.vhdx' } }
                'D:\DevVM\Alpha\Disks\Alpha-OS.vhdx' { [pscustomobject]@{ Path = $_; FileSize = 30GB; Size = 127GB; ParentPath = '' } }
                'D:\DevVM\Alpha\Disks\Alpha-SQL.vhdx' { [pscustomobject]@{ Path = $_; FileSize = 5GB; Size = 100GB; ParentPath = '' } }
            }
        }

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.Disks.Name | Should -Be @('Alpha-OS.vhdx', 'Alpha-SQL.vhdx')
        $row.Disks[0].Used | Should -Be 32GB
        $row.Disks[0].Maximum | Should -Be 127GB
        $row.Disks[0].PSObject.TypeNames[0] | Should -Be 'LazyVM.DashboardDisk'
        $row.DiskSpaceUsed | Should -Be 37GB
    }

    It 'asks Hyper-V nothing about a VM that is not built' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha')
        Mock -ModuleName $module Get-VM { }

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.State | Should -Be 'Not built'
        $row.Created | Should -BeNullOrEmpty
        $row.Disks | Should -BeNullOrEmpty
        $row.DiskSpaceUsed | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Get-VMHardDiskDrive -Times 0
    }

    It 'gives the last maintenance run as <Expected> when its task result is <Result>' -ForEach @(
        @{ Result = 0; Expected = 'Succeeded'; HasRun = $true }
        @{ Result = 1; Expected = 'Failed (0x1)'; HasRun = $true }
        @{ Result = 267011; Expected = 'Not run yet'; HasRun = $false }
    ) {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha')
        Mock -ModuleName $module Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName } }
        Mock -ModuleName $module Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-11-12 03:00'; LastTaskResult = $Result } }.GetNewClosure()

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.LastMaintenanceResult | Should -Be $Expected
        if ($HasRun) { $row.LastMaintenance | Should -Be ([datetime]'2026-11-12 03:00') }
        else { $row.LastMaintenance | Should -BeNullOrEmpty }
    }

    It 'gives no last maintenance run when no task is registered' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha')

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.LastMaintenance | Should -BeNullOrEmpty
        $row.LastMaintenanceResult | Should -BeNullOrEmpty
    }

    It 'gives the configuration the VM was first built from, when there is one' {
        $root = New-TestRoot -VMs 'Alpha', 'Beta'
        $asBuilt = Join-Path -Path $root -ChildPath 'Alpha' | Join-Path -ChildPath 'Config' | Join-Path -ChildPath 'VM.Template.json'
        Set-Content -LiteralPath $asBuilt -Value '{ "vCPU": 4 }'
        Use-TestRoot -Root $root

        $rows = @(Get-LazyVMDashboard)

        $rows[0].OriginalConfig | Should -Be $asBuilt
        $rows[1].OriginalConfig | Should -BeNullOrEmpty
    }

    It 'gives the green template LazyVM keeps for the VM, and when it last changed' {
        $root = New-TestRoot -VMs 'Alpha', 'Beta'
        $templates = Join-Path -Path $root -ChildPath 'Shared' | Join-Path -ChildPath 'Templates'
        New-Item -ItemType Directory -Path $templates -Force | Out-Null
        $green = Join-Path -Path $templates -ChildPath 'Alpha-latest.json'
        Set-Content -LiteralPath $green -Value '{ "vCPU": 6 }'
        (Get-Item -LiteralPath $green).LastWriteTime = [datetime]'2026-11-10 21:15'
        Use-TestRoot -Root $root

        $rows = @(Get-LazyVMDashboard)

        $rows[0].GreenTemplate | Should -Be 'Alpha-latest'
        $rows[0].GreenTemplateUpdated | Should -Be ([datetime]'2026-11-10 21:15')
        $rows[1].GreenTemplate | Should -BeNullOrEmpty
    }

    It 'counts the findings still open, leaving out resolved and approved ones' {
        $root = New-TestRoot -VMs 'Alpha'
        Use-TestRoot -Root $root
        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $vm = [VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha' -ReadOnly).Settings)
            $findings = foreach ($item in @(@('Firewall:Public:Off', 'New'), @('Smb1:On', 'Still open'), @('Uac:Off', 'Resolved'), @('Rdp:On', 'New'))) {
                [SecurityFinding]::new($item[0], 'High', 't', 'w', 'y', 'h').Compared($item[1], [datetimeoffset]'2026-11-01')
            }
            $record = @{ ScannedAt = '2026-11-12T03:20:00.0000000+00:00'; Findings = @($findings | ForEach-Object { $_.ToRecord() }); Unchecked = @() }
            New-Item -ItemType Directory -Path (Split-Path -Path $vm.Settings.SecurityFindingsFile -Parent) -Force | Out-Null
            Set-Content -LiteralPath $vm.Settings.SecurityFindingsFile -Value (ConvertTo-Json -InputObject $record -Depth 4)
        }
        $approval = InModuleScope $module { [SecurityApproval]::new('Rdp:On', 'High', 't', [datetimeoffset]'2026-11-02', 'Needed for support') }
        Mock -ModuleName $module Read-SecurityBaseline { [pscustomobject]@{ Approvals = @($approval) } }.GetNewClosure()

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.OpenFindings | Should -Be 2
        $row.LastSecurityScan | Should -Be ([datetimeoffset]'2026-11-12T03:20:00Z')
    }

    It 'gives no findings count before the first scan' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha')

        $row = Get-LazyVMDashboard -Name 'Alpha'

        $row.OpenFindings | Should -BeNullOrEmpty
        $row.LastSecurityScan | Should -BeNullOrEmpty
    }

    It 'shows what it could not read on that VM''s row, and still lists the rest' {
        Use-TestRoot -Root (New-TestRoot -VMs 'Alpha', 'Beta')
        Mock -ModuleName $module Get-VMHardDiskDrive { throw 'access denied' } -ParameterFilter { $VMName -eq 'Alpha' }

        $rows = @(Get-LazyVMDashboard)

        $rows.Name | Should -Be @('Alpha', 'Beta')
        $rows[0].Problems | Should -Be @('Disks: access denied')
        $rows[0].Created | Should -Be $created
        $rows[1].Problems | Should -BeNullOrEmpty
    }
}
