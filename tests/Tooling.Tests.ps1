# Tooling.Tests.ps1
# The tooling list: its record classes, normalizing names, comparing lists,
# and carrying AwaitingReinstall items across a rebuild. Nothing here touches Hyper-V or a guest.
#
# Most of these functions are internal to the module, so each test runs its
# body with InModuleScope. Test data is built out here, as the dictionaries
# and objects a tooling list is read from, and passed in with -Parameters;
# inside, [ToolingRecord]::FromObject turns it into a record, because the
# module's classes are only visible inside the module.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function New-TestProduct {
        param(
            [string]$ProductId = 'Microsoft.VisualStudio.Product.Community',
            [string]$ChannelId = 'VisualStudio.18.Release',
            [string]$DisplayName = 'Visual Studio Community 2026',
            [string[]]$Components = @(),
            [string[]]$Extensions = @(),
            [object[]]$UserExtensions = @()
        )

        return [ordered]@{
            ProductId      = $ProductId
            ChannelId      = $ChannelId
            DisplayName    = $DisplayName
            Components     = @($Components)
            Extensions     = @($Extensions)
            UserExtensions = @($UserExtensions)
        }
    }

    function New-TestRecord {
        param(
            [object[]]$Products = @(),
            [string[]]$WingetIds = @(),
            [string[]]$ProgramNames = @(),
            $AwaitingReinstall
        )

        $record = [ordered]@{
            Version        = 1
            Products       = @($Products)
            WingetPackages = @($WingetIds | ForEach-Object { [ordered]@{ Id = $_; Source = 'winget' } })
            Programs       = @($ProgramNames | ForEach-Object { [ordered]@{ Name = $_; Publisher = 'Test Publisher' } })
        }
        if ($AwaitingReinstall) {
            $record['AwaitingReinstall'] = $AwaitingReinstall
        }
        return $record
    }

    function ConvertTo-RecordFromDisk {
        <# The same record as it reads back after being written as JSON. #>
        param([Parameter(Mandatory)]$Record)

        return ($Record | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }
}

Describe 'Get-NormalizedProgramName' {
    It "reduces '<Name>' to '<Expected>'" -ForEach @(
        @{ Name = 'LINQPad 9 version 9.10.20'; Expected = 'LINQPad 9' }
        @{ Name = 'JetBrains dotPeek 2026.3 EAP 5'; Expected = 'JetBrains dotPeek' }
        @{ Name = 'Notepad++ (8.7.1)'; Expected = 'Notepad++' }
        @{ Name = 'Node.js v22.11.0'; Expected = 'Node.js' }
        @{ Name = '7-Zip 24.08 (x64)'; Expected = '7-Zip (x64)' }
        @{ Name = 'Some Tool Preview 3'; Expected = 'Some Tool' }
        @{ Name = 'Some Tool RC2'; Expected = 'Some Tool' }
        @{ Name = 'WinMerge'; Expected = 'WinMerge' }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } {
            param($Name)
            Get-NormalizedProgramName -Name $Name
        } | Should -BeExactly $Expected
    }
}

Describe 'Get-SetChange' {
    It 'lists additions then removals, each sorted, with the label' {
        $changes = InModuleScope $module {
            @(Get-SetChange -Label 'winget' -Old @('B', 'A', 'C') -New @('C', 'E', 'D'))
        }

        $changes | Should -Be @('+ winget: D', '+ winget: E', '- winget: A', '- winget: B')
    }

    It 'ignores case, so a re-cased name is not a change' {
        $changes = InModuleScope $module {
            @(Get-SetChange -Label 'program' -Old @('LINQPad 9') -New @('linqpad 9'))
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'ignores empty items and duplicates' {
        $changes = InModuleScope $module {
            @(Get-SetChange -Label 'winget' -Old @('A', '', $null) -New @('A', 'A'))
        }

        $changes | Should -BeNullOrEmpty
    }
}

Describe 'RecordReader' {
    It 'reads a field from <Case>' -ForEach @(
        @{ Case = 'a list built in memory'; Item = [ordered]@{ Name = 'Git' } }
        @{ Case = 'a list read back from disk'; Item = [pscustomobject]@{ Name = 'Git' } }
    ) {
        InModuleScope $module -Parameters @{ Item = $Item } {
            param($Item)
            [RecordReader]::Field($Item, 'Name')
            [RecordReader]::Field($Item, 'Publisher') | Should -BeNullOrEmpty
            [RecordReader]::Text($Item, 'Publisher') | Should -BeExactly ''
            [RecordReader]::Field($null, 'Name') | Should -BeNullOrEmpty
        } | Should -Be 'Git'
    }

    It 'reads a list of text, leaving out empty entries' {
        InModuleScope $module {
            [RecordReader]::Strings([pscustomobject]@{ Items = @('a', '', $null, 'b') }, 'Items')
        } | Should -Be @('a', 'b')
    }
}

Describe 'ToolingProduct' {
    It 'identifies extensions by Marketplace link where known, and by name and id otherwise' {
        $product = New-TestProduct -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.exported') -UserExtensions @(
            [ordered]@{ Id = 'linked-id'; DisplayName = 'Linked'; MarketplaceItem = 'pub.linked' }
            [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; MarketplaceItem = '' }
        )

        $identities = InModuleScope $module -Parameters @{ Product = $product } {
            param($Product)
            [ToolingProduct]::FromObject($Product).ExtensionIdentities()
        }

        $identities | Should -Be @(
            'https://marketplace.visualstudio.com/items?itemName=pub.exported'
            'https://marketplace.visualstudio.com/items?itemName=pub.linked'
            'Local Only [local-id]'
        )
    }

    It 'keys a product by its id and channel' {
        $product = New-TestProduct

        InModuleScope $module -Parameters @{ Product = $product } {
            param($Product)
            [ToolingProduct]::FromObject($Product).Key()
        } | Should -Be 'Microsoft.VisualStudio.Product.Community|VisualStudio.18.Release'
    }
}

Describe 'ToolingRecord' {
    It 'reads back what it writes, unchanged' {
        $product = New-TestProduct -Components @('A', 'B') -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.ext') -UserExtensions @(
            [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P'; MoreInfo = ''; MarketplaceItem = '' }
            [ordered]@{ Id = 'new-id'; DisplayName = 'Not looked up'; Publisher = 'P'; MoreInfo = '' }
        )
        $record = New-TestRecord -Products @($product) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9') -AwaitingReinstall ([ordered]@{
                Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                Extensions = @()
            })

        InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            $json = [ToolingRecord]::FromObject($Record).ToJson()
            $again = [ToolingRecord]::FromJson($json)

            $again.ToJson() | Should -Be $json
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Record)) -New $again) | Should -BeNullOrEmpty
            # Not looked up ($null) is kept apart from no Marketplace match ('').
            $again.Products[0].FindUserExtension('local-id').MarketplaceItem | Should -BeExactly ''
            $again.Products[0].FindUserExtension('new-id').MarketplaceItem | Should -BeNullOrEmpty
            $null -eq $again.Products[0].FindUserExtension('new-id').MarketplaceItem | Should -BeTrue
        }
    }

    It 'refuses a list written by a newer LazyVM' {
        {
            InModuleScope $module { [ToolingRecord]::FromJson('{ "Version": 99 }') }
        } | Should -Throw -ExpectedMessage '*version 99, newer than this LazyVM understands*'
    }

    It 'has nothing awaiting reinstall when the list never had any' {
        InModuleScope $module { [ToolingRecord]::FromJson('{ "Version": 1 }').Awaiting().Count() } | Should -Be 0
    }
}

Describe 'Test-ToolingExcluded' {
    It "returns <Expected> for '<PackageId>'" -ForEach @(
        @{ PackageId = 'Microsoft.VisualStudio.2026.Community'; Expected = $true }
        @{ PackageId = 'Microsoft.Edge'; Expected = $true }
        @{ PackageId = 'Microsoft.EdgeWebView2Runtime'; Expected = $false }
        @{ PackageId = 'Git.Git'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ PackageId = $PackageId } {
            param($PackageId)
            Test-ToolingExcluded -PackageId $PackageId -Patterns @('Microsoft.VisualStudio.*', 'Microsoft.Edge')
        } | Should -Be $Expected
    }
}

Describe 'ConvertTo-ToolingRecord' {
    BeforeAll {
        # Shaped like Get-GuestToolingInventory's result, which arrives from
        # the guest as objects rather than dictionaries.
        $inventory = [pscustomobject]@{
            Products       = @(
                [pscustomobject]@{
                    ProductId          = 'Microsoft.VisualStudio.Product.Community'
                    ChannelId          = 'VisualStudio.18.Release'
                    DisplayName        = 'Visual Studio Community 2026'
                    Version            = '18.0.1'
                    Components         = @('Microsoft.Component.MSBuild', 'Component.OpenJDK', 'Microsoft.Component.MSBuild')
                    ExportedExtensions = @('https://marketplace.visualstudio.com/items?itemName=pub.ext')
                    UserExtensions     = @(
                        [pscustomobject]@{ Id = 'z-ext'; DisplayName = 'Zed'; Publisher = 'P'; MoreInfo = ''; Version = '2.0' }
                        [pscustomobject]@{ Id = 'a-ext'; DisplayName = 'Aye'; Publisher = 'P'; MoreInfo = ''; Version = '1.0' }
                    )
                }
            )
            WingetPackages = @(
                [pscustomobject]@{ Id = 'Microsoft.VisualStudio.2026.Community'; Source = 'winget'; Version = '18.0' }
                [pscustomobject]@{ Id = 'LINQPad.LINQPad.9'; Source = 'winget'; Version = '9.10' }
                [pscustomobject]@{ Id = 'Git.Git'; Source = 'winget'; Version = '2.47' }
            )
            Programs       = @(
                [pscustomobject]@{ Name = 'LINQPad 9 version 9.10.20'; Publisher = 'Joseph Albahari' }
                [pscustomobject]@{ Name = 'LINQPad 9 version 9.10.21'; Publisher = 'Joseph Albahari' }
                [pscustomobject]@{ Name = 'Git version 2.47.1'; Publisher = 'The Git Development Community' }
            )
        }

        $record = InModuleScope $module -Parameters @{ Inventory = $inventory } {
            param($Inventory)
            ConvertTo-ToolingRecord -Inventory $Inventory -WingetExclude @('Microsoft.VisualStudio.*')
        }
    }

    It 'leaves out excluded winget packages and sorts the rest by id' {
        @($record.WingetPackages | ForEach-Object { $_.Id }) | Should -Be @('Git.Git', 'LINQPad.LINQPad.9')
    }

    It 'strips versions from program names and keeps one entry per name' {
        @($record.Programs | ForEach-Object { $_.Name }) | Should -Be @('Git', 'LINQPad 9')
    }

    It 'sorts components and removes duplicates' {
        $record.Products[0].Components | Should -Be @('Component.OpenJDK', 'Microsoft.Component.MSBuild')
    }

    It 'keeps the exported extensions' {
        $record.Products[0].Extensions | Should -Be @('https://marketplace.visualstudio.com/items?itemName=pub.ext')
    }

    It 'sorts user extensions by id and records no versions' {
        $userExtensions = @($record.Products[0].UserExtensions)

        @($userExtensions | ForEach-Object { $_.Id }) | Should -Be @('a-ext', 'z-ext')
        $userExtensions[0].ToDictionary().Keys | Should -Not -Contain 'Version'
    }

    It 'gives an empty product list, which saves and reads back, for a guest with no Visual Studio or SSMS (#82)' {
        $noProducts = [pscustomobject]@{
            Products       = @()
            WingetPackages = @([pscustomobject]@{ Id = 'Git.Git'; Source = 'winget' })
            Programs       = @([pscustomobject]@{ Name = 'Git'; Publisher = 'The Git Development Community' })
        }

        $result = InModuleScope $module -Parameters @{ Inventory = $noProducts } {
            param($Inventory)
            $converted = ConvertTo-ToolingRecord -Inventory $Inventory
            $readBack = [ToolingRecord]::FromObject((ConvertTo-ToolingSetting -Record $converted))
            [pscustomobject]@{
                ProductsIsNull = $null -eq $converted.Products
                ProductCount   = @($converted.Products).Count
                Changes        = @(Compare-ToolingRecord -Old $converted -New $readBack)
                WingetIds      = @($readBack.WingetPackages | ForEach-Object { $_.Id })
            }
        }

        $result.ProductsIsNull | Should -BeFalse
        $result.ProductCount | Should -Be 0
        $result.Changes | Should -BeNullOrEmpty
        $result.WingetIds | Should -Be @('Git.Git')
    }
}

Describe 'Compare-ToolingRecord' {
    It 'finds no changes between identical lists' {
        $old = New-TestRecord -Products @(New-TestProduct -Components @('A')) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9')
        $new = New-TestRecord -Products @(New-TestProduct -Components @('A')) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'finds no changes between a list in memory and the same list read back from disk' {
        $product = New-TestProduct -Components @('A', 'B') -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.ext') -UserExtensions @(
            [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P'; MoreInfo = ''; MarketplaceItem = '' }
        )
        $inMemory = New-TestRecord -Products @($product) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9') -AwaitingReinstall ([ordered]@{
                Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                Extensions = @()
            })
        $fromDisk = ConvertTo-RecordFromDisk -Record $inMemory

        $changes = InModuleScope $module -Parameters @{ Old = $fromDisk; New = $inMemory } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'reports a product added and a product removed' {
        $old = New-TestRecord -Products @(New-TestProduct -ProductId 'Old.Product' -ChannelId 'C1' -DisplayName 'Old Product')
        $new = New-TestRecord -Products @(New-TestProduct -ProductId 'New.Product' -ChannelId 'C1' -DisplayName 'New Product')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -Be @('+ product: New Product [New.Product, C1]', '- product: Old Product [Old.Product, C1]')
    }

    It 'treats the same product on another channel as a different product' {
        $old = New-TestRecord -Products @(New-TestProduct -ChannelId 'VisualStudio.18.Release' -DisplayName 'VS')
        $new = New-TestRecord -Products @(New-TestProduct -ChannelId 'VisualStudio.18.Preview' -DisplayName 'VS')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes.Count | Should -Be 2
    }

    It 'reports components added and removed within a product' {
        $old = New-TestRecord -Products @(New-TestProduct -DisplayName 'VS' -Components @('Keep', 'Gone'))
        $new = New-TestRecord -Products @(New-TestProduct -DisplayName 'VS' -Components @('Keep', 'Added'))

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -Be @('+ VS component: Added', '- VS component: Gone')
    }

    It 'matches a per-user extension with the same extension reinstalled for all users' {
        $old = New-TestRecord -Products @(New-TestProduct -UserExtensions @(
                [ordered]@{ Id = 'ext-id'; DisplayName = 'Ext'; MarketplaceItem = 'pub.ext' }
            ))
        $new = New-TestRecord -Products @(New-TestProduct -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.ext'))

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'reports winget packages and programs added and removed' {
        $old = New-TestRecord -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9')
        $new = New-TestRecord -WingetIds @('Microsoft.PowerShell') -ProgramNames @('JetBrains dotPeek')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -Be @(
            '+ winget: Microsoft.PowerShell'
            '- winget: Git.Git'
            '+ program: JetBrains dotPeek'
            '- program: LINQPad 9'
        )
    }

    It 'reports an item leaving the awaiting-reinstall list' {
        $old = New-TestRecord -AwaitingReinstall ([ordered]@{ Programs = @([ordered]@{ Name = 'Old Tool' }); Extensions = @() })
        $new = New-TestRecord -AwaitingReinstall ([ordered]@{ Programs = @(); Extensions = @() })

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -Be @('- awaiting reinstall: program Old Tool')
    }
}

Describe 'Merge-AwaitingReinstall' {
    BeforeAll {
        Mock Write-LogEntry -ModuleName $module
    }

    It 'keeps a program that is still missing, both in the list and as awaiting' {
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                    Extensions = @()
                }))
        $record = New-TestRecord -ProgramNames @('LINQPad 9')

        $record = InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            $merged = [ToolingRecord]::FromObject($Record)
            Merge-AwaitingReinstall -Record $merged -Previous ([ToolingRecord]::FromObject($Previous))
            $merged
        }

        @($record.Programs | ForEach-Object { $_.Name }) | Should -Be @('LINQPad 9', 'Old Tool')
        @($record.AwaitingReinstall.Programs | ForEach-Object { $_.Name }) | Should -Be @('Old Tool')
        Should -Invoke Write-LogEntry -ModuleName $module -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'drops a program from the awaiting list once it is installed again' {
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                    Extensions = @()
                }))
        $record = New-TestRecord -ProgramNames @('Old Tool')

        $record = InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            $merged = [ToolingRecord]::FromObject($Record)
            Merge-AwaitingReinstall -Record $merged -Previous ([ToolingRecord]::FromObject($Previous))
            $merged
        }

        @($record.Programs | ForEach-Object { $_.Name }) | Should -Be @('Old Tool')
        $record.AwaitingReinstall.Programs | Should -BeNullOrEmpty
    }

    It 'puts a still-missing extension back under its product and keeps it awaiting' {
        $productKey = 'Microsoft.VisualStudio.Product.Community|VisualStudio.18.Release'
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @()
                    Extensions = @([ordered]@{ ProductKey = $productKey; Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P' })
                }))
        $record = New-TestRecord -Products @(New-TestProduct)

        $record = InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            $merged = [ToolingRecord]::FromObject($Record)
            Merge-AwaitingReinstall -Record $merged -Previous ([ToolingRecord]::FromObject($Previous))
            $merged
        }

        @($record.Products[0].UserExtensions | ForEach-Object { $_.Id }) | Should -Be @('local-id')
        @($record.AwaitingReinstall.Extensions | ForEach-Object { $_.Id }) | Should -Be @('local-id')
    }

    It 'drops an extension from the awaiting list once it is installed again' {
        $productKey = 'Microsoft.VisualStudio.Product.Community|VisualStudio.18.Release'
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @()
                    Extensions = @([ordered]@{ ProductKey = $productKey; Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P' })
                }))
        $record = New-TestRecord -Products @(New-TestProduct -UserExtensions @(
                [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P'; MoreInfo = '' }
            ))

        $record = InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            $merged = [ToolingRecord]::FromObject($Record)
            Merge-AwaitingReinstall -Record $merged -Previous ([ToolingRecord]::FromObject($Previous))
            $merged
        }

        @($record.Products[0].UserExtensions).Count | Should -Be 1
        $record.AwaitingReinstall.Extensions | Should -BeNullOrEmpty
    }

    It 'records an empty awaiting list when there is no previous list' {
        $record = New-TestRecord -ProgramNames @('LINQPad 9')

        $record = InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            $merged = [ToolingRecord]::FromObject($Record)
            Merge-AwaitingReinstall -Record $merged -Previous $null
            $merged
        }

        $record.AwaitingReinstall.Programs | Should -BeNullOrEmpty
        $record.AwaitingReinstall.Extensions | Should -BeNullOrEmpty
        Should -Invoke Write-LogEntry -ModuleName $module -Times 0 -Exactly -Scope It
    }
}

Describe 'The tooling list in VM.json (#130)' {
    BeforeAll {
        function New-TestVM {
            <# A LazyVM folder with one VM, Alpha, whose VM.json holds $Settings. Returns the root. #>
            param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

            $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
            $configDir = Join-Path -Path $root -ChildPath 'Alpha/Config'
            New-Item -ItemType Directory -Path $configDir, (Join-Path -Path $root -ChildPath 'Shared/Config') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.json') -Value (ConvertTo-Json -InputObject $Settings -Depth 10)
            return $root
        }

        function Read-TestProfile {
            param([Parameter(Mandatory)][string]$Path)
            return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        }
    }

    BeforeEach {
        $buildList = New-TestRecord -Products @(New-TestProduct) -WingetIds @('Git.Git') -ProgramNames @('Git')
    }

    Context 'when maintenance records a change' {
        BeforeEach {
            Mock -ModuleName $module Get-GuestToolingInventory {
                # The product New-TestProduct describes, as the guest reports it.
                [pscustomobject]@{
                    Products       = @([pscustomobject]@{
                            ProductId          = 'Microsoft.VisualStudio.Product.Community'
                            ChannelId          = 'VisualStudio.18.Release'
                            DisplayName        = 'Visual Studio Community 2026'
                            Components         = @()
                            ExportedExtensions = @()
                            UserExtensions     = @()
                        })
                    WingetPackages = @([pscustomobject]@{ Id = 'Git.Git'; Source = 'winget' }, [pscustomobject]@{ Id = 'Notepad++.Notepad++'; Source = 'winget' })
                    Programs       = @([pscustomobject]@{ Name = 'Git'; Publisher = 'Test Publisher' })
                }
            }
            Mock -ModuleName $module Add-MarketplaceItem {}
            Mock -ModuleName $module Get-ToolingStamp { '20261024-120000' }
            Mock -ModuleName $module New-ToolingCheckpoint {}
            Mock -ModuleName $module Get-ToolingCheckpointStamp { , @('20261024-120000') }

            # As a build leaves the VM: VM.json and its template, the same.
            $root = New-TestVM -Settings @{ vCPU = 4; Tooling = $buildList }
            $configDir = Join-Path -Path $root -ChildPath 'Alpha/Config'
            Copy-Item -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.json') -Destination (Join-Path -Path $configDir -ChildPath 'VM.Template.json')

            $changes = InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                Update-ToolingRecord -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)) 6>$null
            }
        }

        It 'records it in VM.json''s Tooling section, keeping the other settings' {
            @($changes) | Should -Contain '+ winget: Notepad++.Notepad++'
            $vmProfile = Read-TestProfile -Path (Join-Path -Path $configDir -ChildPath 'VM.json')
            @($vmProfile.Tooling.WingetPackages | ForEach-Object { $_.Id }) | Should -Contain 'Notepad++.Notepad++'
            $vmProfile.vCPU | Should -Be 4
        }

        It 'keeps the version it recorded in History under its checkpoint''s date and time' {
            $version = Read-TestProfile -Path (Join-Path -Path $configDir -ChildPath 'History/VM-20261024-120000.json')
            @($version.Tooling.WingetPackages | ForEach-Object { $_.Id }) | Should -Contain 'Notepad++.Notepad++'
        }

        It 'leaves VM.Template.json as it was, and keeps no separate tooling files' {
            Get-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.Template.json') -Raw | Should -Not -Match 'Notepad\+\+'
            Join-Path -Path $configDir -ChildPath 'Tooling.json' | Should -Not -Exist
            Join-Path -Path $configDir -ChildPath 'History/Daily' | Should -Not -Exist
        }
    }

    It 'refuses to read the list of a VM whose Tooling.json has not been folded into VM.json yet' {
        $root = New-TestVM -Settings @{ vCPU = 4 }
        Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/Tooling.json') -Value (ConvertTo-Json -InputObject $buildList -Depth 10)

        {
            InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                Read-VMTooling -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings))
            }
        } | Should -Throw -ExpectedMessage '*Tooling.json*'
    }

    Context 'when a revert restores an earlier list' {
        BeforeEach {
            $newerList = New-TestRecord -Products @(New-TestProduct) -WingetIds @('Git.Git', 'Notepad++.Notepad++') -ProgramNames @('Git')
            $root = New-TestVM -Settings @{ vCPU = 8; Tooling = $newerList }
            $historyDir = Join-Path -Path $root -ChildPath 'Alpha/Config/History'
            New-Item -ItemType Directory -Path $historyDir | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $historyDir -ChildPath 'VM-20261008-193000.json') -Value (ConvertTo-Json -InputObject @{ vCPU = 4; Tooling = $buildList } -Depth 10)
            Set-Content -LiteralPath (Join-Path -Path $historyDir -ChildPath 'VM-20261009-080000.json') -Value '{ "vCPU": 6 }'
        }

        It 'puts back only the Tooling section of that version, keeping settings changed since' {
            InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                Mock Write-LogEntry {}
                Mock Get-ToolingCheckpointStamp { , @('20261008-193000') }
                Restore-ProfileTooling -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)) -Stamp '20261008-193000'
            }

            $vmProfile = Read-TestProfile -Path (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json')
            @($vmProfile.Tooling.WingetPackages | ForEach-Object { $_.Id }) | Should -Be @('Git.Git')
            $vmProfile.vCPU | Should -Be 8
        }

        It 'refuses a version that has no tooling list' {
            {
                InModuleScope $module -Parameters @{ Root = $root } {
                    param($Root)
                    Get-ProfileTooling -VM ([VMContext]::new((Read-VMSetting -Root $Root -VMName 'Alpha').Settings)) -Stamp '20261009-080000'
                }
            } | Should -Throw -ExpectedMessage '*20261009-080000*'
        }
    }
}
