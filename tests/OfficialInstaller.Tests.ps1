# OfficialInstaller.Tests.ps1
# Reinstalling what winget and the Marketplace do not cover (#24): finding a
# winget package for a program installed some other way, and installing the
# rest from an official installer the tooling list names. An installer runs
# only when it came over HTTPS, is signed by the publisher the list names
# and, when the list pins one, has the pinned hash. The guest is mocked;
# nothing here touches a VM or downloads anything.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    function New-TestInstaller {
        param(
            [string]$Name = 'JetBrains ReSharper',
            [string]$Url = 'https://download.jetbrains.com/resharper/JetBrains.dotUltimate.exe',
            [string[]]$Arguments = @('/SpecificProductNames=ReSharper', '/Silent=True'),
            [string]$Publisher = 'JetBrains s.r.o.',
            [string]$Sha256
        )

        $installer = [ordered]@{ Name = $Name; Url = $Url; Arguments = @($Arguments); Publisher = $Publisher }
        if ($Sha256) { $installer['Sha256'] = $Sha256 }
        return $installer
    }

    function New-TestRecord {
        param(
            [object[]]$Programs = @(),
            [string[]]$WingetIds = @(),
            [object[]]$Installers = @(),
            [object[]]$Products = @()
        )

        return [ordered]@{
            Version        = 1
            Products       = @($Products)
            WingetPackages = @($WingetIds | ForEach-Object { [ordered]@{ Id = $_; Source = 'winget' } })
            Programs       = @($Programs)
            Installers     = @($Installers)
        }
    }
}

Describe 'The tooling list''s record of winget matches and installers' {
    It 'keeps a program''s winget match, and no match, through a write and a read' {
        $record = New-TestRecord -Programs @(
            [ordered]@{ Name = 'LINQPad 9'; Publisher = 'Joseph Albahari'; WingetId = 'LINQPad.LINQPad.9' }
            [ordered]@{ Name = 'Odd Tool'; Publisher = 'Someone'; WingetId = '' }
            [ordered]@{ Name = 'New Tool'; Publisher = 'Someone' }
        )

        $read = InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            [ToolingRecord]::FromJson(([ToolingRecord]::FromObject($Record)).ToJson()).Programs
        }

        $read[0].WingetId | Should -Be 'LINQPad.LINQPad.9'
        $read[1].WingetId | Should -BeExactly ''
        $read[2].WingetId | Should -BeNullOrEmpty
        $null -eq $read[2].WingetId | Should -BeTrue
    }

    It 'keeps the installers through a write and a read' {
        $record = New-TestRecord -Installers @(New-TestInstaller -Sha256 ('a' * 64))

        $installer = InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            [ToolingRecord]::FromJson(([ToolingRecord]::FromObject($Record)).ToJson()).Installers[0]
        }

        $installer.Name | Should -Be 'JetBrains ReSharper'
        $installer.Url | Should -Be 'https://download.jetbrains.com/resharper/JetBrains.dotUltimate.exe'
        @($installer.Arguments) | Should -Be @('/SpecificProductNames=ReSharper', '/Silent=True')
        $installer.Publisher | Should -Be 'JetBrains s.r.o.'
        $installer.Sha256 | Should -Be ('a' * 64)
    }

    It 'writes no Installers or WingetId to a list that has none, so older lists stay the same' {
        $record = [ordered]@{ Version = 1; Products = @(); WingetPackages = @(); Programs = @([ordered]@{ Name = 'Git'; Publisher = 'P' }) }

        $json = InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            ([ToolingRecord]::FromObject($Record)).ToJson()
        }

        $json | Should -Not -Match 'Installers'
        $json | Should -Not -Match 'WingetId'
    }

    It 'installs the winget packages and the programs'' winget matches, each once' {
        $record = New-TestRecord -WingetIds @('Git.Git') -Programs @(
            [ordered]@{ Name = 'LINQPad 9'; Publisher = 'P'; WingetId = 'LINQPad.LINQPad.9' }
            [ordered]@{ Name = 'Git'; Publisher = 'P'; WingetId = 'git.git' }
            [ordered]@{ Name = 'Odd Tool'; Publisher = 'P'; WingetId = '' }
            [ordered]@{ Name = 'New Tool'; Publisher = 'P' }
        )

        $ids = InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            @(([ToolingRecord]::FromObject($Record)).WingetInstalls() | ForEach-Object { $_.Id })
        }

        $ids | Should -Be @('Git.Git', 'LINQPad.LINQPad.9')
    }

    It 'finds an installer by the program name or extension id it is for, ignoring case' {
        $record = New-TestRecord -Installers @(New-TestInstaller -Name 'JetBrains ReSharper')

        $found = InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            $tooling = [ToolingRecord]::FromObject($Record)
            @($tooling.FindInstaller('jetbrains resharper'), $tooling.FindInstaller('Something Else'))
        }

        $found[0].Name | Should -Be 'JetBrains ReSharper'
        $found[1] | Should -BeNullOrEmpty
    }

    It 'accepts winget matches and installers in VM.json''s Tooling setting' {
        $problems = InModuleScope $module -Parameters @{ Record = (New-TestRecord -Installers @(New-TestInstaller -Sha256 ('A' * 64)) -Programs @([ordered]@{ Name = 'LINQPad 9'; Publisher = 'P'; WingetId = 'LINQPad.LINQPad.9' })) } {
            param($Record)
            @(Get-SchemaProblem -Values @{ Tooling = $Record })
        }

        $problems | Should -BeNullOrEmpty
    }

    It 'rejects an installer in VM.json whose download is not HTTPS' {
        $problems = InModuleScope $module -Parameters @{ Record = (New-TestRecord -Installers @(New-TestInstaller -Url 'http://example.com/setup.exe')) } {
            param($Record)
            @(Get-SchemaProblem -Values @{ Tooling = $Record })
        }

        $problems | Should -Not -BeNullOrEmpty
    }
}

Describe 'Compare-ToolingRecord with winget matches' {
    It 'reports a winget match found, and a lookup that found none, so both are recorded' {
        $old = New-TestRecord -Programs @([ordered]@{ Name = 'LINQPad 9'; Publisher = 'P' }, [ordered]@{ Name = 'Odd Tool'; Publisher = 'P' })
        $new = New-TestRecord -Programs @(
            [ordered]@{ Name = 'LINQPad 9'; Publisher = 'P'; WingetId = 'LINQPad.LINQPad.9' }
            [ordered]@{ Name = 'Odd Tool'; Publisher = 'P'; WingetId = '' }
        )

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -Be @('+ winget match: LINQPad 9 = LINQPad.LINQPad.9', '+ winget match: Odd Tool = none')
    }

    It 'finds no change when the matches are the same' {
        $record = New-TestRecord -Programs @([ordered]@{ Name = 'LINQPad 9'; Publisher = 'P'; WingetId = 'LINQPad.LINQPad.9' })

        $changes = InModuleScope $module -Parameters @{ Old = $record; New = $record } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old ([ToolingRecord]::FromObject($Old)) -New ([ToolingRecord]::FromObject($New)))
        }

        $changes | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-GuestWingetTable' {
    It 'reads the name and id of each row, from the column positions in the header' {
        $lines = @(
            '   - '
            'Name       Id                  Version  Source'
            '-----------------------------------------------'
            'LINQPad 9  LINQPad.LINQPad.9   9.1.10   winget'
            'LINQPad 8  LINQPad.LINQPad.8   8.7.5    winget'
        )

        $rows = @(ConvertFrom-GuestWingetTable -Lines $lines)

        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'LINQPad 9'
        $rows[0].Id | Should -Be 'LINQPad.LINQPad.9'
        $rows[1].Id | Should -Be 'LINQPad.LINQPad.8'
    }

    It 'returns nothing when there is no table' {
        @(ConvertFrom-GuestWingetTable -Lines @('No package found matching input criteria.')) | Should -BeNullOrEmpty
    }
}

Describe 'Get-GuestWingetPublisher' {
    It 'reads the publisher from winget show''s output' {
        $lines = @('Found LINQPad 9 [LINQPad.LINQPad.9]', 'Version: 9.1.10', 'Publisher: Joseph Albahari', 'Publisher Url: https://www.linqpad.net')

        Get-GuestWingetPublisher -Lines $lines | Should -Be 'Joseph Albahari'
    }

    It 'returns nothing when the output names no publisher' {
        Get-GuestWingetPublisher -Lines @('Found Something [Some.Thing]') | Should -BeExactly ''
    }
}

Describe 'Select-GuestWingetMatch' {
    BeforeAll {
        $table = @(
            'Name       Id                  Version  Source'
            '-----------------------------------------------'
            'LINQPad 9  LINQPad.LINQPad.9   9.1.10   winget'
        )
    }

    It 'returns the id of the one row whose name matches exactly' {
        Select-GuestWingetMatch -Lines $table -Name 'linqpad 9' | Should -Be 'LINQPad.LINQPad.9'
    }

    It 'returns no match when two rows have the name' {
        $two = $table + 'LINQPad 9  Other.LINQPad.9     1.0      winget'

        Select-GuestWingetMatch -Lines $two -Name 'LINQPad 9' | Should -BeExactly ''
    }

    It 'returns no match when the only row has another name' {
        Select-GuestWingetMatch -Lines $table -Name 'LINQPad' | Should -BeExactly ''
    }

    It 'returns no match for an id that is not a winget identifier' {
        $odd = @(
            'Name       Id                  Version  Source'
            '-----------------------------------------------'
            'LINQPad 9  ARP\Machine\X64\x   9.1.10   winget'
        )

        Select-GuestWingetMatch -Lines $odd -Name 'LINQPad 9' | Should -BeExactly ''
    }
}

Describe 'Get-GuestInstallerKind' {
    It 'is <expected> for a file that starts with <name>' -ForEach @(
        @{ Name = 'MZ'; Bytes = [byte[]](0x4D, 0x5A, 0x90, 0x00); Expected = 'exe' }
        @{ Name = 'the OLE header'; Bytes = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1); Expected = 'msi' }
        @{ Name = 'anything else'; Bytes = [byte[]](0x50, 0x4B, 0x03, 0x04); Expected = '' }
        @{ Name = 'nothing'; Bytes = [byte[]]@(); Expected = '' }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllBytes($path, $Bytes)

        Get-GuestInstallerKind -Path $path | Should -BeExactly $Expected
    }
}

Describe 'Get-GuestInstallerProblem' {
    BeforeAll {
        function New-TestSignature {
            param([string]$Status = 'Valid', [string]$Signer = 'JetBrains s.r.o.')

            # A certificate whose GetNameInfo gives the signer's name.
            $certificate = [pscustomobject]@{ SignerName = $Signer } | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value { $this.SignerName } -PassThru
            return [pscustomobject]@{ Status = $Status; SignerCertificate = $certificate }
        }
    }

    BeforeEach {
        $path = Join-Path -Path $TestDrive -ChildPath 'installer.exe'
        Set-Content -LiteralPath $path -Value 'installer' -NoNewline
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    It 'finds no problem with a validly signed file from the named publisher' {
        Mock Get-AuthenticodeSignature { New-TestSignature }

        Get-GuestInstallerProblem -Path $path -Publisher 'JetBrains s.r.o.' | Should -BeExactly ''
    }

    It 'finds no problem when the pinned hash matches too' {
        Mock Get-AuthenticodeSignature { New-TestSignature }

        Get-GuestInstallerProblem -Path $path -Publisher 'JetBrains s.r.o.' -Sha256 $hash.ToLowerInvariant() | Should -BeExactly ''
    }

    It 'refuses a file whose hash is not the pinned one' {
        Mock Get-AuthenticodeSignature { New-TestSignature }

        Get-GuestInstallerProblem -Path $path -Publisher 'JetBrains s.r.o.' -Sha256 ('0' * 64) | Should -Match 'hash'
    }

    It 'refuses a file whose signature is <status>' -ForEach @(
        @{ Status = 'NotSigned' }, @{ Status = 'HashMismatch' }, @{ Status = 'NotTrusted' }, @{ Status = 'UnknownError' }
    ) {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status $Status }

        Get-GuestInstallerProblem -Path $path -Publisher 'JetBrains s.r.o.' | Should -Match 'signature'
    }

    It 'refuses a file signed by someone else' {
        Mock Get-AuthenticodeSignature { New-TestSignature -Signer 'Someone Else Ltd' }

        Get-GuestInstallerProblem -Path $path -Publisher 'JetBrains s.r.o.' | Should -Match 'Someone Else Ltd'
    }

    It 'refuses the file when the signature cannot be read' {
        Mock Get-AuthenticodeSignature { throw 'cannot read' }

        Get-GuestInstallerProblem -Path $path -Publisher 'JetBrains s.r.o.' | Should -Match 'signature'
    }
}

Describe 'Get-OfficialInstallerProblem' {
    It 'finds no problem with a complete installer entry' {
        $problems = InModuleScope $module -Parameters @{ Item = (New-TestInstaller -Sha256 ('a' * 64)) } {
            param($Item)
            @(Get-OfficialInstallerProblem -Installer ([OfficialInstaller]::FromObject($Item)))
        }

        $problems | Should -BeNullOrEmpty
    }

    It 'refuses an entry whose <case>' -ForEach @(
        @{ Case = 'download is plain HTTP'; Change = @{ Url = 'http://download.jetbrains.com/setup.exe' } }
        @{ Case = 'download is a file path'; Change = @{ Url = 'file:///C:/setup.exe' } }
        @{ Case = 'download is not a URL'; Change = @{ Url = 'setup.exe' } }
        @{ Case = 'download carries a user name'; Change = @{ Url = 'https://user:pass@example.com/setup.exe' } }
        @{ Case = 'publisher is missing'; Change = @{ Publisher = ' ' } }
        @{ Case = 'name is missing'; Change = @{ Name = '' } }
        @{ Case = 'hash is not SHA-256'; Change = @{ Sha256 = 'abc' } }
        @{ Case = 'argument has a quote'; Change = @{ Arguments = @('/D="C:\x"') } }
        @{ Case = 'argument has a line break'; Change = @{ Arguments = @("/S`n/X") } }
    ) {
        $item = New-TestInstaller
        foreach ($key in $Change.Keys) { $item[$key] = $Change[$key] }

        $problems = InModuleScope $module -Parameters @{ Item = $item } {
            param($Item)
            @(Get-OfficialInstallerProblem -Installer ([OfficialInstaller]::FromObject($Item)))
        }

        $problems | Should -Not -BeNullOrEmpty
    }
}

Describe 'Join-CommandLineArgument' {
    It 'joins <arguments> as <expected>' -ForEach @(
        @{ Arguments = @('/S', '/norestart'); Expected = '/S /norestart' }
        @{ Arguments = @('/D=C:\Program Files\Tool'); Expected = '"/D=C:\Program Files\Tool"' }
        @{ Arguments = @('C:\With Space\'); Expected = '"C:\With Space\\"' }
        @{ Arguments = @(''); Expected = '""' }
        @{ Arguments = @(); Expected = '' }
    ) {
        $joined = InModuleScope $module -Parameters @{ Arguments = $Arguments } {
            param($Arguments)
            Join-CommandLineArgument -ArgumentList $Arguments
        }

        $joined | Should -BeExactly $Expected
    }
}

Describe 'The installer task''s work' {
    BeforeEach {
        # A harmless program to run: a copy of cmd.exe, so the real one is never locked.
        $program = Join-Path -Path $TestDrive -ChildPath ('{0}.exe' -f [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe') -Destination $program
        $hash = (Get-FileHash -LiteralPath $program -Algorithm SHA256).Hash
        $work = InModuleScope $module { $script:OfficialInstallerWork }
    }

    It 'runs the verified file and returns its exit code' {
        $exit = & $work $program $hash $program '/c exit 3'

        $exit | Should -Be 3
    }

    It 'refuses to run a file that changed after it was verified' {
        { & $work $program ('0' * 64) $program '/c exit 0' } | Should -Throw -ExpectedMessage '*changed*'
    }
}

Describe 'Add-ProgramWingetId' {
    BeforeAll {
        Mock -ModuleName $module Write-LogEntry {}
    }

    It 'reuses the earlier answers and looks up only the programs never looked up' {
        Mock -ModuleName $module Invoke-GuestScript { , @([pscustomobject]@{ Name = 'New Tool'; WingetId = 'New.Tool' }) }
        $previous = New-TestRecord -Programs @(
            [ordered]@{ Name = 'LINQPad 9'; Publisher = 'P'; WingetId = 'LINQPad.LINQPad.9' }
            [ordered]@{ Name = 'Odd Tool'; Publisher = 'P'; WingetId = '' }
        )
        $current = New-TestRecord -Programs @(
            [ordered]@{ Name = 'LINQPad 9'; Publisher = 'P' }
            [ordered]@{ Name = 'Odd Tool'; Publisher = 'P' }
            [ordered]@{ Name = 'New Tool'; Publisher = 'P' }
        )

        $ids = InModuleScope $module -Parameters @{ Previous = $previous; Current = $current } {
            param($Previous, $Current)
            $record = [ToolingRecord]::FromObject($Current)
            Add-ProgramWingetId -VM ([VMContext]::new(@{ VMName = 'Alpha' })) -Record $record -Previous ([ToolingRecord]::FromObject($Previous))
            @($record.Programs | ForEach-Object { $_.WingetId })
        }

        $ids | Should -Be @('LINQPad.LINQPad.9', '', 'New.Tool')
        Should -Invoke Invoke-GuestScript -ModuleName $module -Times 1 -Exactly -ParameterFilter {
            @($ArgumentList[0] | ForEach-Object { $_.Name }) -join ',' -eq 'New Tool'
        }
    }

    It 'leaves the programs not looked up when the lookup fails, so the next run tries again' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'session closed' }
        $current = New-TestRecord -Programs @([ordered]@{ Name = 'New Tool'; Publisher = 'P' })

        $id = InModuleScope $module -Parameters @{ Current = $current } {
            param($Current)
            $record = [ToolingRecord]::FromObject($Current)
            Add-ProgramWingetId -VM ([VMContext]::new(@{ VMName = 'Alpha' })) -Record $record -Previous $null
            $record.Programs[0].WingetId
        }

        $null -eq $id | Should -BeTrue
    }

    It 'does not go to the guest when every program has been looked up' {
        Mock -ModuleName $module Invoke-GuestScript {}
        $record = New-TestRecord -Programs @([ordered]@{ Name = 'LINQPad 9'; Publisher = 'P'; WingetId = 'LINQPad.LINQPad.9' })

        InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            Add-ProgramWingetId -VM ([VMContext]::new(@{ VMName = 'Alpha' })) -Record ([ToolingRecord]::FromObject($Record)) -Previous ([ToolingRecord]::FromObject($Record))
        }

        Should -Invoke Invoke-GuestScript -ModuleName $module -Times 0 -Exactly
    }
}

Describe 'Add-ToolingSource' {
    It 'carries the installers over from the earlier list' {
        Mock -ModuleName $module Add-MarketplaceItem {}
        Mock -ModuleName $module Add-ProgramWingetId {}
        $previous = New-TestRecord -Installers @(New-TestInstaller)

        $names = InModuleScope $module -Parameters @{ Previous = $previous } {
            param($Previous)
            $record = [ToolingRecord]::FromObject((@{ Version = 1 }))
            Add-ToolingSource -VM ([VMContext]::new(@{ VMName = 'Alpha' })) -Record $record -Previous ([ToolingRecord]::FromObject($Previous))
            @($record.Installers | ForEach-Object { $_.Name })
        }

        $names | Should -Be @('JetBrains ReSharper')
    }
}

Describe 'Install-OfficialInstaller' {
    BeforeAll {
        $observedProduct = [pscustomobject]@{
            ProductId          = 'Microsoft.VisualStudio.Product.Community'
            ChannelId          = 'VisualStudio.18.Release'
            DisplayName        = 'Visual Studio Community 2026'
            Components         = @()
            ExportedExtensions = @()
            UserExtensions     = @()
        }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry {}
        Mock -ModuleName $module Get-GuestToolingInventory {
            [pscustomobject]@{ Products = @($observedProduct); WingetPackages = @(); Programs = @([pscustomobject]@{ Name = 'Git'; Publisher = 'P' }) }
        }.GetNewClosure()
        # The guest returns the file it checked, inside the folder it was given.
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ FilePath = "$($ArgumentList[3])\installer.exe"; Kind = 'exe'; Sha256 = ('b' * 64) } }
        Mock -ModuleName $module Invoke-GuestTask { '0' }
    }

    It 'installs a missing program from its installer, after checking the download in the guest' {
        $tooling = New-TestRecord -Programs @([ordered]@{ Name = 'JetBrains ReSharper'; Publisher = 'JetBrains s.r.o.' }) -Installers @(New-TestInstaller)

        InModuleScope $module -Parameters @{ Tooling = $tooling } {
            param($Tooling)
            Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
        }

        Should -Invoke Invoke-GuestScript -ModuleName $module -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'https://download.jetbrains.com/resharper/JetBrains.dotUltimate.exe' -and $ArgumentList[1] -eq 'JetBrains s.r.o.'
        }
        Should -Invoke Invoke-GuestTask -ModuleName $module -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[1] -eq ('b' * 64) -and $ArgumentList[3] -eq '/SpecificProductNames=ReSharper /Silent=True'
        }
    }

    It 'runs an .msi through msiexec' {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ FilePath = "$($ArgumentList[3])\installer.msi"; Kind = 'msi'; Sha256 = ('b' * 64) } }
        $tooling = New-TestRecord -Programs @([ordered]@{ Name = 'Tool'; Publisher = 'P' }) -Installers @(New-TestInstaller -Name 'Tool' -Arguments @('/qn'))

        InModuleScope $module -Parameters @{ Tooling = $tooling } {
            param($Tooling)
            Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
        }

        Should -Invoke Invoke-GuestTask -ModuleName $module -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[2] -eq 'msiexec.exe' -and $ArgumentList[3] -like '/i C:\LazyVM\installers\*\installer.msi /qn'
        }
    }

    It 'installs a missing per-user extension from the installer named by its id' {
        $product = [ordered]@{
            ProductId = 'Microsoft.VisualStudio.Product.Community'; ChannelId = 'VisualStudio.18.Release'; DisplayName = 'Visual Studio Community 2026'
            Components = @(); Extensions = @()
            UserExtensions = @([ordered]@{ Id = 'ReSharperPlatformVs18'; DisplayName = 'JetBrains ReSharper'; Publisher = 'JetBrains'; MoreInfo = ''; MarketplaceItem = '' })
        }
        $tooling = New-TestRecord -Products @($product) -Installers @(New-TestInstaller -Name 'ReSharperPlatformVs18')

        InModuleScope $module -Parameters @{ Tooling = $tooling } {
            param($Tooling)
            Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
        }

        Should -Invoke Invoke-GuestTask -ModuleName $module -Times 1 -Exactly
    }

    It 'leaves alone a program the guest already has' {
        $tooling = New-TestRecord -Programs @([ordered]@{ Name = 'Git'; Publisher = 'P' }) -Installers @(New-TestInstaller -Name 'Git')

        InModuleScope $module -Parameters @{ Tooling = $tooling } {
            param($Tooling)
            Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
        }

        Should -Invoke Get-GuestToolingInventory -ModuleName $module -Times 1 -Exactly
        Should -Invoke Invoke-GuestTask -ModuleName $module -Times 0 -Exactly
    }

    It 'does not go to the guest when no missing item has an installer' {
        $tooling = New-TestRecord -Programs @([ordered]@{ Name = 'JetBrains ReSharper'; Publisher = 'P' })

        InModuleScope $module -Parameters @{ Tooling = $tooling } {
            param($Tooling)
            Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
        }

        Should -Invoke Get-GuestToolingInventory -ModuleName $module -Times 0 -Exactly
    }

    It 'never downloads from an entry that fails its checks' {
        $tooling = New-TestRecord -Programs @([ordered]@{ Name = 'JetBrains ReSharper'; Publisher = 'P' }) -Installers @(New-TestInstaller -Url 'http://download.jetbrains.com/setup.exe')

        InModuleScope $module -Parameters @{ Tooling = $tooling } {
            param($Tooling)
            Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
        }

        Should -Invoke Invoke-GuestScript -ModuleName $module -Times 0 -Exactly
        Should -Invoke Invoke-GuestTask -ModuleName $module -Times 0 -Exactly
    }

    It 'never runs a download the guest refused, and carries on' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'the signature is NotSigned' }
        $tooling = New-TestRecord -Programs @([ordered]@{ Name = 'JetBrains ReSharper'; Publisher = 'P' }) -Installers @(New-TestInstaller)

        {
            InModuleScope $module -Parameters @{ Tooling = $tooling } {
                param($Tooling)
                Install-OfficialInstaller -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM'; ToolingWingetExclude = @() })) -Tooling ([ToolingRecord]::FromObject($Tooling))
            }
        } | Should -Not -Throw

        Should -Invoke Invoke-GuestTask -ModuleName $module -Times 0 -Exactly
    }
}
