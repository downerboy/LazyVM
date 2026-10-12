# PublicCommands.Tests.ps1
# What the public commands decide for themselves: confirmations, outcomes
# and output. The work they hand to the private functions is mocked, so
# nothing here needs Hyper-V, the registry or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'Massokissed.LazyVM'

    # Initialize-CommandRun is mocked in most tests; the settings it would
    # load are set directly instead, in BeforeEach.
    function New-TestRoot {
        <# A root folder with one empty VM profile per name given. #>
        param([string[]]$VMs = @())

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($vm in $VMs) {
            $folder = Join-Path -Path $root -ChildPath "Config/VMs/$vm"
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'VM.json') -Value '{ "vCPU": 6 }'
        }
        return $root
    }
}

Describe 'Remove-LazyVM' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-CommandRun { }
        InModuleScope $module { $script:Settings['VMName'] = 'Alpha'; $script:Settings['LogFile'] = 'Alpha.log' }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Get-VMRemovalContext { [pscustomobject]@{ Files = @('x') } }
        Mock -ModuleName $module Invoke-VMRemoval { 'removed' }
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'lists what would go and deletes nothing with -WhatIf' {
        Remove-LazyVM -Name Alpha -WhatIf

        Should -Invoke -ModuleName $module Get-VMRemovalContext -Times 1
        Should -Invoke -ModuleName $module Invoke-VMRemoval -Times 0
    }

    It 'deletes without asking with -Force' {
        Remove-LazyVM -Name Alpha -Force

        Should -Invoke -ModuleName $module Invoke-VMRemoval -Times 1
    }

    It 'does nothing more when there is nothing to remove' {
        Mock -ModuleName $module Get-VMRemovalContext { $null }

        Remove-LazyVM -Name Alpha -Force

        Should -Invoke -ModuleName $module Invoke-VMRemoval -Times 0
    }

    It 'reports a removal that could not finish as an error' {
        Mock -ModuleName $module Invoke-VMRemoval { 'incomplete' }

        { Remove-LazyVM -Name Alpha -Force } | Should -Throw -ExpectedMessage '*only partly removed*'
    }

    It 'always cleans up after itself' {
        Mock -ModuleName $module Get-VMRemovalContext { throw 'boom' }

        { Remove-LazyVM -Name Alpha -Force } | Should -Throw
        Should -Invoke -ModuleName $module Complete-CommandRun -Times 1
    }
}

Describe 'Invoke-LazyVMMaintenance' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-CommandRun { }
        InModuleScope $module { $script:Settings['VMName'] = 'Alpha'; $script:Settings['LogFile'] = 'Alpha.log' }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-Rebuild { $true }
    }

    It 'returns <Expected> when maintenance decides <Decision>' -ForEach @(
        @{ Decision = 'none'; Expected = 'None'; Rebuilds = 0 }
        @{ Decision = 'rearmed'; Expected = 'Rearmed'; Rebuilds = 0 }
        @{ Decision = 'rebuild'; Expected = 'Rebuilt'; Rebuilds = 1 }
        @{ Decision = 'build'; Expected = 'Built'; Rebuilds = 1 }
    ) {
        Mock -ModuleName $module Invoke-Maintenance { $Decision }.GetNewClosure()

        Invoke-LazyVMMaintenance -Name Alpha | Should -Be $Expected
        Should -Invoke -ModuleName $module Invoke-Rebuild -Times $Rebuilds -Exactly
    }

    It 'fails, so the scheduled task shows it, when maintenance could not run' {
        Mock -ModuleName $module Invoke-Maintenance { 'error' }

        { Invoke-LazyVMMaintenance -Name Alpha } | Should -Throw -ExpectedMessage '*could not run*'
    }

    It 'fails when a rebuild does not complete' {
        Mock -ModuleName $module Invoke-Maintenance { 'rebuild' }
        Mock -ModuleName $module Invoke-Rebuild { $false }

        { Invoke-LazyVMMaintenance -Name Alpha } | Should -Throw -ExpectedMessage '*did not complete cleanly*'
    }
}

Describe 'Build-LazyVM' {
    BeforeEach {
        Mock -ModuleName $module Initialize-BuildTarget { }
        Mock -ModuleName $module Register-RebuildSchedule { }
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-CommandRun { }
        InModuleScope $module { $script:Settings['VMName'] = 'Alpha'; $script:Settings['LogFile'] = 'Alpha.log' }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'stops quietly, without an error, when the host is restarting to turn on Hyper-V' {
        Mock -ModuleName $module Invoke-VMBuild { 'RestartPending' }

        { Build-LazyVM -Name Alpha } | Should -Not -Throw
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*restarting*' }
    }

    It 'passes -FromPhase and -NoUnattend on' {
        Mock -ModuleName $module Invoke-VMBuild { 'Complete' }

        Build-LazyVM -Name Alpha -FromPhase 7 -NoUnattend

        Should -Invoke -ModuleName $module Invoke-VMBuild -ParameterFilter { $FromPhase -eq 7 -and $NoUnattend }
    }

    It 'schedules the daily maintenance after a successful build' {
        Mock -ModuleName $module Invoke-VMBuild { 'Complete' }

        Build-LazyVM -Name Alpha

        Should -Invoke -ModuleName $module Register-RebuildSchedule -Times 1
    }

    It 'still finishes a good build when the maintenance cannot be scheduled' {
        Mock -ModuleName $module Invoke-VMBuild { 'Complete' }
        Mock -ModuleName $module Register-RebuildSchedule { throw 'no task scheduler' }

        { Build-LazyVM -Name Alpha } | Should -Not -Throw
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*could not be scheduled*' }
    }

    It 'does not schedule maintenance while the host restarts' {
        Mock -ModuleName $module Invoke-VMBuild { 'RestartPending' }

        Build-LazyVM -Name Alpha

        Should -Invoke -ModuleName $module Register-RebuildSchedule -Times 0
    }

    It 'refuses a phase that does not exist' {
        { Build-LazyVM -Name Alpha -FromPhase 9 } | Should -Throw
    }
}

Describe 'Restore-LazyVMTooling' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-CommandRun { }
        InModuleScope $module { $script:Settings['VMName'] = 'Alpha'; $script:Settings['LogFile'] = 'Alpha.log' }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-ToolingRevert { }
    }

    It 'changes nothing with -WhatIf' {
        Restore-LazyVMTooling -Name Alpha -RestorePoint 20261008-193000 -WhatIf

        Should -Invoke -ModuleName $module Invoke-ToolingRevert -Times 0
    }

    It 'takes a restore point from Get-LazyVMRestorePoint through the pipeline' {
        [pscustomobject]@{ Name = 'Alpha'; RestorePoint = '20261008-193000' } | Restore-LazyVMTooling -Force

        Should -Invoke -ModuleName $module Invoke-ToolingRevert -ParameterFilter { $Stamp -eq '20261008-193000' }
    }

    It 'refuses something that is not a restore point' {
        { Restore-LazyVMTooling -Name Alpha -RestorePoint 'yesterday' -Force } | Should -Throw -ExpectedMessage '*is not a restore point*'
    }
}

Describe 'Get-LazyVMSetting' {
    BeforeEach {
        $root = New-TestRoot -VMs 'Alpha'
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'a test' } }.GetNewClosure()
    }

    It 'lists every setting with its value, source and description' {
        $settings = @(Get-LazyVMSetting -Name Alpha)
        $schemaCount = InModuleScope $module { @((Get-SettingsSchema).properties.Keys | Where-Object { $_ -ne '$schema' }).Count }

        $settings.Count | Should -Be $schemaCount
        $vcpu = $settings | Where-Object Setting -eq 'vCPU'
        $vcpu.Value | Should -Be 6
        $vcpu.Source | Should -Be 'VMs\Alpha\VM.json'
        $vcpu.Description | Should -Not -BeNullOrEmpty
        ($settings | Where-Object Setting -eq 'MemMaxGB').Source | Should -Be 'Default'
    }

    It 'filters by setting name, with wildcards' {
        @(Get-LazyVMSetting -Name Alpha -Setting 'Mem*').Setting | Should -Be @('MemStartGB', 'MemMinGB', 'MemMaxGB')
    }
}

Describe 'New-LazyVM' {
    BeforeEach {
        $root = New-TestRoot
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'a test' } }.GetNewClosure()
        # Where Hyper-V is installed, the new VM must still read as not built.
        if (Get-Command -Name Get-VM -ErrorAction SilentlyContinue) {
            Mock -ModuleName $module Get-VM { }
        }
    }

    It 'creates the profile and returns the new VM' {
        $vm = New-LazyVM -Name Beta 6> $null

        $vm.Name | Should -Be 'Beta'
        $vm.State | Should -Be 'Not built'
        $vm.ProfilePath | Should -Exist
    }

    It 'creates nothing with -WhatIf' {
        New-LazyVM -Name Beta -WhatIf

        Join-Path -Path $root -ChildPath 'Config/VMs/Beta' | Should -Not -Exist
    }

    It 'refuses a name Windows cannot use' {
        { New-LazyVM -Name 'Not Valid' } | Should -Throw -ExpectedMessage "*cannot be used as a VM name*"
    }
}

Describe 'Get-ModuleImportCommand' {
    It 'imports by name when the module is installed where PowerShell looks for modules' {
        InModuleScope $module {
            $base = $ExecutionContext.SessionState.Module.ModuleBase
            $saved = $env:PSModulePath
            try {
                $env:PSModulePath = (Split-Path -Path $base -Parent) + [IO.Path]::PathSeparator + $saved
                Get-ModuleImportCommand | Should -Be "Import-Module -Name 'Massokissed.LazyVM'"
            }
            finally { $env:PSModulePath = $saved }
        }
    }

    It 'imports by path otherwise' {
        InModuleScope $module {
            $saved = $env:PSModulePath
            try {
                $env:PSModulePath = ''
                Get-ModuleImportCommand | Should -BeLike "Import-Module -Name '*Massokissed.LazyVM.psd1'"
            }
            finally { $env:PSModulePath = $saved }
        }
    }
}

Describe 'Initialize-BuildTarget' {
    BeforeEach {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName $module Set-RegisteredRoot { }
        Mock -ModuleName $module Get-DefaultRoot { $root }.GetNewClosure()
    }

    It 'chooses and records the LazyVM folder on first use, and creates the profile' {
        Mock -ModuleName $module Get-RegisteredRoot { $null }

        InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' } 6> $null

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 1 -ParameterFilter { $Path -eq $root }
        Join-Path -Path $root -ChildPath 'Config/VMs/DevBox/VM.json' | Should -Exist
        Join-Path -Path $root -ChildPath 'Config/LazyVM.Settings.json' | Should -Exist
    }

    It 'leaves a chosen folder and an existing profile alone' {
        Mock -ModuleName $module Get-RegisteredRoot { $root }.GetNewClosure()
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Config/VMs/DevBox') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Config/VMs/DevBox/VM.json') -Value '{ "vCPU": 6 }'

        InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' } 6> $null

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 0
        (Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Config/VMs/DevBox/VM.json') -Raw).Trim() | Should -Be '{ "vCPU": 6 }'
    }

    It 'asks for a name when there are no VMs yet' {
        Mock -ModuleName $module Get-RegisteredRoot { $root }.GetNewClosure()

        { InModuleScope $module { Initialize-BuildTarget } } | Should -Throw -ExpectedMessage '*Build-LazyVM -Name DevBox*'
    }
}

Describe 'Select-RootVolume' {
    It 'picks the NTFS volume with the most free space, leaving out virtual disks' {
        $volumes = @(
            [pscustomobject]@{ DriveLetter = 'C'; FileSystem = 'NTFS'; SizeRemaining = 200GB; IsVirtual = $false }
            [pscustomobject]@{ DriveLetter = 'D'; FileSystem = 'NTFS'; SizeRemaining = 900GB; IsVirtual = $false }
            [pscustomobject]@{ DriveLetter = 'S'; FileSystem = 'ReFS'; SizeRemaining = 950GB; IsVirtual = $true }
            [pscustomobject]@{ DriveLetter = 'V'; FileSystem = 'NTFS'; SizeRemaining = 999GB; IsVirtual = $true }
        )

        (InModuleScope $module -Parameters @{ Volumes = $volumes } { param($Volumes) Select-RootVolume -Volumes $Volumes }).DriveLetter | Should -Be 'D'
    }

    It 'returns nothing when no volume will do' {
        $volumes = @([pscustomobject]@{ DriveLetter = 'S'; FileSystem = 'ReFS'; SizeRemaining = 1TB; IsVirtual = $true })

        InModuleScope $module -Parameters @{ Volumes = $volumes } { param($Volumes) Select-RootVolume -Volumes $Volumes } | Should -BeNullOrEmpty
    }
}

Describe 'Get-GuestUserSetting' {
    It 'asks for only what is turned on' {
        $values = InModuleScope $module {
            $script:Settings.Clear()
            $script:Settings['GuestDarkMode'] = $false
            $script:Settings['GuestShowFileExtensions'] = $true
            $script:Settings['GuestTaskbarLeft'] = $true
            $script:Settings['GuestHideTaskbarSearch'] = $false
            Get-GuestUserSetting
        }
        @($values).ForEach({ $_.Name }) | Should -Be @('HideFileExt', 'TaskbarAl')
    }

    It 'asks for nothing when everything is off' {
        InModuleScope $module {
            $script:Settings.Clear()
            foreach ($name in 'GuestDarkMode', 'GuestShowFileExtensions', 'GuestTaskbarLeft', 'GuestHideTaskbarSearch') { $script:Settings[$name] = $false }
            @(Get-GuestUserSetting).Count
        } | Should -Be 0
    }
}

Describe 'Get-FreeControllerLocation' {
    It 'returns <Expected> when <Used> are in use' -ForEach @(
        @{ Used = @(); Expected = 0 }
        @{ Used = @(0, 1); Expected = 2 }
        @{ Used = @(0, 1, 3); Expected = 2 }
        @{ Used = @(1); Expected = 0 }
    ) {
        InModuleScope $module -Parameters @{ Used = $Used } { param($Used) Get-FreeControllerLocation -Used $Used } | Should -Be $Expected
    }

    It 'returns nothing when the controller is full' {
        InModuleScope $module { Get-FreeControllerLocation -Used (0..63) } | Should -BeNullOrEmpty
    }
}

Describe 'Test-WindowsIsoName' {
    It "returns <Expected> for '<Name>'" -ForEach @(
        @{ Name = '26100.1742.240906-0331.ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'; Expected = $true }
        @{ Name = 'Win11Ent_Eval.iso'; Expected = $true }
        @{ Name = 'Windows 11 Enterprise.iso'; Expected = $true }
        @{ Name = 'ubuntu-24.04-desktop-amd64.iso'; Expected = $false }
        @{ Name = 'SQLServer2025-x64-ENU-EntDev.iso'; Expected = $false }
        @{ Name = 'Win11Ent_Eval.zip'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } { param($Name) Test-WindowsIsoName -Name $Name } | Should -Be $Expected
    }
}
