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
        Mock -ModuleName $module Remove-VMAndItsFiles { 'removed' }
        Mock -ModuleName $module Write-Log { }
    }

    It 'lists what would go and deletes nothing with -WhatIf' {
        Remove-LazyVM -Name Alpha -WhatIf

        Should -Invoke -ModuleName $module Get-VMRemovalContext -Times 1
        Should -Invoke -ModuleName $module Remove-VMAndItsFiles -Times 0
    }

    It 'deletes without asking with -Force' {
        Remove-LazyVM -Name Alpha -Force

        Should -Invoke -ModuleName $module Remove-VMAndItsFiles -Times 1
    }

    It 'does nothing more when there is nothing to remove' {
        Mock -ModuleName $module Get-VMRemovalContext { $null }

        Remove-LazyVM -Name Alpha -Force

        Should -Invoke -ModuleName $module Remove-VMAndItsFiles -Times 0
    }

    It 'reports a removal that could not finish as an error' {
        Mock -ModuleName $module Remove-VMAndItsFiles { 'incomplete' }

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
        Mock -ModuleName $module Write-Log { }
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
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Initialize-CommandRun { }
        InModuleScope $module { $script:Settings['VMName'] = 'Alpha'; $script:Settings['LogFile'] = 'Alpha.log' }
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Write-Log { }
    }

    It 'stops quietly, without an error, when the host is restarting to turn on Hyper-V' {
        Mock -ModuleName $module Invoke-VMBuild { 'RestartPending' }

        { Build-LazyVM -Name Alpha } | Should -Not -Throw
        Should -Invoke -ModuleName $module Write-Log -ParameterFilter { $Message -like '*restarting*' }
    }

    It 'passes -FromPhase and -NoUnattend on' {
        Mock -ModuleName $module Invoke-VMBuild { 'Complete' }

        Build-LazyVM -Name Alpha -FromPhase 7 -NoUnattend

        Should -Invoke -ModuleName $module Invoke-VMBuild -ParameterFilter { $FromPhase -eq 7 -and $NoUnattend }
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
        Mock -ModuleName $module Write-Log { }
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
