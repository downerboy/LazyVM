# ProgramInstaller.Tests.ps1
# Programs that winget does not install, reinstalled by a rebuild from an
# official installer the tooling list names (#24), and programs winget can
# install although they were installed some other way. Nothing here needs
# Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    function New-TestProgram {
        <# A tooling-list program, with an installer when $Url is given. #>
        param(
            [Parameter(Mandatory)][string]$Name,
            [string]$Url,
            [string]$SignedBy = 'JetBrains s.r.o.',
            [string]$Arguments = '/S'
        )

        $item = @{ Name = $Name; Publisher = 'Test Publisher' }
        if ($Url) { $item.Installer = @{ Url = $Url; Arguments = $Arguments; SignedBy = $SignedBy } }
        return InModuleScope $module -Parameters @{ Item = $item } { param($Item) [ToolingProgram]::FromObject($Item) }
    }

    function New-TestTooling {
        param(
            [object[]]$Programs = @(),
            [object[]]$Awaiting = @()
        )

        return InModuleScope $module -Parameters @{ Programs = $Programs; Awaiting = $Awaiting } {
            param($Programs, $Awaiting)
            $record = [ToolingRecord]::new()
            $record.Programs = [ToolingProgram[]]@($Programs)
            if ($Awaiting) {
                $record.AwaitingReinstall = [AwaitingReinstall]::new()
                $record.AwaitingReinstall.Programs = [ToolingProgram[]]@($Awaiting)
            }
            $record
        }
    }
}

Describe 'A program''s installer in the tooling list' {
    It 'is kept when the list is written and read back' {
        $tooling = New-TestTooling -Programs @(New-TestProgram -Name 'JetBrains ReSharper' -Url 'https://download.jetbrains.com/resharper/ReSharper.exe')

        $read = InModuleScope $module -Parameters @{ Tooling = $tooling } { param($Tooling) [ToolingRecord]::FromJson($Tooling.ToJson()) }

        $read.Programs[0].Installer.Url | Should -Be 'https://download.jetbrains.com/resharper/ReSharper.exe'
        $read.Programs[0].Installer.SignedBy | Should -Be 'JetBrains s.r.o.'
        $read.Programs[0].Installer.Arguments | Should -Be '/S'
    }

    It 'is left out of the list for a program that has none' {
        $tooling = New-TestTooling -Programs @(New-TestProgram -Name 'Git')

        $tooling.ToJson() | Should -Not -Match 'Installer'
    }
}

Describe 'Test-ToolingInstaller' {
    It 'accepts <Url>' -ForEach @(
        @{ Url = 'https://download.jetbrains.com/resharper/ReSharper.exe' }
        @{ Url = 'https://example.com/setup.msi' }
    ) {
        $program = New-TestProgram -Name 'Tool' -Url $Url

        InModuleScope $module -Parameters @{ Program = $program } { param($Program) Test-ToolingInstaller -Installer $Program.Installer } | Should -BeNullOrEmpty
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an address that is not https'; Url = 'http://example.com/setup.exe'; SignedBy = 'Vendor'; Reason = '*https*' }
        @{ Case = 'an address that is not a full URL'; Url = 'setup.exe'; SignedBy = 'Vendor'; Reason = '*https*' }
        @{ Case = 'a file that is not an .exe or .msi'; Url = 'https://example.com/setup.zip'; SignedBy = 'Vendor'; Reason = '*.exe or .msi*' }
        @{ Case = 'an installer with no SignedBy'; Url = 'https://example.com/setup.exe'; SignedBy = ''; Reason = '*SignedBy*' }
    ) {
        $program = New-TestProgram -Name 'Tool' -Url $Url -SignedBy $SignedBy

        InModuleScope $module -Parameters @{ Program = $program } { param($Program) Test-ToolingInstaller -Installer $Program.Installer } | Should -BeLike $Reason
    }
}

Describe 'Add-ProgramInstaller' {
    It 'gives each program the installer the previous list named for it, from its programs or those awaiting reinstall' {
        $previous = New-TestTooling -Programs @(New-TestProgram -Name 'Tool A' -Url 'https://example.com/a.exe') -Awaiting @(New-TestProgram -Name 'Tool B' -Url 'https://example.com/b.exe')
        $record = New-TestTooling -Programs @((New-TestProgram -Name 'Tool A'), (New-TestProgram -Name 'Tool B'), (New-TestProgram -Name 'Tool C'))

        InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } { param($Record, $Previous) Add-ProgramInstaller -Record $Record -Previous $Previous }

        @($record.Programs | ForEach-Object { "$($_.Name)=$(if ($_.Installer) { $_.Installer.Url })" }) | Should -Be @('Tool A=https://example.com/a.exe', 'Tool B=https://example.com/b.exe', 'Tool C=')
    }

    It 'changes nothing when there is no previous list' {
        $record = New-TestTooling -Programs @(New-TestProgram -Name 'Tool A')

        { InModuleScope $module -Parameters @{ Record = $record } { param($Record) Add-ProgramInstaller -Record $Record -Previous $null } } | Should -Not -Throw
    }
}

Describe 'Install-ToolingProgram' {
    BeforeEach {
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM\Setup'; ToolingWingetExclude = @() }) }
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-GuestToolingInventory { [pscustomobject]@{ Products = @(); WingetPackages = @(); Programs = @([pscustomobject]@{ Name = 'Present Tool'; Publisher = 'Vendor' }) } }
        Mock -ModuleName $module Invoke-GuestScript { }
        Mock -ModuleName $module Invoke-GuestInstaller { 0 }
    }

    It 'installs a missing program that has an installer, once it is downloaded and checked' {
        $tooling = New-TestTooling -Awaiting @(New-TestProgram -Name 'JetBrains ReSharper' -Url 'https://download.jetbrains.com/resharper/ReSharper.exe' -Arguments '/SpecificProductNames=ReSharper /Silent=True')

        InModuleScope $module -Parameters @{ VM = $vm; Tooling = $tooling } { param($VM, $Tooling) Install-ToolingProgram -VM $VM -Tooling $Tooling }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'https://download.jetbrains.com/resharper/ReSharper.exe' -and $ArgumentList[2] -eq 'JetBrains s.r.o.' }
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter { $FilePath -like 'C:\LazyVM\Setup\*.exe' -and $ArgumentList -contains '/SpecificProductNames=ReSharper /Silent=True' }
    }

    It 'runs an .msi through msiexec' {
        $tooling = New-TestTooling -Programs @(New-TestProgram -Name 'Some Tool' -Url 'https://example.com/tool.msi' -Arguments '/qn')

        InModuleScope $module -Parameters @{ VM = $vm; Tooling = $tooling } { param($VM, $Tooling) Install-ToolingProgram -VM $VM -Tooling $Tooling }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' -and $ArgumentList[0] -eq '/i' -and $ArgumentList -contains '/qn' }
    }

    It 'leaves alone a program the guest already has, and one with no installer' {
        $tooling = New-TestTooling -Programs @((New-TestProgram -Name 'Present Tool' -Url 'https://example.com/p.exe'), (New-TestProgram -Name 'Other Tool'))

        InModuleScope $module -Parameters @{ VM = $vm; Tooling = $tooling } { param($VM, $Tooling) Install-ToolingProgram -VM $VM -Tooling $Tooling }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0 -Exactly
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
    }

    It 'runs nothing when the download or its signature check fails, and carries on' {
        Mock -ModuleName $module Invoke-GuestScript { throw "it is signed by 'Someone Else', not 'JetBrains s.r.o.'" }
        $tooling = New-TestTooling -Programs @(New-TestProgram -Name 'JetBrains ReSharper' -Url 'https://download.jetbrains.com/resharper/ReSharper.exe')

        { InModuleScope $module -Parameters @{ VM = $vm; Tooling = $tooling } { param($VM, $Tooling) Install-ToolingProgram -VM $VM -Tooling $Tooling } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0 -Exactly
    }

    It 'downloads nothing for an installer the tooling list gives wrongly' {
        $tooling = New-TestTooling -Programs @(New-TestProgram -Name 'Some Tool' -Url 'http://example.com/tool.exe')

        InModuleScope $module -Parameters @{ VM = $vm; Tooling = $tooling } { param($VM, $Tooling) Install-ToolingProgram -VM $VM -Tooling $Tooling }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 0 -Exactly
    }

    It 'asks the guest nothing when no program has an installer' {
        $tooling = New-TestTooling -Programs @(New-TestProgram -Name 'Other Tool')

        InModuleScope $module -Parameters @{ VM = $vm; Tooling = $tooling } { param($VM, $Tooling) Install-ToolingProgram -VM $VM -Tooling $Tooling }

        Should -Invoke -ModuleName $module Get-GuestToolingInventory -Times 0 -Exactly
    }
}

Describe 'Save-GuestVerifiedInstaller' {
    BeforeEach {
        $path = Join-Path -Path $TestDrive -ChildPath 'Setup\installer.exe'
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'installer' }
    }

    It 'keeps the download when it is signed, validly, by the vendor named' {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status 'Valid' -Signer 'JetBrains s.r.o.' }

        Save-GuestVerifiedInstaller -Url 'https://download.jetbrains.com/r.exe' -Path $path -SignedBy 'JetBrains s.r.o.'

        $path | Should -Exist
    }

    It 'throws, and deletes the download, when <Case>' -ForEach @(
        @{ Case = 'someone else signed it'; Status = 'Valid'; Signer = 'Someone Else'; Message = '*Someone Else*' }
        @{ Case = 'its signature is not valid'; Status = 'HashMismatch'; Signer = 'JetBrains s.r.o.'; Message = '*HashMismatch*' }
        @{ Case = 'it is not signed'; Status = 'NotSigned'; Signer = $null; Message = '*NotSigned*' }
    ) {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status $Status -Signer $Signer }

        { Save-GuestVerifiedInstaller -Url 'https://download.jetbrains.com/r.exe' -Path $path -SignedBy 'JetBrains s.r.o.' } | Should -Throw -ExpectedMessage $Message

        $path | Should -Not -Exist
    }

    It 'downloads nothing from an address that is not https' {
        { Save-GuestVerifiedInstaller -Url 'http://download.jetbrains.com/r.exe' -Path $path -SignedBy 'JetBrains s.r.o.' } | Should -Throw -ExpectedMessage '*https*'

        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    BeforeAll {
        function New-TestSignature {
            <# What Get-AuthenticodeSignature returns, as far as the helper reads it. #>
            param([string]$Status, [string]$Signer)

            $certificate = $null
            if ($Signer) {
                $certificate = [pscustomobject]@{ Name = $Signer }
                $certificate | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value { $this.Name }
            }
            return [pscustomobject]@{ Status = $Status; SignerCertificate = $certificate }
        }
    }
}

Describe 'ConvertFrom-GuestWingetList' {
    It 'reads each row''s package id from under the Id heading' {
        $lines = @(
            "   - `r   \ `rName                         Id                          Version   Available Source"
            '--------------------------------------------------------------------------------------------'
            'JetBrains dotPeek            JetBrains.dotPeek           2026.3.1            winget'
            'Notepad++ (64-bit x64)       Notepad++.Notepad++         8.7.1     8.7.2     winget'
        )

        ConvertFrom-GuestWingetList -Lines $lines | Should -Be @('JetBrains.dotPeek', 'Notepad++.Notepad++')
    }

    It 'leaves out an id winget cut short' {
        $lines = @(
            'Name           Id             Version Source'
            '--------------------------------------------'
            "Some Long Tool SomeVendor.Lo$([char]0x2026) 1.0     winget"
        )

        @(ConvertFrom-GuestWingetList -Lines $lines) | Should -BeNullOrEmpty
    }

    It 'returns nothing when the output has no table' {
        @(ConvertFrom-GuestWingetList -Lines @('No installed package found matching input criteria.')) | Should -BeNullOrEmpty
    }
}
