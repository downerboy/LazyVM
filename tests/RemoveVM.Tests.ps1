# RemoveVM.Tests.ps1
# Removing a VM (Remove-LazyVM): what it deletes, and what it keeps because every
# VM, or another VM, still uses it. The planning reads nothing from disk; the
# deleting is tested against a VM folder in TestDrive, with Hyper-V and the
# Task Scheduler left out.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $scriptDir = 'D:\DevVM\Scripts'

    function New-TestVMSetting {
        <# A VM's settings as Read-VMSetting resolves them with the defaults, under D:\DevVM. #>
        param(
            [Parameter(Mandatory)][string]$Name,
            [hashtable]$Overrides = @{}
        )

        $settings = @{
            VMName           = $Name
            Root             = 'D:\DevVM'
            VMRoot           = "D:\DevVM\$Name"
            ConfigDir        = 'D:\DevVM\Shared\Config'
            ProfileDir       = "D:\DevVM\$Name\Config"
            DiskDir          = "D:\DevVM\$Name\Disks"
            OSDiskPath       = "D:\DevVM\$Name\Disks\$Name-OS.vhdx"
            VMConfigDir      = "D:\DevVM\$Name\Virtual Machines"
            ISOPath          = 'D:\DevVM\Shared\ISO\Win11Ent_Eval.iso'
            ISOSearchRoot    = 'D:\DevVM\Shared\ISO'
            SQLIsoPath       = 'D:\DevVM\Shared\Installers\SQLServer2025-x64-ENU-EntDev.iso'
            SQLDiskPath      = "D:\DevVM\$Name\Disks\$Name-SQL.vhdx"
            DevDrivePath     = "D:\DevVM\$Name\Disks\$Name-DevDrive.vhdx"
            SeedDiskPath     = "D:\DevVM\$Name\Disks\$Name-Seed.iso"
            CheckpointDir    = "D:\DevVM\$Name\Checkpoints"
            VSSettingsBackup = "D:\DevVM\$Name\Backups\VisualStudio.vssettings"
            LogFile          = "D:\DevVM\$Name\Logs\$Name.log"
            CredStoreDir     = 'D:\DevVM\Shared\Credentials'
            CredKeyFile      = 'D:\DevVM\Shared\Credentials\.lazyvm.key'
            GuestCredFile    = "D:\DevVM\$Name\Credentials\guest.cred"
            CertCredFile     = "D:\DevVM\$Name\Credentials\certs.cred"
            StateDir         = "D:\DevVM\$Name\State"
            ResumeRegKey     = "HKLM:\SOFTWARE\LazyVM\$Name"
            ResumeTaskName   = "LazyVM-ResumeAfterReboot-$Name"
            ScheduleTaskName = "LazyVM-Maintain-$Name"
        }
        foreach ($key in $Overrides.Keys) {
            $settings[$key] = $Overrides[$key]
        }
        return $settings
    }

    function Get-TestPlan {
        <# Get-VMRemovalPlan, run inside the module, where it lives. #>
        param(
            [Parameter(Mandatory)][hashtable]$Settings,
            [hashtable[]]$OtherSettings = @(),
            [string[]]$AttachedDisks = @(),
            [string[]]$OtherVMDisks = @(),
            [string[]]$ExtraFiles = @(),
            [string[]]$ExtraFolders = @()
        )

        $arguments = @{
            Settings      = $Settings
            OtherSettings = $OtherSettings
            AttachedDisks = $AttachedDisks
            OtherVMDisks  = $OtherVMDisks
            ExtraFiles    = $ExtraFiles
            ExtraFolders  = $ExtraFolders
            ScriptDir     = $scriptDir
        }
        return InModuleScope $module -Parameters @{ Arguments = $arguments } {
            param($Arguments)
            Get-VMRemovalPlan @Arguments
        }
    }
}

Describe 'Test-PathWithin' {
    It "returns <Expected> for '<Path>' within '<Folder>'" -ForEach @(
        @{ Path = 'D:\DevVM\State'; Folder = 'D:\DevVM\State'; Expected = $true }
        @{ Path = 'd:\devvm\state\'; Folder = 'D:\DevVM\State'; Expected = $true }
        @{ Path = 'D:\DevVM\State\Alpha\manifest.json'; Folder = 'D:\DevVM\State'; Expected = $true }
        @{ Path = 'D:\DevVM\State2'; Folder = 'D:\DevVM\State'; Expected = $false }
        @{ Path = 'D:\DevVM'; Folder = 'D:\DevVM\State'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Path = $Path; Folder = $Folder } {
            param($Path, $Folder)
            Test-PathWithin -Path $Path -Folder $Folder
        } | Should -Be $Expected
    }
}

Describe 'Assert-VMRootFolder' {
    It 'returns the VM folder, its name inside the LazyVM folder' {
        InModuleScope $module -Parameters @{ Settings = (New-TestVMSetting -Name 'Alpha') } {
            param($Settings)
            Assert-VMRootFolder -Settings $Settings
        } | Should -Be 'D:\DevVM\Alpha'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'the LazyVM folder itself'; Overrides = @{ VMRoot = 'D:\DevVM' } }
        @{ Case = 'the Shared folder'; Overrides = @{ VMName = 'Shared'; VMRoot = 'D:\DevVM\Shared' } }
        @{ Case = 'an empty VM name'; Overrides = @{ VMName = ''; VMRoot = 'D:\DevVM\' } }
        @{ Case = 'a folder that is not named after the VM'; Overrides = @{ VMRoot = 'D:\DevVM\Beta' } }
        @{ Case = 'a folder outside the LazyVM folder'; Overrides = @{ VMRoot = 'E:\Alpha' } }
        @{ Case = 'an empty LazyVM folder'; Overrides = @{ Root = ''; VMRoot = '\Alpha' } }
    ) {
        $settings = New-TestVMSetting -Name 'Alpha' -Overrides $Overrides
        {
            InModuleScope $module -Parameters @{ Settings = $settings } {
                param($Settings)
                Assert-VMRootFolder -Settings $Settings
            }
        } | Should -Throw -ExpectedMessage '*Refusing to remove*'
    }
}

Describe 'Get-VMRemovalPlan' {
    Context 'with the default layout and no other VM on the host' {
        BeforeAll {
            $plan = Get-TestPlan -Settings (New-TestVMSetting -Name 'Alpha') -AttachedDisks @(
                'D:\DevVM\Alpha\Disks\Alpha-OS_1234.avhdx'
                'D:\DevVM\Alpha\Disks\Alpha-OS.vhdx'
            )
        }

        It 'deletes the VM folder, which holds every disk, checkpoint disk, profile and log' {
            $plan.VMRoot | Should -Be 'D:\DevVM\Alpha'
        }

        It 'does not list anything inside the VM folder apart' {
            @($plan.Files + $plan.Folders | Where-Object { $_ -like 'D:\DevVM\Alpha\*' }) | Should -BeNullOrEmpty
            $plan.Folders | Should -BeNullOrEmpty
        }

        It 'deletes the credential key, which no other VM needs' {
            $plan.Files | Should -Be @('D:\DevVM\Shared\Credentials\.lazyvm.key')
        }

        It 'removes both scheduled tasks and the resume registry key' {
            $plan.Tasks | Should -Be @('LazyVM-Maintain-Alpha', 'LazyVM-ResumeAfterReboot-Alpha')
            $plan.RegistryKey | Should -Be 'HKLM:\SOFTWARE\LazyVM\Alpha'
        }

        It 'keeps nothing back' {
            $plan.Kept | Should -BeNullOrEmpty
        }
    }

    It 'keeps the credential key while another VM uses it' {
        $plan = Get-TestPlan -Settings (New-TestVMSetting -Name 'Alpha') -OtherSettings @(New-TestVMSetting -Name 'Beta')

        $plan.Files | Should -Not -Contain 'D:\DevVM\Shared\Credentials\.lazyvm.key'
        ($plan.Kept | Where-Object { $_.Path -eq 'D:\DevVM\Shared\Credentials\.lazyvm.key' }).Reason | Should -BeLike "*VM 'Beta'*"
    }

    It 'lists a disk the settings put outside the VM folder' {
        $alpha = New-TestVMSetting -Name 'Alpha' -Overrides @{ DevDrivePath = 'E:\DevDrives\Alpha.vhdx' }
        $plan = Get-TestPlan -Settings $alpha

        $plan.Files | Should -Contain 'E:\DevDrives\Alpha.vhdx'
    }

    It 'lists a disk Hyper-V reports attached outside the VM folder, once' {
        $plan = Get-TestPlan -Settings (New-TestVMSetting -Name 'Alpha') -AttachedDisks @(
            'E:\Elsewhere\Extra.vhdx'
            'e:\elsewhere\extra.vhdx'
        )

        @($plan.Files | Where-Object { $_ -like 'E:\Elsewhere\Extra.vhdx' }).Count | Should -Be 1
    }

    It 'keeps a disk outside the VM folder that is attached to another VM' {
        $alpha = New-TestVMSetting -Name 'Alpha' -Overrides @{ SQLDiskPath = 'E:\SQL\Common.vhdx' }
        $plan = Get-TestPlan -Settings $alpha -OtherVMDisks @('E:\SQL\Common.vhdx')

        $plan.Files | Should -Not -Contain 'E:\SQL\Common.vhdx'
        ($plan.Kept | Where-Object { $_.Path -eq 'E:\SQL\Common.vhdx' }).Reason | Should -BeLike '*attached to another VM*'
    }

    It "never deletes a folder outside the VM folder that holds what every VM uses: '<Folder>'" -ForEach @(
        @{ Folder = 'D:\DevVM' }
        @{ Folder = 'D:\DevVM\Shared' }
        @{ Folder = 'D:\DevVM\Shared\ISO' }
        @{ Folder = 'D:\DevVM\Scripts' }
    ) {
        $alpha = New-TestVMSetting -Name 'Alpha' -Overrides @{ StateDir = $Folder }
        $plan = Get-TestPlan -Settings $alpha

        $plan.Folders | Should -Not -Contain $Folder
        ($plan.Kept | Where-Object { $_.Path -eq $Folder }).Reason | Should -BeLike '*which every VM uses*'
    }

    It 'removes nothing when the VM folder holds something another VM uses' {
        $beta = New-TestVMSetting -Name 'Beta' -Overrides @{ DevDrivePath = 'D:\DevVM\Alpha\Disks\Beta-DevDrive.vhdx' }

        { Get-TestPlan -Settings (New-TestVMSetting -Name 'Alpha') -OtherSettings @($beta) } |
            Should -Throw -ExpectedMessage "*nothing has been removed*VM 'Beta' also uses*"
    }

    It 'removes nothing when the VM folder holds a disk attached to another VM' {
        { Get-TestPlan -Settings (New-TestVMSetting -Name 'Alpha') -OtherVMDisks @('D:\DevVM\Alpha\Disks\Borrowed.vhdx') } |
            Should -Throw -ExpectedMessage '*nothing has been removed*attached to another VM*'
    }

    It 'keeps a scheduled task another VM uses' {
        $alpha = New-TestVMSetting -Name 'Alpha' -Overrides @{ ScheduleTaskName = 'Shared-Task' }
        $beta = New-TestVMSetting -Name 'Beta' -Overrides @{ ScheduleTaskName = 'Shared-Task' }

        $plan = Get-TestPlan -Settings $alpha -OtherSettings @($beta)

        $plan.Tasks | Should -Be @('LazyVM-ResumeAfterReboot-Alpha')
        $plan.Kept.Path | Should -Contain 'task Shared-Task'
    }

    It 'keeps a registry key that holds another VM''s key' {
        $alpha = New-TestVMSetting -Name 'Alpha' -Overrides @{ ResumeRegKey = 'HKLM:\SOFTWARE\LazyVM' }

        $plan = Get-TestPlan -Settings $alpha -OtherSettings @(New-TestVMSetting -Name 'Beta')

        $plan.RegistryKey | Should -BeNullOrEmpty
        $plan.Kept.Path | Should -Contain 'HKLM:\SOFTWARE\LazyVM'
    }
}

Describe 'Invoke-VMRemoval' {
    BeforeEach {
        # A VM folder as a build leaves it, with a checkpoint disk that is no
        # longer in the VM's disk chain, so nothing lists it (#72).
        $root = Join-Path -Path $TestDrive -ChildPath 'LazyVM'
        $vmRoot = Join-Path -Path $root -ChildPath 'Alpha'
        $shared = Join-Path -Path $root -ChildPath 'Shared'
        foreach ($folder in 'Disks', 'Config', 'Logs', 'Virtual Machines') {
            New-Item -ItemType Directory -Path (Join-Path -Path $vmRoot -ChildPath $folder) -Force | Out-Null
        }
        New-Item -ItemType Directory -Path (Join-Path -Path $shared -ChildPath 'ISO') -Force | Out-Null
        foreach ($file in 'Disks\Alpha-OS.vhdx', 'Disks\Alpha-OS_28A36081-36CC-4C10-9FDE-A1A5489978B7.avhdx', 'Config\VM.json', 'Config\Tooling.Template.json', 'Logs\Alpha.log') {
            Set-Content -LiteralPath (Join-Path -Path $vmRoot -ChildPath $file) -Value 'x'
        }
        $iso = Join-Path -Path $shared -ChildPath 'ISO\Win11Ent_Eval.iso'
        Set-Content -LiteralPath $iso -Value 'x'

        $settings = @{ VMName = 'Alpha'; LogFile = (Join-Path -Path $vmRoot -ChildPath 'Logs\Alpha.log') }
        $context = [pscustomobject]@{
            Machine     = $null
            Tasks       = @()
            RegistryKey = $null
            VMRoot      = $vmRoot
            Files       = @()
            Folders     = @()
            RotatedLogs = @()
            Total       = 0
        }
    }

    It 'deletes the whole VM folder, including a checkpoint disk nothing listed' {
        $outcome = InModuleScope $module -Parameters @{ Settings = $settings; Context = $context } {
            param($Settings, $Context)
            Start-Log -Path $Settings.LogFile -MaxSizeMB 10
            Invoke-VMRemoval -VM ([VMContext]::new($Settings)) -Context $Context 6>$null
        }

        "$outcome" | Should -Be 'Removed'
        Test-Path -LiteralPath $vmRoot | Should -BeFalse
    }

    It 'deletes the copy of the tooling list the VM was built from, with its Config folder (#71)' {
        $templateCopy = Join-Path -Path $vmRoot -ChildPath 'Config\Tooling.Template.json'
        $templateCopy | Should -Exist

        InModuleScope $module -Parameters @{ Settings = $settings; Context = $context } {
            param($Settings, $Context)
            Start-Log -Path $Settings.LogFile -MaxSizeMB 10
            $null = Invoke-VMRemoval -VM ([VMContext]::new($Settings)) -Context $Context 6>$null
        }

        $templateCopy | Should -Not -Exist
    }

    It 'leaves the Shared folder alone' {
        InModuleScope $module -Parameters @{ Settings = $settings; Context = $context } {
            param($Settings, $Context)
            Start-Log -Path $Settings.LogFile -MaxSizeMB 10
            $null = Invoke-VMRemoval -VM ([VMContext]::new($Settings)) -Context $Context 6>$null
        }

        Test-Path -LiteralPath $iso | Should -BeTrue
    }
}
