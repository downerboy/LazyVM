# SourceUpdate.Tests.ps1
# The nightly updates from the guest's other installation sources (#293):
# Visual Studio Installer products (Visual Studio, SSMS), PowerShell Gallery modules and dotnet
# global tools. Each source is updated only when the guest has it. The guest
# is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    # What Windows sets, for a test runner that is not Windows.
    if (-not $env:windir) { $env:windir = 'C:\Windows' }
    if (-not $env:ProgramFiles) { $env:ProgramFiles = 'C:\Program Files' }

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

Describe 'ConvertTo-UpdateResult (#293)' {
    It 'says <Label> was <Case>' -ForEach @(
        @{ Case = 'updated, from which version to which'; Label = 'dotnet-ef'; Before = '9.0.0'; After = '10.0.1'; Level = 'OK'; Text = 'updated: dotnet-ef 9.0.0 -> 10.0.1' }
        @{ Case = 'up to date when its version did not change'; Label = 'Pester'; Before = '5.7.1'; After = '5.7.1'; Level = 'INFO'; Text = 'up to date: Pester 5.7.1' }
        @{ Case = 'not updated when its version cannot be read afterwards'; Label = 'Pester'; Before = '5.7.1'; After = $null; Level = 'WARN'; Text = 'update failed: Pester - its version could not be read afterwards' }
    ) {
        $result = InModuleScope $module -Parameters @{ Label = $Label; Before = $Before; After = $After } {
            param($Label, $Before, $After)
            ConvertTo-UpdateResult -Label $Label -Before $Before -After $After
        }

        $result.Level | Should -Be $Level
        $result.Text | Should -Be $Text
    }
}

Describe 'Invoke-ItemUpdate (#293)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
    }

    It 'logs each result as it comes, and returns the results' {
        $results = @(InModuleScope $module {
                Invoke-ItemUpdate -Items @([pscustomobject]@{ Label = 'one' }, [pscustomobject]@{ Label = 'two' }) -BudgetMinutes 20 -Update {
                    param($item)
                    New-UpdateResult -Level OK -Text "updated: $($item.Label)"
                }
            })

        ($results.Text -join ',') | Should -Be 'updated: one,updated: two'
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  updated: one' -and $Level -eq 'OK' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  updated: two' -and $Level -eq 'OK' }
    }

    It 'keeps going when one update throws, and says why it failed' {
        $results = @(InModuleScope $module {
                Invoke-ItemUpdate -Items @([pscustomobject]@{ Label = 'broken' }, [pscustomobject]@{ Label = 'fine' }) -BudgetMinutes 20 -Update {
                    param($item)
                    if ($item.Label -eq 'broken') { throw 'the guest stopped answering' }
                    New-UpdateResult -Level OK -Text 'updated: fine'
                }
            })

        $results[0].Level | Should -Be 'WARN'
        $results[0].Text | Should -Be 'update failed: broken - the guest stopped answering'
        $results[1].Text | Should -Be 'updated: fine'
    }

    It 'gives each update the caller''s state and when tonight''s budget ends, so the update needs nothing from the scope it runs in' {
        $results = @(InModuleScope $module {
                $state = @{ Greeting = 'hello' }
                Invoke-ItemUpdate -Items @([pscustomobject]@{ Label = 'one' }) -BudgetMinutes 20 -State $state -Update {
                    param($item, $state, $deadline)
                    New-UpdateResult -Level INFO -Text "$($state.Greeting) $($item.Label) $($deadline -gt (Get-Date))"
                }
            })

        $results[0].Text | Should -Be 'hello one True'
    }

    It 'starts no update once its time is up, and says it is tried again tomorrow' {
        $results = @(InModuleScope $module {
                $script:started = 0
                Invoke-ItemUpdate -Items @([pscustomobject]@{ Label = 'dotnet-ef' }) -BudgetMinutes 0 -Update { $script:started++ }
            })

        (InModuleScope $module { $script:started }) | Should -Be 0
        $results[0].Text | Should -Be "not started: dotnet-ef - tonight's time for updates ran out; tried again tomorrow"
    }
}

Describe 'Update-GuestSource (#293)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Invoke-GuestScript {
            [pscustomobject]@{ Items = @((New-SourceItem -Label 'dotnet-ef' -Version '9.0.0'), (New-SourceItem -Label 'csharpier' -Version '1.0.0')); Notes = @([pscustomobject]@{ Level = 'WARN'; Text = 'listing note' }) }
        } -ParameterFilter { $Activity -like 'listing*' }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Version = '10.0.1'; Notes = @([pscustomobject]@{ Level = 'INFO'; Text = "note for $($ArgumentList[0].Label)" }) } } -ParameterFilter { $Activity -notlike 'listing*' }
    }

    It 'updates each item in a guest call of its own, with its own time limit, and logs each result and the notes that came with it' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } {
                param($VM)
                Update-GuestSource -VM $VM -Label 'dotnet tool updates' -EmptyMessage 'no dotnet global tools in the guest' -List { Get-GuestDotnetTool } -Update { param($tool) Invoke-GuestDotnetToolUpdate -Tool $tool }
            })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 2 -Exactly -ParameterFilter {
            $Activity -like 'dotnet tool updates - *' -and $TimeoutMinutes -gt 0 -and "$ScriptBlock" -match 'Invoke-GuestDotnetToolUpdate'
        }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'listing note' }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'note for csharpier' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  updated: dotnet-ef 9.0.0 -> 10.0.1' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  updated: csharpier 1.0.0 -> 10.0.1' }
    }

    It 'gives each item less time than the night''s budget for the source' {
        InModuleScope $module -Parameters @{ VM = $testVM } {
            param($VM)
            Update-GuestSource -VM $VM -Label 'dotnet tool updates' -EmptyMessage 'none' -List { } -Update { }
        }

        $budget = InModuleScope $module { $script:SourceUpdateBudgetMinutes }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 2 -Exactly -ParameterFilter { $Activity -notlike 'listing*' -and $TimeoutMinutes -lt $budget }
    }

    It 'updates nothing, and says so, when the guest has nothing from the source' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Items = @(); Notes = @() } } -ParameterFilter { $Activity -like 'listing*' }

        InModuleScope $module -Parameters @{ VM = $testVM } {
            param($VM)
            Update-GuestSource -VM $VM -Label 'dotnet tool updates' -EmptyMessage 'no dotnet global tools in the guest' -List { } -Update { }
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
            $Label -eq 'dotnet tool updates' -and "$List" -match 'Get-GuestDotnetTool' -and "$Update" -match 'Invoke-GuestDotnetToolUpdate'
        }
    }

    It 'updates the PowerShell Gallery modules as a source of their own' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestGalleryModule -VM $VM }

        Should -Invoke -ModuleName $module Update-GuestSource -Times 1 -Exactly -ParameterFilter {
            $Label -eq 'PowerShell Gallery updates' -and "$List" -match 'Get-GuestGalleryModule' -and "$Update" -match 'Invoke-GuestGalleryModuleUpdate'
        }
    }

    It 'forgets, while listing, the removals recorded for modules no longer installed, in the editions listed only (#309)' {
        Mock -ModuleName $module Update-GuestSource { $List }
        $list = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestGalleryModule -VM $VM }
        $listing = [pscustomobject]@{ Items = @((New-SourceItem -Label 'posh-git (PowerShell 7)' -Version '1.1.0')); Notes = @(); Editions = @('PowerShell 7') }
        Mock Get-GuestGalleryModule { $listing }
        Mock Remove-GuestModuleRemovalStale { }

        # As the guest runs it: from its text, with the guest helpers loaded.
        $result = & ([scriptblock]::Create("$list"))

        $result | Should -Be $listing
        Should -Invoke Remove-GuestModuleRemovalStale -Times 1 -Exactly
        Should -Invoke Remove-GuestModuleRemovalStale -Times 1 -Exactly -ParameterFilter { $Edition -eq 'PowerShell 7' -and (@($Label) -join ',') -eq 'posh-git (PowerShell 7)' }
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

    It 'updates the tool with dotnet tool update, and returns its version afterwards' {
        $outcome = Invoke-GuestDotnetToolUpdate -Tool (New-SourceItem -Label 'dotnet-ef' -Version '9.0.0')

        ($script:updates -join ';') | Should -Be 'tool update --global dotnet-ef'
        $outcome.Version | Should -Be '10.0.1'
        @($outcome.Notes).Count | Should -Be 0
    }

    It 'returns no version when the tool is gone afterwards' {
        Mock Get-GuestDotnetTool { }

        (Invoke-GuestDotnetToolUpdate -Tool (New-SourceItem -Label 'dotnet-ef' -Version '9.0.0')).Version | Should -BeNullOrEmpty
    }

    It 'throws with what dotnet said when it could not update the tool' {
        { Invoke-GuestDotnetToolUpdate -Tool (New-SourceItem -Label 'broken' -Version '1.0') } | Should -Throw '*exit 1*failed to update*'
    }
}

Describe 'Get-GuestPowerShellEdition (#293)' {
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

Describe 'Get-GuestGalleryModule (#293)' {
    BeforeEach {
        Mock Get-GuestPowerShellEdition {
            [pscustomobject]@{ Edition = 'Windows PowerShell'; Path = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
            [pscustomobject]@{ Edition = 'PowerShell 7'; Path = 'C:\Program Files\PowerShell\7\pwsh.exe' }
        }
        Mock Invoke-GuestPowerShellEdition { [pscustomobject]@{ Name = 'Pester'; Version = '5.7.1' } } -ParameterFilter { $Path -like '*powershell.exe' }
        Mock Invoke-GuestPowerShellEdition { [pscustomobject]@{ Name = 'Pester'; Version = '5.6.0' }; [pscustomobject]@{ Name = 'posh-git'; Version = '1.1.0' } } -ParameterFilter { $Path -like '*pwsh.exe' }
    }

    It 'names the editions it listed, and only reads (#309)' {
        Mock Remove-GuestModuleRemovalStale { }

        $listing = Get-GuestGalleryModule

        ($listing.Editions -join ',') | Should -Be 'Windows PowerShell,PowerShell 7'
        Should -Invoke Remove-GuestModuleRemovalStale -Times 0
    }

    It 'lists the Gallery modules of each PowerShell edition in the guest, each labelled with its edition and kept with the PowerShell it updates in' {
        $listing = Get-GuestGalleryModule

        ($listing.Items.Label -join ',') | Should -Be 'Pester (Windows PowerShell),Pester (PowerShell 7),posh-git (PowerShell 7)'
        ($listing.Items.Name -join ',') | Should -Be 'Pester,Pester,posh-git'
        $listing.Items[1].Version | Should -Be '5.6.0'
        $listing.Items[2].Path | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        @($listing.Notes).Count | Should -Be 0
    }

    It 'asks each edition only for modules installed from the PowerShell Gallery' {
        $null = Get-GuestGalleryModule

        Should -Invoke Invoke-GuestPowerShellEdition -Times 2 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Get-InstalledModule' -and "$ScriptBlock" -match "Repository -eq 'PSGallery'" }
    }

    It 'leaves PowerShellGet and PackageManagement alone, which would be updating themselves, and says so' {
        Mock Invoke-GuestPowerShellEdition { [pscustomobject]@{ Name = 'PowerShellGet'; Version = '2.2.5' }; [pscustomobject]@{ Name = 'PackageManagement'; Version = '1.4.8.1' }; [pscustomobject]@{ Name = 'Pester'; Version = '5.7.1' } } -ParameterFilter { $Path -like '*powershell.exe' }

        $listing = Get-GuestGalleryModule

        ($listing.Items.Label -join ',') | Should -Be 'Pester (Windows PowerShell),Pester (PowerShell 7),posh-git (PowerShell 7)'
        @($listing.Notes | Where-Object { $_.Level -eq 'INFO' -and $_.Text -like 'left alone: PowerShellGet (Windows PowerShell)*' }).Count | Should -Be 1
        @($listing.Notes | Where-Object { $_.Level -eq 'INFO' -and $_.Text -like 'left alone: PackageManagement (Windows PowerShell)*' }).Count | Should -Be 1
    }

    It 'still lists the other editions'' modules when one edition cannot be asked, and says which and why' {
        Mock Invoke-GuestPowerShellEdition { throw 'PowerShellGet is broken' } -ParameterFilter { $Path -like '*powershell.exe' }

        $listing = Get-GuestGalleryModule

        ($listing.Items.Label -join ',') | Should -Be 'Pester (PowerShell 7),posh-git (PowerShell 7)'
        ($listing.Editions -join ',') | Should -Be 'PowerShell 7'
        @($listing.Notes).Count | Should -Be 1
        $listing.Notes[0].Level | Should -Be 'WARN'
        $listing.Notes[0].Text | Should -Be 'could not list the modules of Windows PowerShell: PowerShellGet is broken'
    }
}

Describe 'Invoke-GuestGalleryModuleUpdate (#293)' {
    BeforeAll {
        $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $posh = [pscustomobject]@{ Name = 'posh-git'; Label = 'posh-git (PowerShell 7)'; Version = '1.1.0'; Path = $pwsh }

        function New-InstalledModule {
            param([string]$Version, [string]$Location = 'C:\Program Files\PowerShell\Modules\posh-git')

            return [pscustomobject]@{ Name = 'posh-git'; Version = $Version; InstalledLocation = "$Location\$Version" }
        }
    }

    BeforeEach {
        # 0.5.0 is kept side by side on purpose; 1.0.0 is the one before the newest.
        $script:installed = @((New-InstalledModule -Version '1.1.0'), (New-InstalledModule -Version '1.0.0'), (New-InstalledModule -Version '0.5.0'))
        # Runs the script block here, as the edition's own process would.
        Mock Invoke-GuestPowerShellEdition { & $ScriptBlock @ArgumentList }
        # As Get-InstalledModule does, one object per location without -AllVersions, every version with it.
        Mock Get-InstalledModule {
            if ($AllVersions) { return $script:installed }
            $script:installed | Group-Object { Split-Path -Path (Split-Path -Path $_.InstalledLocation -Parent) -Parent } |
                ForEach-Object { $_.Group | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1 }
        }
        Mock Find-Module { [pscustomobject]@{ Name = 'posh-git'; Version = '2.0.0' } }
        Mock Install-Module { $script:installed = @(New-InstalledModule -Version $RequiredVersion) + $script:installed }
        Mock Uninstall-Module { $script:installed = @($script:installed | Where-Object { $_.Version -ne "$RequiredVersion" }) }
        Mock Get-GuestModuleRemovalPending { }
        Mock Set-GuestModuleRemovalPending { }
    }

    It 'installs the newer version from the Gallery beside the old one, in the scope it was installed in, in its own PowerShell' {
        $outcome = Invoke-GuestGalleryModuleUpdate -Module $posh

        $outcome.Version | Should -Be '2.0.0'
        Should -Invoke Invoke-GuestPowerShellEdition -Times 1 -Exactly -ParameterFilter { $Path -eq $pwsh -and $ArgumentList[0] -eq 'posh-git' -and "$ScriptBlock" -match 'Tls12' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'posh-git' -and "$RequiredVersion" -eq '2.0.0' -and $Scope -eq 'AllUsers' -and $Repository -eq 'PSGallery' }
    }

    It 'installs for the current user a module installed for the current user' {
        $script:installed = @(New-InstalledModule -Version '1.1.0' -Location 'U:\Documents\PowerShell\Modules\posh-git')

        $null = Invoke-GuestGalleryModuleUpdate -Module $posh

        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Scope -eq 'CurrentUser' }
    }

    It 'compares with the newest copy of a module installed both for all users and for the current user' {
        $script:installed = @((New-InstalledModule -Version '1.1.0' -Location 'U:\Documents\PowerShell\Modules\posh-git'), (New-InstalledModule -Version '1.0.0'))
        Mock Find-Module { [pscustomobject]@{ Name = 'posh-git'; Version = '1.1.0' } }

        $outcome = Invoke-GuestGalleryModuleUpdate -Module $posh

        $outcome.Version | Should -Be '1.1.0'
        Should -Invoke Install-Module -Times 0
    }

    It 'removes the version made old, not the newest one''s second copy, when the newest is installed both for all users and for the current user (#309)' {
        $script:installed = @((New-InstalledModule -Version '1.1.0'), (New-InstalledModule -Version '1.1.0' -Location 'U:\Documents\PowerShell\Modules\posh-git'), (New-InstalledModule -Version '1.0.0'))

        $null = Invoke-GuestGalleryModuleUpdate -Module $posh

        Should -Invoke Uninstall-Module -Times 1 -Exactly
        Should -Invoke Uninstall-Module -Times 1 -Exactly -ParameterFilter { "$RequiredVersion" -eq '1.0.0' }
    }

    It 'installs nothing, and removes nothing, when the Gallery has no newer version' {
        Mock Find-Module { [pscustomobject]@{ Name = 'posh-git'; Version = '1.1.0' } }

        $outcome = Invoke-GuestGalleryModuleUpdate -Module $posh

        $outcome.Version | Should -Be '1.1.0'
        Should -Invoke Install-Module -Times 0
        Should -Invoke Uninstall-Module -Times 0
    }

    It 'removes only the version tonight''s update made old, and leaves other versions kept side by side alone' {
        $outcome = Invoke-GuestGalleryModuleUpdate -Module $posh

        Should -Invoke Uninstall-Module -Times 1 -Exactly
        Should -Invoke Uninstall-Module -Times 1 -Exactly -ParameterFilter { "$RequiredVersion" -eq '1.0.0' }
        @($outcome.Notes | Where-Object { $_.Level -eq 'INFO' -and $_.Text -eq 'removed: posh-git (PowerShell 7) 1.0.0 - made old by tonight''s update; the two newest versions are kept' }).Count | Should -Be 1
    }

    It 'records a version it could not remove, such as one in use, and says it is tried again tomorrow' {
        Mock Uninstall-Module { throw 'The module is currently in use.' }

        $outcome = Invoke-GuestGalleryModuleUpdate -Module $posh

        Should -Invoke Set-GuestModuleRemovalPending -Times 1 -Exactly -ParameterFilter { $Label -eq 'posh-git (PowerShell 7)' -and (@($Version) -join ',') -eq '1.0.0' }
        @($outcome.Notes | Where-Object { $_.Level -eq 'INFO' -and $_.Text -eq 'not removed yet: posh-git (PowerShell 7) 1.0.0 - The module is currently in use.; tried again tomorrow' }).Count | Should -Be 1
    }

    It 'tries again a removal recorded on an earlier night, even with no update tonight, and forgets it once done or once the version is gone' {
        Mock Find-Module { [pscustomobject]@{ Name = 'posh-git'; Version = '1.1.0' } }
        Mock Get-GuestModuleRemovalPending { '0.5.0'; '0.1.0' }

        $null = Invoke-GuestGalleryModuleUpdate -Module $posh

        Should -Invoke Uninstall-Module -Times 1 -Exactly -ParameterFilter { "$RequiredVersion" -eq '0.5.0' }
        Should -Invoke Set-GuestModuleRemovalPending -Times 1 -Exactly -ParameterFilter { $Label -eq 'posh-git (PowerShell 7)' -and @($Version).Count -eq 0 }
    }
}

Describe 'Get-GuestModuleRemovalPending and Set-GuestModuleRemovalPending (#293)' {
    BeforeAll {
        $label = 'posh-git (PowerShell 7)'
    }

    It 'reads the versions recorded for a module, by its label' {
        Mock Get-ItemProperty { [pscustomobject]@{ 'posh-git (PowerShell 7)' = '0.5.0;0.1.0' } }

        (@(Get-GuestModuleRemovalPending -Label $label) -join ',') | Should -Be '0.5.0,0.1.0'
    }

    It 'reads nothing when nothing is recorded' {
        Mock Get-ItemProperty { }

        @(Get-GuestModuleRemovalPending -Label $label).Count | Should -Be 0
    }

    It 'records the versions under the module''s label' {
        Mock Test-Path { $true }
        Mock New-ItemProperty { }

        Set-GuestModuleRemovalPending -Label $label -Version @('1.0.0', '0.5.0')

        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq $label -and $Value -eq '1.0.0;0.5.0' -and $Path -like 'HKCU:\SOFTWARE\LazyVM\*' }
    }

    It 'forgets the module when no version is left to remove' {
        Mock Remove-ItemProperty { }

        Set-GuestModuleRemovalPending -Label $label -Version @()

        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq $label }
    }
}

Describe 'Remove-GuestModuleRemovalStale (#309)' {
    BeforeEach {
        Mock Get-Item { [pscustomobject]@{ Property = @('posh-git (PowerShell 7)', 'gone (PowerShell 7)', 'gone (Windows PowerShell)') } }
        Mock Set-GuestModuleRemovalPending { }
    }

    It 'forgets the removals recorded for the edition''s modules that are no longer installed, and only those' {
        Remove-GuestModuleRemovalStale -Edition 'PowerShell 7' -Label @('posh-git (PowerShell 7)', 'Pester (PowerShell 7)')

        Should -Invoke Set-GuestModuleRemovalPending -Times 1 -Exactly
        Should -Invoke Set-GuestModuleRemovalPending -Times 1 -Exactly -ParameterFilter { $Label -eq 'gone (PowerShell 7)' }
    }

    It 'forgets every removal recorded for an edition with no Gallery modules left' {
        Remove-GuestModuleRemovalStale -Edition 'Windows PowerShell' -Label @()

        Should -Invoke Set-GuestModuleRemovalPending -Times 1 -Exactly -ParameterFilter { $Label -eq 'gone (Windows PowerShell)' }
    }

    It 'does nothing when no removal is recorded' {
        Mock Get-Item { }

        Remove-GuestModuleRemovalStale -Edition 'PowerShell 7' -Label @()

        Should -Invoke Set-GuestModuleRemovalPending -Times 0
    }
}

Describe 'Get-GuestProcessNameInFolder (#293)' {
    It 'names each process running from the folder or below it, once, and none from a folder that only starts the same' {
        Mock Get-CimInstance {
            [pscustomobject]@{ Name = 'devenv.exe'; ExecutablePath = 'C:\VS\Common7\IDE\devenv.exe' }
            [pscustomobject]@{ Name = 'devenv.exe'; ExecutablePath = 'C:\VS\Common7\IDE\devenv.exe' }
            [pscustomobject]@{ Name = 'MSBuild.exe'; ExecutablePath = 'c:\vs\MSBuild\Current\Bin\MSBuild.exe' }
            [pscustomobject]@{ Name = 'other.exe'; ExecutablePath = 'C:\VS2\other.exe' }
            [pscustomobject]@{ Name = 'System'; ExecutablePath = $null }
        }

        (@(Get-GuestProcessNameInFolder -Folder 'C:\VS') -join ',') | Should -Be 'devenv.exe,MSBuild.exe'
    }
}

Describe 'Update-GuestInstallerProduct (#293)' {
    BeforeAll {
        function New-Product {
            param([string]$ProductId = 'Microsoft.VisualStudio.Product.Community', [string]$Version = '18.0.1', [string]$InstanceId = 'a1b2c3d4', [string]$InstallPath = 'C:\VS', [bool]$IsComplete = $true)

            return [pscustomobject]@{
                InstanceId = $InstanceId; ProductId = $ProductId; ChannelId = 'VisualStudio.18.Release'; DisplayName = "Product $InstanceId"
                Version = $Version; InstallPath = $InstallPath; IsComplete = $IsComplete; IsLaunchable = $true
            }
        }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $script:listed = 0
        # The version before the update, then after it.
        Mock -ModuleName $module Get-GuestInstallerProduct { $script:listed++; if ($script:listed -eq 1) { New-Product } else { New-Product -Version '18.0.2' } }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Installer = 'C:\Installer\setup.exe'; Running = @() } } -ParameterFilter { $Activity -like 'checking whether*' }
        Mock -ModuleName $module Invoke-GuestInstaller { 0 }
        Mock -ModuleName $module Repair-ToolingProduct { $true }
    }

    It 'updates each product with the Visual Studio Installer''s update command, quietly, with no restart and never forced, and returns only that no restart is needed' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [bool]
        $result[0] | Should -BeFalse
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Installer\setup.exe' -and ($ArgumentList -join ' ') -eq 'update --installPath "C:\VS" --quiet --norestart' -and $TimeoutMinutes -eq 90
        }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -eq '  updated: Product a1b2c3d4 18.0.1 -> 18.0.2' }
    }

    It 'says a product whose version did not change is up to date' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -eq '  up to date: Product a1b2c3d4 18.0.1' }
    }

    It 'returns that a restart is needed when the update needs one to finish, and says so' {
        Mock -ModuleName $module Invoke-GuestInstaller { 3010 }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM })

        $result | Should -Be @($true)
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -eq '  updated: Product a1b2c3d4 18.0.1 -> 18.0.2 - a restart finishes it' }
    }

    It 'skips a product that is in use, naming what runs, and tries again the next night' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Installer = 'C:\Installer\setup.exe'; Running = @('devenv.exe') } } -ParameterFilter { $Activity -like 'checking whether*' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -eq '  skipped: Product a1b2c3d4 - in use (devenv.exe); tried again tomorrow' }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'checking whether*' -and $ArgumentList[0] -eq 'C:\VS' -and "$ScriptBlock" -match 'Get-GuestProcessNameInFolder' }
    }

    It 'reports a failed update with what its exit code means, and goes on to the next product' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -InstanceId 'one' -InstallPath 'C:\VS1'; New-Product -InstanceId 'two' -InstallPath 'C:\VS2' }
        Mock -ModuleName $module Invoke-GuestInstaller { 5007 } -ParameterFilter { $ArgumentList -contains '"C:\VS1"' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 2 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq '  update failed: Product one - exit 5007: the computer does not meet the requirements' }
    }

    It 'skips, and tries again the next night, when the installer says it is busy or in use (exit <ExitCode>)' -ForEach @(
        @{ ExitCode = 1001 }
        @{ ExitCode = 1003 }
        @{ ExitCode = 1618 }
        @{ ExitCode = 8006 }
    ) {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product }
        Mock -ModuleName $module Invoke-GuestInstaller { $ExitCode }.GetNewClosure()

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'INFO' -and $Message -like "  skipped: Product a1b2c3d4 - exit ${ExitCode}: *; tried again tomorrow" }
    }

    It 'goes on to the next product when the update of one throws' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -InstanceId 'one' -InstallPath 'C:\VS1'; New-Product -InstanceId 'two' -InstallPath 'C:\VS2' }
        Mock -ModuleName $module Invoke-GuestScript { throw 'the guest stopped answering' } -ParameterFilter { $Activity -like 'checking whether Product one*' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '"C:\VS2"' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq '  update failed: Product one - the guest stopped answering' }
    }

    It 'repairs an incomplete product instead of updating it' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -IsComplete $false }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0
        Should -Invoke -ModuleName $module Repair-ToolingProduct -Times 1 -Exactly -ParameterFilter { $InstallPath -eq 'C:\VS' -and $Product.ProductId -eq 'Microsoft.VisualStudio.Product.Community' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -like '  repaired: Product a1b2c3d4 - *updated from tomorrow' }
    }

    It 'repairs at once a product a failed update left incomplete, when the installer gave up quickly and time is left, and says what to do when the repair fails too' {
        Mock -ModuleName $module Get-GuestInstallerProduct { $script:listed++; if ($script:listed -eq 1) { New-Product } else { New-Product -IsComplete $false } }
        Mock -ModuleName $module Invoke-GuestInstaller { 1 }
        Mock -ModuleName $module Repair-ToolingProduct { $false }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Repair-ToolingProduct -Times 1 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like '  repair failed: Product a1b2c3d4 - *Visual Studio Installer*' }
    }

    It 'leaves a product an update that threw, such as one that ran out of time, left incomplete to the next night''s check, so tonight''s time is not spent twice' {
        Mock -ModuleName $module Get-GuestInstallerProduct { $script:listed++; if ($script:listed -eq 1) { New-Product } else { New-Product -IsComplete $false } }
        Mock -ModuleName $module Invoke-GuestInstaller { throw 'the update did not finish within 90 minutes' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Repair-ToolingProduct -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -eq '  update failed: Product a1b2c3d4 - the update did not finish within 90 minutes; left incomplete, repaired tomorrow'
        }
    }

    It 'repairs nothing tonight when the failed update <Case>' -ForEach @(
        @{ Case = 'took a long time'; InstallerMinutes = 30; DeadlineMinutes = 60 }
        @{ Case = 'left no time in the budget'; InstallerMinutes = 0; DeadlineMinutes = -1 }
    ) {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -IsComplete $false }
        $script:now = [datetime]'2026-11-02T03:00:00'
        Mock -ModuleName $module Get-Date { $script:now }
        Mock -ModuleName $module Invoke-GuestInstaller { $script:now = $script:now.AddMinutes($InstallerMinutes); 1 }.GetNewClosure()

        InModuleScope $module -Parameters @{ VM = $testVM; Product = (New-Product | Add-Member -NotePropertyName Label -NotePropertyValue 'Product a1b2c3d4' -PassThru); Deadline = $script:now.AddMinutes($DeadlineMinutes) } {
            param($VM, $Product, $Deadline)
            Update-InstallerProduct -VM $VM -Product $Product -Deadline $Deadline
        } | Out-Null

        Should -Invoke -ModuleName $module Repair-ToolingProduct -Times 0
    }

    It 'says the update failed when the product is gone from the installer''s list afterwards' {
        Mock -ModuleName $module Get-GuestInstallerProduct { $script:listed++; if ($script:listed -eq 1) { New-Product } }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq '  update failed: Product a1b2c3d4 - its version could not be read afterwards' }
    }

    It 'updates SSMS too, which the same installer manages, and skips it while Ssms.exe runs from its folder' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product -ProductId 'Microsoft.VisualStudio.Product.Ssms' -InstanceId 'ssms' -InstallPath 'C:\SSMS'; New-Product -InstanceId 'vs' }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Installer = 'C:\Installer\setup.exe'; Running = @('Ssms.exe') } } -ParameterFilter { $Activity -like 'checking whether Product ssms*' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $Activity -like 'checking whether Product ssms*' -and $ArgumentList[0] -eq 'C:\SSMS' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq '  skipped: Product ssms - in use (Ssms.exe); tried again tomorrow' }
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '"C:\VS"' }

        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Installer = 'C:\Installer\setup.exe'; Running = @() } } -ParameterFilter { $Activity -like 'checking whether*' }
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '"C:\SSMS"' }
    }

    It 'updates nothing, and needs no restart, when the guest has no Visual Studio Installer product' {
        Mock -ModuleName $module Get-GuestInstallerProduct { }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM })

        $result | Should -Be @($false)
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -eq 'Visual Studio Installer products: none in the guest - nothing to update' }
    }

    It 'reports an update that threw, such as one that ran out of time, as failed, once it has checked the product is complete' {
        Mock -ModuleName $module Get-GuestInstallerProduct { New-Product }
        Mock -ModuleName $module Invoke-GuestInstaller { throw 'the update did not finish within 90 minutes' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestInstallerProduct -Times 2 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -eq '  update failed: Product a1b2c3d4 - the update did not finish within 90 minutes' }
    }

    It 'gives the installer product updates their own budget' {
        Mock -ModuleName $module Invoke-ItemUpdate { }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestInstallerProduct -VM $VM }

        $budget = InModuleScope $module { $script:InstallerProductUpdateBudgetMinutes }
        Should -Invoke -ModuleName $module Invoke-ItemUpdate -Times 1 -Exactly -ParameterFilter { $BudgetMinutes -eq $budget -and @($Items)[0].Label -eq 'Product a1b2c3d4' }
    }
}
