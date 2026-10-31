# PublicCommands.Tests.ps1
# What the public commands decide for themselves: confirmations, outcomes
# and output. The work they hand to the private functions is mocked, so
# nothing here needs Hyper-V, the registry or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Initialize-CommandRun is mocked in most tests, returning this context
    # instead of reading settings files. Classes defined in a module are only
    # visible inside it, so the context is made there.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; LogFile = 'Alpha.log' }) }

    function New-TestRoot {
        <# A root folder with one empty VM profile per name given. #>
        param([string[]]$VMs = @())

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($vm in $VMs) {
            $folder = Join-Path -Path $root -ChildPath "$vm/Config"
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'VM.json') -Value '{ "vCPU": 6 }'
        }
        return $root
    }
}

Describe 'Remove-LazyVM' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        # GetNewClosure keeps only this block's own variables.
        $vm = $testVM
        Mock -ModuleName $module Initialize-CommandRun { $vm }.GetNewClosure()
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Get-VMRemovalContext { [pscustomobject]@{ Files = @('x') } }
        Mock -ModuleName $module Invoke-VMRemoval { 'Removed' }
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
        Mock -ModuleName $module Invoke-VMRemoval { 'Incomplete' }

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
        # GetNewClosure keeps only this block's own variables.
        $vm = $testVM
        Mock -ModuleName $module Initialize-CommandRun { $vm }.GetNewClosure()
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Sync-VMProfile { }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Invoke-Rebuild { $true }
    }

    It 'returns <Expected> when maintenance leaves <Step>' -ForEach @(
        @{ Step = 'None'; Expected = 'None'; Rebuilds = 0 }
        @{ Step = 'Rearmed'; Expected = 'Rearmed'; Rebuilds = 0 }
        @{ Step = 'Rebuild'; Expected = 'Rebuilt'; Rebuilds = 1 }
        @{ Step = 'Build'; Expected = 'Built'; Rebuilds = 1 }
    ) {
        Mock -ModuleName $module Invoke-Maintenance { $Step }.GetNewClosure()

        Invoke-LazyVMMaintenance -Name Alpha | Should -Be $Expected
        Should -Invoke -ModuleName $module Invoke-Rebuild -Times $Rebuilds -Exactly
    }

    It 'fails, so the scheduled task shows it, when maintenance could not run' {
        Mock -ModuleName $module Invoke-Maintenance { 'Error' }

        { Invoke-LazyVMMaintenance -Name Alpha } | Should -Throw -ExpectedMessage '*could not run*'
    }

    It 'fails when a rebuild does not complete' {
        Mock -ModuleName $module Invoke-Maintenance { 'Rebuild' }
        Mock -ModuleName $module Invoke-Rebuild { $false }

        { Invoke-LazyVMMaintenance -Name Alpha } | Should -Throw -ExpectedMessage '*did not complete cleanly*'
    }

    It 'says what a run would do and changes nothing with -WhatIf (#18)' {
        Mock -ModuleName $module Get-MaintenancePreview { 'Run the daily checks' }
        Mock -ModuleName $module Invoke-Maintenance { 'None' }

        $result = @(Invoke-LazyVMMaintenance -Name Alpha -WhatIf)

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Get-MaintenancePreview -Times 1 -Exactly
        Should -Invoke -ModuleName $module Invoke-Maintenance -Times 0
        Should -Invoke -ModuleName $module Sync-VMProfile -Times 0
        Should -Invoke -ModuleName $module Initialize-CommandRun -Times 1 -Exactly -ParameterFilter { -not $RecordHardware }
    }
}

Describe 'Build-LazyVM' {
    BeforeEach {
        Mock -ModuleName $module Initialize-BuildTarget { }
        Mock -ModuleName $module Register-RebuildSchedule { }
        Mock -ModuleName $module Assert-Administrator { }
        # GetNewClosure keeps only this block's own variables.
        $vm = $testVM
        Mock -ModuleName $module Initialize-CommandRun { $vm }.GetNewClosure()
        Mock -ModuleName $module Complete-CommandRun { }
        Mock -ModuleName $module Sync-VMProfile { }
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'stops quietly, without an error, when the host is restarting to turn on Hyper-V' {
        Mock -ModuleName $module Invoke-VMBuild { 'RestartPending' }

        { Build-LazyVM -Name Alpha } | Should -Not -Throw
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*restarting*' }
    }

    It 'brings the VM''s configuration up to date before building' {
        Mock -ModuleName $module Invoke-VMBuild { 'Complete' }

        Build-LazyVM -Name Alpha

        Should -Invoke -ModuleName $module Sync-VMProfile -Times 1
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

    It 'sets up nothing and builds nothing with -WhatIf (#18)' {
        Mock -ModuleName $module Invoke-VMBuild { 'Complete' }

        Build-LazyVM -Name Alpha -FromPhase 7 -WhatIf

        Should -Invoke -ModuleName $module Initialize-BuildTarget -Times 0
        Should -Invoke -ModuleName $module Invoke-VMBuild -Times 0
        Should -Invoke -ModuleName $module Register-RebuildSchedule -Times 0
    }

    It 'refuses a phase that does not exist' {
        { Build-LazyVM -Name Alpha -FromPhase 9 } | Should -Throw -ExpectedMessage '*There is no build phase 9*'
    }
}

Describe 'Restore-LazyVMTooling' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        # GetNewClosure keeps only this block's own variables.
        $vm = $testVM
        Mock -ModuleName $module Initialize-CommandRun { $vm }.GetNewClosure()
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
        $settings.Name | Select-Object -Unique | Should -Be 'Alpha'
        $vcpu = $settings | Where-Object Setting -eq 'vCPU'
        $vcpu.Value | Should -Be 6
        $vcpu.Source | Should -Be 'Alpha\Config\VM.json'
        $vcpu.Description | Should -Not -BeNullOrEmpty
        ($settings | Where-Object Setting -eq 'MemMaxGB').Source | Should -Be 'Default'
    }

    It 'filters by setting name, with wildcards' {
        @(Get-LazyVMSetting -Name Alpha -Setting 'Mem*').Setting | Should -Be @('MemStartGB', 'MemMinGB', 'MemMaxGB')
    }
}

Describe 'Pipeline input' {
    It '<_> takes Name from the pipeline, by value and by property name' -ForEach @(
        'Build-LazyVM', 'Get-LazyVM', 'Get-LazyVMCredential', 'Get-LazyVMLicense', 'Get-LazyVMRestorePoint',
        'Get-LazyVMSetting', 'Get-LazyVMTooling', 'Invoke-LazyVMMaintenance', 'Invoke-LazyVMRebuild',
        'Register-LazyVMMaintenance', 'Remove-LazyVM', 'Restore-LazyVMState', 'Save-LazyVMState',
        'Save-LazyVMTooling', 'Set-LazyVMCredential'
    ) {
        $attribute = (Get-Command -Name $_).Parameters['Name'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $attribute.ValueFromPipeline | Should -BeTrue
        $attribute.ValueFromPipelineByPropertyName | Should -BeTrue
    }

    It 'runs once per VM piped in' {
        $root = New-TestRoot -VMs 'Alpha', 'Beta'
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'a test' } }.GetNewClosure()

        $byObject = @(Get-LazyVM | Get-LazyVMSetting -Setting 'vCPU')
        $byName = @('Alpha', 'Beta' | Get-LazyVMSetting -Setting 'vCPU')

        $byObject.Name | Should -Be @('Alpha', 'Beta')
        $byName.Name | Should -Be @('Alpha', 'Beta')
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

        Join-Path -Path $root -ChildPath 'Beta' | Should -Not -Exist
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
                Get-ModuleImportCommand | Should -Be "Import-Module -Name 'LazyVM'"
            }
            finally { $env:PSModulePath = $saved }
        }
    }

    It 'imports by path otherwise' {
        InModuleScope $module {
            $saved = $env:PSModulePath
            try {
                $env:PSModulePath = ''
                Get-ModuleImportCommand | Should -BeLike "Import-Module -Name '*LazyVM.psd1'"
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
        Join-Path -Path $root -ChildPath 'DevBox/Config/VM.json' | Should -Exist
        Join-Path -Path $root -ChildPath 'Shared/Config/LazyVM.Settings.json' | Should -Exist
    }

    It 'leaves a chosen folder and an existing profile alone' {
        Mock -ModuleName $module Get-RegisteredRoot { $root }.GetNewClosure()
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'DevBox/Config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'DevBox/Config/VM.json') -Value '{ "vCPU": 6 }'

        InModuleScope $module { Initialize-BuildTarget -Name 'DevBox' } 6> $null

        Should -Invoke -ModuleName $module Set-RegisteredRoot -Times 0
        (Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'DevBox/Config/VM.json') -Raw).Trim() | Should -Be '{ "vCPU": 6 }'
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

Describe 'Get-MissingProductExtension' {
    BeforeAll {
        $product = @{
            Extensions     = @('https://marketplace.visualstudio.com/items?itemName=A.One')
            UserExtensions = @(
                @{ Id = 'two'; DisplayName = 'Two'; Publisher = 'B'; MarketplaceItem = 'B.Two' }
                @{ Id = 'three'; DisplayName = 'Three'; Publisher = 'C' }
            )
        }
    }

    It 'lists everything when the guest has none of them' {
        $missing = InModuleScope $module -Parameters @{ Product = $product } {
            param($Product)
            Get-MissingProductExtension -Product ([ToolingProduct]::FromObject($Product)) -Observed $null
        }
        @($missing).Count | Should -Be 3
        @($missing | Where-Object { $_.Link }).Count | Should -Be 2
    }

    It 'leaves out what the guest has, by link or by id' {
        $observed = @{
            Extensions     = @('https://marketplace.visualstudio.com/items?itemName=B.Two')
            UserExtensions = @(@{ Id = 'three' })
        }
        $missing = InModuleScope $module -Parameters @{ Product = $product; Observed = $observed } {
            param($Product, $Observed)
            Get-MissingProductExtension -Product ([ToolingProduct]::FromObject($Product)) -Observed ([ToolingProduct]::FromObject($Observed))
        }
        @($missing).ForEach({ $_.Link }) | Should -Be @('https://marketplace.visualstudio.com/items?itemName=A.One')
    }
}

Describe 'Test-UnsignedExtensionAllowed' {
    It 'returns <Expected> when <Case>' -ForEach @(
        @{ Case = 'an extension is listed'; Allowed = @('Pub.Unsigned'); Expected = $true }
        @{ Case = 'no extension is listed'; Allowed = @(); Expected = $false }
        @{ Case = 'only another extension is listed'; Allowed = @('Pub.Other'); Expected = $false }
    ) {
        $links = @('https://marketplace.visualstudio.com/items?itemName=Pub.Signed', 'https://marketplace.visualstudio.com/items?itemName=Pub.Unsigned')

        InModuleScope $module -Parameters @{ Links = $links; Allowed = $Allowed } {
            param($Links, $Allowed)
            Test-UnsignedExtensionAllowed -Links $Links -Allowed $Allowed
        } | Should -Be $Expected
    }
}

Describe 'Get-GuestUserSetting' {
    It 'asks for only what is turned on' {
        $settings = @{ GuestDarkMode = $false; GuestShowFileExtensions = $true; GuestTaskbarLeft = $true; GuestHideTaskbarSearch = $false }

        $values = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Get-GuestUserSetting -Settings $Settings }

        @($values).ForEach({ $_.Name }) | Should -Be @('HideFileExt', 'TaskbarAl')
    }

    It 'asks for nothing when everything is off' {
        $settings = @{ GuestDarkMode = $false; GuestShowFileExtensions = $false; GuestTaskbarLeft = $false; GuestHideTaskbarSearch = $false }

        InModuleScope $module -Parameters @{ Settings = $settings } {
            param($Settings)
            @(Get-GuestUserSetting -Settings $Settings).Count
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

Describe 'Show-LazyVM' {
    It 'writes the version, the LazyVM folder, each VM and the module''s folder, then the command list' {
        $root = New-TestRoot -VMs 'Alpha', 'Beta'
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'a test' } }

        $output = @(Show-LazyVM)

        $loaded = Get-Module -Name $module
        $output[0] | Should -Be "LazyVM $($loaded.Version)"
        $output[1] | Should -Be "Folder  : $root"
        $output[2] | Should -Be 'VMs     : Alpha'
        $output[3] | Should -Be '          Beta'
        $output[4] | Should -Be "Module  : $($loaded.ModuleBase)"

        # Then what Get-Help lists for the module: every exported command
        # with its synopsis, and none of the internal ones.
        $listed = @($output | Select-Object -Skip 5)
        $listed.Name | Sort-Object | Should -Be @($loaded.ExportedFunctions.Keys | Sort-Object)
        ($listed | Where-Object { $_.Name -eq 'Build-LazyVM' }).Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'says what to do when no folder has been chosen or there are no VMs yet' {
        Mock -ModuleName $module Resolve-LazyVMRoot { throw 'LazyVM does not know which folder to keep its VMs in yet.' }

        $output = @(Show-LazyVM)

        $output[1] | Should -Be 'Folder  : LazyVM does not know which folder to keep its VMs in yet.'
        $output[2] | Should -BeLike 'VMs     : none yet*Build-LazyVM*'
        $output[3] | Should -BeLike 'Module  : *'
    }
}
