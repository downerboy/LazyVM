# SourceUpdate.Tests.ps1
# The nightly updates from the guest's other installation sources (#293):
# Visual Studio through its installer, PowerShell Gallery modules and dotnet
# global tools. Each source is updated only when the guest has it. The guest
# is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $testVM = InModuleScope $module {
        $vm = [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM\Setup'; VSInstallMinutes = 90 })
        $vm.Runtime.GuestAdminUser = 'lazy'
        $vm
    }
    # Get-CimInstance is Windows-only; the tests mock it.
    Add-MissingCommandStub -Stub @{ 'Get-CimInstance' = { param([string]$ClassName) throw "Get-CimInstance is a test stub; mock it ($ClassName)." } }

    function New-SourceItem {
        <# One item a source lists, as its guest helper reports it. #>
        param([string]$Label, [string]$Version)

        return [pscustomobject]@{ Name = $Label; Label = $Label; Version = $Version }
    }
}

Describe 'Invoke-GuestItemUpdate (#293)' {
    It 'says which items were updated, from which version to which' {
        $notes = @(Invoke-GuestItemUpdate -Items @(New-SourceItem -Label 'dotnet-ef' -Version '9.0.0') -BudgetMinutes 20 -Update { '10.0.1' })

        $notes.Count | Should -Be 1
        $notes[0].Level | Should -Be 'OK'
        $notes[0].Text | Should -Be 'updated: dotnet-ef 9.0.0 -> 10.0.1'
    }

    It 'says an item whose version did not change is up to date' {
        $notes = @(Invoke-GuestItemUpdate -Items @(New-SourceItem -Label 'Pester' -Version '5.7.1') -BudgetMinutes 20 -Update { '5.7.1' })

        $notes[0].Level | Should -Be 'INFO'
        $notes[0].Text | Should -Be 'up to date: Pester 5.7.1'
    }

    It 'keeps going when one update fails, and says why it failed' {
        $items = @((New-SourceItem -Label 'broken' -Version '1.0'), (New-SourceItem -Label 'fine' -Version '1.0'))

        $notes = @(Invoke-GuestItemUpdate -Items $items -BudgetMinutes 20 -Update {
                param($item)
                if ($item.Label -eq 'broken') { throw 'the feed could not be reached' }
                '2.0'
            })

        $notes.Count | Should -Be 2
        $notes[0].Level | Should -Be 'WARN'
        $notes[0].Text | Should -Be 'update failed: broken - the feed could not be reached'
        $notes[1].Text | Should -Be 'updated: fine 1.0 -> 2.0'
    }

    It 'starts no update once its time is up, and says it is tried again tomorrow' {
        $script:updated = 0

        $notes = @(Invoke-GuestItemUpdate -Items @(New-SourceItem -Label 'dotnet-ef' -Version '9.0.0') -BudgetMinutes 0 -Update { $script:updated++; '10.0.1' })

        $script:updated | Should -Be 0
        $notes[0].Text | Should -Be "not started: dotnet-ef - tonight's time for updates ran out; tried again tomorrow"
    }
}

Describe 'ConvertFrom-GuestDotnetToolList (#293)' {
    It 'reads each tool''s package id and version from the rows under the line of dashes' {
        $lines = @(
            'Package Id      Version      Commands'
            '----------------------------------------'
            'dotnet-ef       9.0.0        dotnet-ef'
            'powershell      7.5.4        pwsh'
            ''
        )

        $tools = @(ConvertFrom-GuestDotnetToolList -Lines $lines)

        ($tools.Name -join ',') | Should -Be 'dotnet-ef,powershell'
        ($tools.Version -join ',') | Should -Be '9.0.0,7.5.4'
    }

    It 'returns nothing for a list with no tools, or for an error dotnet printed instead' {
        @(ConvertFrom-GuestDotnetToolList -Lines @('Package Id      Version      Commands', '-----------------------------')).Count | Should -Be 0
        @(ConvertFrom-GuestDotnetToolList -Lines @('No .NET SDKs were found.')).Count | Should -Be 0
    }
}

Describe 'Get-GuestDotnetTool (#293)' {
    BeforeAll {
        # Stands in for dotnet.exe.
        function Invoke-FakeDotnet {
            $script:dotnetArgs = $args
            'Package Id      Version      Commands'
            '----------------------------------------'
            'dotnet-ef       9.0.0        dotnet-ef'
        }
    }

    It 'lists the global tools, each labelled by its package id' {
        Mock Find-GuestDotnet { 'Invoke-FakeDotnet' }

        $tools = @(Get-GuestDotnetTool)

        ($script:dotnetArgs -join ' ') | Should -Be 'tool list --global'
        $tools.Count | Should -Be 1
        $tools[0].Name | Should -Be 'dotnet-ef'
        $tools[0].Label | Should -Be 'dotnet-ef'
        $tools[0].Version | Should -Be '9.0.0'
    }

    It 'returns nothing when the guest has no dotnet' {
        Mock Find-GuestDotnet { }

        @(Get-GuestDotnetTool).Count | Should -Be 0
    }
}

Describe 'Invoke-GuestDotnetToolUpdate (#293)' {
    BeforeAll {
        # Stands in for dotnet.exe: records each update, and fails the one named 'broken'.
        function Invoke-FakeDotnet {
            $script:updates.Add(($args -join ' '))
            if ($args[3] -eq 'broken') { 'Tool ''broken'' failed to update.'; $global:LASTEXITCODE = 1 }
            else { $global:LASTEXITCODE = 0 }
        }
    }

    BeforeEach {
        $script:updates = [System.Collections.Generic.List[string]]::new()
        Mock Find-GuestDotnet { 'Invoke-FakeDotnet' }
        Mock Get-GuestDotnetTool { New-SourceItem -Label 'dotnet-ef' -Version '10.0.1' }
    }

    It 'updates each tool with dotnet tool update, and reads its version afterwards' {
        $notes = @(Invoke-GuestDotnetToolUpdate -Tools @(New-SourceItem -Label 'dotnet-ef' -Version '9.0.0') -BudgetMinutes 20)

        ($script:updates -join ';') | Should -Be 'tool update --global dotnet-ef'
        $notes[0].Text | Should -Be 'updated: dotnet-ef 9.0.0 -> 10.0.1'
    }

    It 'reports a tool dotnet could not update, with what dotnet said' {
        $notes = @(Invoke-GuestDotnetToolUpdate -Tools @(New-SourceItem -Label 'broken' -Version '1.0') -BudgetMinutes 20)

        $notes[0].Level | Should -Be 'WARN'
        $notes[0].Text | Should -BeLike 'update failed: broken - *exit 1*failed to update*'
    }
}

Describe 'Get-GuestGalleryModule (#293)' {
    BeforeEach {
        Mock Get-GuestPowerShellEdition {
            [pscustomobject]@{ Edition = 'Windows PowerShell'; Path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
            [pscustomobject]@{ Edition = 'PowerShell 7'; Path = 'C:\Program Files\PowerShell\7\pwsh.exe' }
        }
        Mock Invoke-GuestPowerShellEdition { [pscustomobject]@{ Name = 'Pester'; Version = '5.7.1' } } -ParameterFilter { $Path -like '*powershell.exe' }
        Mock Invoke-GuestPowerShellEdition { [pscustomobject]@{ Name = 'Pester'; Version = '5.6.0' }; [pscustomobject]@{ Name = 'posh-git'; Version = '1.1.0' } } -ParameterFilter { $Path -like '*pwsh.exe' }
    }

    It 'lists the Gallery modules of each PowerShell edition in the guest, each labelled with its edition and kept with the PowerShell it updates in' {
        $modules = @(Get-GuestGalleryModule)

        ($modules.Label -join ',') | Should -Be 'Pester (Windows PowerShell),Pester (PowerShell 7),posh-git (PowerShell 7)'
        ($modules.Name -join ',') | Should -Be 'Pester,Pester,posh-git'
        $modules[1].Version | Should -Be '5.6.0'
        $modules[2].Shell | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'asks each edition only for modules installed from the PowerShell Gallery' {
        $null = Get-GuestGalleryModule

        Should -Invoke Invoke-GuestPowerShellEdition -Times 2 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Get-InstalledModule' -and "$ScriptBlock" -match "Repository -eq 'PSGallery'" }
    }

    It 'still lists the other editions'' modules when one edition cannot be asked' {
        Mock Invoke-GuestPowerShellEdition { throw 'PowerShellGet is broken' } -ParameterFilter { $Path -like '*powershell.exe' }

        $modules = @(Get-GuestGalleryModule)

        ($modules.Label -join ',') | Should -Be 'Pester (PowerShell 7),posh-git (PowerShell 7)'
    }
}

Describe 'Get-GuestPowerShellEdition (#293)' {
    BeforeAll {
        # What Windows sets, for a test runner that is not Windows.
        if (-not $env:windir) { $env:windir = 'C:\Windows' }
    }

    It 'always has Windows PowerShell, and PowerShell 7 when it is installed' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh' }

        $editions = @(Get-GuestPowerShellEdition)

        ($editions.Edition -join ',') | Should -Be 'Windows PowerShell,PowerShell 7'
        $editions[0].Path | Should -BeLike '*\System32\WindowsPowerShell\v1.0\powershell.exe'
        $editions[1].Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
    }

    It 'has only Windows PowerShell when PowerShell 7 is not installed' {
        Mock Get-Command { } -ParameterFilter { $Name -eq 'pwsh' }

        (@(Get-GuestPowerShellEdition).Edition -join ',') | Should -Be 'Windows PowerShell'
    }
}

Describe 'Invoke-GuestPowerShellEdition (#293)' {
    BeforeAll {
        # Stands in for powershell.exe or pwsh.exe given a script block: runs it, as the real one does in a process of its own.
        function Invoke-FakeShell {
            $script:shellArgs = $args
            $block = $args[[array]::IndexOf($args, '-Command') + 1]
            $arguments = @($args[[array]::IndexOf($args, '-args') + 1])
            try { & $block @arguments; $global:LASTEXITCODE = 0 }
            catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; $global:LASTEXITCODE = 1 }
        }
    }

    It 'runs the script block in that PowerShell, without its profile, and returns its output' {
        $output = @(Invoke-GuestPowerShellEdition -Path 'Invoke-FakeShell' -ScriptBlock { param($name) "hello $name" } -ArgumentList @('lazy'))

        $output | Should -Be @('hello lazy')
        $script:shellArgs[0..2] | Should -Be @('-NoProfile', '-NonInteractive', '-Command')
    }

    It 'throws with the error the script block stopped on' {
        { Invoke-GuestPowerShellEdition -Path 'Invoke-FakeShell' -ScriptBlock { throw 'no such module' } } | Should -Throw '*no such module*'
    }
}

Describe 'Invoke-GuestGalleryModuleUpdate (#293)' {
    BeforeEach {
        Mock Invoke-GuestPowerShellEdition { '2.0.0' }
    }

    It 'updates each module with Update-Module, in the PowerShell it was installed in, and reads its version afterwards' {
        $module = [pscustomobject]@{ Name = 'posh-git'; Label = 'posh-git (PowerShell 7)'; Version = '1.1.0'; Shell = 'C:\Program Files\PowerShell\7\pwsh.exe' }

        $notes = @(Invoke-GuestGalleryModuleUpdate -Modules @($module) -BudgetMinutes 20)

        $notes[0].Text | Should -Be 'updated: posh-git (PowerShell 7) 1.1.0 -> 2.0.0'
        Should -Invoke Invoke-GuestPowerShellEdition -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and $ArgumentList[0] -eq 'posh-git' -and "$ScriptBlock" -match 'Update-Module -Name \$name' -and "$ScriptBlock" -match 'Tls12'
        }
    }
}

Describe 'Update-GuestSource (#293)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Invoke-GuestScript { New-SourceItem -Label 'dotnet-ef' -Version '9.0.0' } -ParameterFilter { $Activity -like 'listing*' }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Level = 'OK'; Text = 'updated: dotnet-ef 9.0.0 -> 10.0.1' } } -ParameterFilter { $Activity -notlike 'listing*' }
    }

    It 'updates what the source lists, within a time budget shorter than the session gives it, and logs each result' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } {
                param($VM)
                Update-GuestSource -VM $VM -Source 'dotnet tool updates' -Nothing 'no dotnet global tools in the guest' -List { Get-GuestDotnetTool } -Update { param($items, $budgetMinutes) Invoke-GuestDotnetToolUpdate -Tools $items -BudgetMinutes $budgetMinutes }
            })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $Activity -eq 'dotnet tool updates' -and @($ArgumentList[0])[0].Label -eq 'dotnet-ef' -and $ArgumentList[1] -gt 0 -and $ArgumentList[1] -le $TimeoutMinutes - 10
        }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'updated: dotnet-ef 9.0.0 -> 10.0.1' }
    }

    It 'updates nothing, and says so, when the guest has nothing from the source' {
        Mock -ModuleName $module Invoke-GuestScript { } -ParameterFilter { $Activity -like 'listing*' }

        InModuleScope $module -Parameters @{ VM = $testVM } {
            param($VM)
            Update-GuestSource -VM $VM -Source 'dotnet tool updates' -Nothing 'no dotnet global tools in the guest' -List { Get-GuestDotnetTool } -Update { }
        }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -ParameterFilter { $Activity -notlike 'listing*' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq 'dotnet tool updates: no dotnet global tools in the guest - nothing to update' }
    }
}

Describe 'Update-GuestDotnetTool and Update-GuestGalleryModule (#293)' {
    BeforeEach {
        Mock -ModuleName $module Update-GuestSource { }
    }

    It 'updates the dotnet global tools as a source of their own' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestDotnetTool -VM $VM }

        Should -Invoke -ModuleName $module Update-GuestSource -Times 1 -Exactly -ParameterFilter {
            $Source -eq 'dotnet tool updates' -and "$List" -match 'Get-GuestDotnetTool' -and "$Update" -match 'Invoke-GuestDotnetToolUpdate'
        }
    }

    It 'updates the PowerShell Gallery modules as a source of their own' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestGalleryModule -VM $VM }

        Should -Invoke -ModuleName $module Update-GuestSource -Times 1 -Exactly -ParameterFilter {
            $Source -eq 'PowerShell Gallery updates' -and "$List" -match 'Get-GuestGalleryModule' -and "$Update" -match 'Invoke-GuestGalleryModuleUpdate'
        }
    }
}

Describe 'Get-GuestProcessInFolder (#293)' {
    It 'names each process running from the folder or below it, once, and none from a folder that only starts the same' {
        Mock Get-CimInstance {
            [pscustomobject]@{ Name = 'devenv.exe'; ExecutablePath = 'C:\VS\Common7\IDE\devenv.exe' }
            [pscustomobject]@{ Name = 'devenv.exe'; ExecutablePath = 'C:\VS\Common7\IDE\devenv.exe' }
            [pscustomobject]@{ Name = 'MSBuild.exe'; ExecutablePath = 'c:\vs\MSBuild\Current\Bin\MSBuild.exe' }
            [pscustomobject]@{ Name = 'other.exe'; ExecutablePath = 'C:\VS2\other.exe' }
            [pscustomobject]@{ Name = 'System'; ExecutablePath = $null }
        }

        (@(Get-GuestProcessInFolder -Folder 'C:\VS') -join ',') | Should -Be 'devenv.exe,MSBuild.exe'
    }
}

Describe 'Update-GuestVisualStudio (#293)' {
    BeforeAll {
        function New-Product {
            param([string]$ProductId = 'Microsoft.VisualStudio.Product.Community', [string]$Version = '18.0.1', [string]$InstanceId = 'a1b2c3d4', [string]$InstallPath = 'C:\VS')

            return [pscustomobject]@{ InstanceId = $InstanceId; ProductId = $ProductId; DisplayName = "Product $InstanceId"; Version = $Version; InstallPath = $InstallPath }
        }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $script:listed = 0
        # The version before the update, then after it.
        Mock -ModuleName $module Get-GuestInstallerProduct { $script:listed++; if ($script:listed -eq 1) { New-Product } else { New-Product -Version '18.0.2' } }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Installer = 'C:\Installer\setup.exe'; Running = @() } } -ParameterFilter { $Activity -like 'checking whether*' }
        Mock -ModuleName $module Invoke-GuestInstaller { 0 }
    }

    It 'updates each Visual Studio with its installer''s update command, quietly and with no restart' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Installer\setup.exe' -and ($ArgumentList -join ' ') -eq 'update --installPath "C:\VS" --quiet --norestart' -and $TimeoutMinutes -eq 90
        }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -eq '  updated: Product a1b2c3d4 18.0.1 -> 18.0.2' }
    }

    It 'says a Visual Studio whose version did not change is up to date' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -eq '  up to date: Product a1b2c3d4 18.0.1' }
    }

    It 'says when the update needs a restart to finish' {
        Mock -ModuleName $module Invoke-GuestInstaller { 3010 }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -like '  updated: Product a1b2c3d4 18.0.1 -> 18.0.2*restart*' }
    }

    It 'skips a Visual Studio that is in use, naming what runs, and tries again the next night' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Installer = 'C:\Installer\setup.exe'; Running = @('devenv.exe') } } -ParameterFilter { $Activity -like 'checking whether*' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  skipped: Product a1b2c3d4 - in use (devenv.exe); tried again tomorrow' }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'checking whether*' -and $ArgumentList[0] -eq 'C:\VS' -and "$ScriptBlock" -match 'Get-GuestProcessInFolder' }
    }

    It 'reports a failed update with what its exit code means, and goes on to the next Visual Studio' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -InstanceId 'one' -InstallPath 'C:\VS1'; New-Product -InstanceId 'two' -InstallPath 'C:\VS2' }
        Mock -ModuleName $module Invoke-GuestInstaller { 1003 } -ParameterFilter { $ArgumentList -contains '"C:\VS1"' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 2 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq '  update failed: Product one - exit 1003: Visual Studio is in use' }
    }

    It 'leaves SSMS alone, and updates nothing when the guest has no Visual Studio' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -ProductId 'Microsoft.VisualStudio.Product.Ssms' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq 'Visual Studio updates: no Visual Studio in the guest - nothing to update' }
    }

    It 'starts no update once its time is up, and says it is tried again tomorrow' {
        Mock -ModuleName $module Get-Date { [datetime]'2026-11-02T03:00:00' }
        Mock -ModuleName $module Invoke-GuestInstaller { Mock -ModuleName LazyVM Get-Date { [datetime]'2026-11-02T05:00:00' }; 0 }
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -InstanceId 'one' -InstallPath 'C:\VS1'; New-Product -InstanceId 'two' -InstallPath 'C:\VS2' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestVisualStudio -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq "  not started: Product two - tonight's time for updates ran out; tried again tomorrow" }
    }
}
