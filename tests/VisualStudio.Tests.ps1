# VisualStudio.Tests.ps1
# Installing Visual Studio Installer products and their extensions (#109).
# The installer refuses a whole install when one extension in it is
# unsigned, so a product is installed with its components only and its
# extensions are added afterwards, a refused batch one extension at a time.
# The guest is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    $link = { param($item) "https://marketplace.visualstudio.com/items?itemName=$item" }
    $signed = & $link 'Pub.Signed'
    $themeA = & $link 'Pub.ThemeA'
    $themeB = & $link 'Pub.ThemeB'

    $product = @{
        ProductId   = 'Microsoft.VisualStudio.Product.Community'
        ChannelId   = 'VisualStudio.18.Release'
        DisplayName = 'Visual Studio Community 2026'
        Components  = @('Microsoft.VisualStudio.Workload.ManagedDesktop')
        Extensions  = @($signed, $themeA, $themeB)
    }
    $settings = @{
        VMName                 = 'Alpha'
        GuestSetupDir          = 'C:\LazyVMSetup'
        VSInstallMinutes       = 90
        InstallerBootstrappers = @{ 'VisualStudio.18.Release' = 'https://aka.ms/vs/stable/vs_{edition}.exe' }
        UnsignedExtensions     = @()
    }
}

Describe 'Install-ToolingProduct' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ FilePath = 'C:\LazyVMSetup\bootstrap-community.exe'; Arguments = @('--quiet') } }
        Mock -ModuleName $module Add-ProductExtension { @() }
    }

    It 'installs the product with its components only, then adds its extensions' {
        $state = @{ Installed = $false }
        Mock -ModuleName $module Invoke-GuestInstaller { $state.Installed = $true; 0 }
        Mock -ModuleName $module Get-GuestInstallerProduct {
            if ($state.Installed) {
                [pscustomobject]@{ ProductId = 'Microsoft.VisualStudio.Product.Community'; ChannelId = 'VisualStudio.18.Release'; InstallPath = 'C:\VS' }
            }
        }

        InModuleScope $module -Parameters @{ Product = $product; Settings = $settings } {
            param($Product, $Settings)
            Install-ToolingProduct -VM ([VMContext]::new($Settings)) -Tooling ([ToolingRecord]::FromObject(@{ Products = @($Product) }))
        }

        # The install's .vsconfig carries no extensions, and it is never
        # given --allowUnsignedExtensions.
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $Activity -like '*download' -and ($ArgumentList[3] | ConvertFrom-Json).PSObject.Properties.Name -notcontains 'extensions' -and $ArgumentList.Count -eq 5
        }
        Should -Invoke -ModuleName $module Add-ProductExtension -Times 1 -Exactly -ParameterFilter {
            $InstallPath -eq 'C:\VS' -and $Links.Count -eq 3
        }
    }

    It 'adds no extensions when the product itself failed, and points at the installer''s logs' {
        Mock -ModuleName $module Invoke-GuestInstaller { 1 }
        Mock -ModuleName $module Get-GuestInstallerProduct { }

        InModuleScope $module -Parameters @{ Product = $product; Settings = $settings } {
            param($Product, $Settings)
            Install-ToolingProduct -VM ([VMContext]::new($Settings)) -Tooling ([ToolingRecord]::FromObject(@{ Products = @($Product) }))
        }

        Should -Invoke -ModuleName $module Add-ProductExtension -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*C:\Windows\SystemTemp\dd_*.log*' }
    }

    # An interrupted install leaves an instance vswhere still lists, so it
    # must be repaired rather than taken as installed for good (#26).
    It 'repairs an instance that is <Case> instead of skipping it' -ForEach @(
        @{ Case = 'incomplete'; IsComplete = $false; IsLaunchable = $true }
        @{ Case = 'not launchable'; IsComplete = $true; IsLaunchable = $false }
    ) {
        Mock -ModuleName $module Invoke-GuestScript { 'C:\Installer\setup.exe' }
        Mock -ModuleName $module Invoke-GuestInstaller { 0 }
        $instance = [pscustomobject]@{
            ProductId = 'Microsoft.VisualStudio.Product.Community'; ChannelId = 'VisualStudio.18.Release'
            InstallPath = 'C:\VS'; IsComplete = $IsComplete; IsLaunchable = $IsLaunchable
        }
        Mock -ModuleName $module Get-GuestInstallerProduct { $instance }.GetNewClosure()
        $bare = $product.Clone()
        $bare.Extensions = @()

        InModuleScope $module -Parameters @{ Product = $bare; Settings = $settings } {
            param($Product, $Settings)
            Install-ToolingProduct -VM ([VMContext]::new($Settings)) -Tooling ([ToolingRecord]::FromObject(@{ Products = @($Product) }))
        }

        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Installer\setup.exe' -and $ArgumentList[0] -eq 'repair' -and $ArgumentList -contains '"C:\VS"' -and $ArgumentList -contains '--quiet'
        }
    }

    It 'adds no extensions to an incomplete instance whose repair failed, and points at the installer''s logs' {
        Mock -ModuleName $module Invoke-GuestScript { 'C:\Installer\setup.exe' }
        Mock -ModuleName $module Invoke-GuestInstaller { 1 }
        Mock -ModuleName $module Get-GuestInstallerProduct {
            [pscustomobject]@{
                ProductId = 'Microsoft.VisualStudio.Product.Community'; ChannelId = 'VisualStudio.18.Release'
                InstallPath = 'C:\VS'; IsComplete = $false; IsLaunchable = $false
            }
        }

        InModuleScope $module -Parameters @{ Product = $product; Settings = $settings } {
            param($Product, $Settings)
            Install-ToolingProduct -VM ([VMContext]::new($Settings)) -Tooling ([ToolingRecord]::FromObject(@{ Products = @($Product) }))
        }

        Should -Invoke -ModuleName $module Add-ProductExtension -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -ParameterFilter { $Message -like '*C:\Windows\SystemTemp\dd_*.log*' }
    }
}

Describe 'Add-ProductExtension' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogList { }
    }

    It 'adds every extension in one go when the installer takes them' {
        Mock -ModuleName $module Invoke-ProductModify { $true }

        $refused = InModuleScope $module -Parameters @{ Product = $product; Settings = $settings } {
            param($Product, $Settings)
            $p = [ToolingProduct]::FromObject($Product)
            Add-ProductExtension -VM ([VMContext]::new($Settings)) -Product $p -InstallPath 'C:\VS' -Links $p.ExtensionLinks()
        }

        @($refused).Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-ProductModify -Times 1 -Exactly -ParameterFilter { $Links.Count -eq 3 -and -not $AllowUnsigned }
        Should -Invoke -ModuleName $module Write-LogList -Times 0 -Exactly
    }

    It 'adds a refused batch one at a time, so the rest still go in and each refusal is named' {
        # The installer refuses any batch holding an unsigned theme.
        Mock -ModuleName $module Invoke-ProductModify { -not ($Links | Where-Object { $_ -like '*Theme*' }) }

        $refused = InModuleScope $module -Parameters @{ Product = $product; Settings = $settings } {
            param($Product, $Settings)
            $p = [ToolingProduct]::FromObject($Product)
            Add-ProductExtension -VM ([VMContext]::new($Settings)) -Product $p -InstallPath 'C:\VS' -Links $p.ExtensionLinks()
        }

        @($refused) | Sort-Object | Should -Be @($themeA, $themeB)
        Should -Invoke -ModuleName $module Invoke-ProductModify -Times 4 -Exactly
        Should -Invoke -ModuleName $module Invoke-ProductModify -Times 1 -Exactly -ParameterFilter { $Links.Count -eq 1 -and $Links[0] -eq $signed }
        Should -Invoke -ModuleName $module Write-LogList -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and ($Items -join ',') -eq 'Pub.ThemeA,Pub.ThemeB'
        }
    }

    It 'runs each modify in the guest and takes a failing installer exit code as a refusal' {
        # The guest's installer exits 1 for any batch holding an unsigned theme.
        Mock -ModuleName $module Write-LogError { }
        $guest = @{ Config = '' }
        Mock -ModuleName $module Invoke-GuestScript { $guest.Config = $ArgumentList[1]; [pscustomobject]@{ FilePath = 'C:\Installer\setup.exe'; Arguments = @('modify') } }
        Mock -ModuleName $module Invoke-GuestInstaller { if ($guest.Config -like '*Theme*') { 1 } else { 0 } }

        $refused = InModuleScope $module -Parameters @{ Product = $product; Settings = $settings } {
            param($Product, $Settings)
            $p = [ToolingProduct]::FromObject($Product)
            Add-ProductExtension -VM ([VMContext]::new($Settings)) -Product $p -InstallPath 'C:\VS' -Links $p.ExtensionLinks()
        }

        @($refused) | Sort-Object | Should -Be @($themeA, $themeB)
        Should -Invoke -ModuleName $module Invoke-GuestInstaller -Times 4 -Exactly -ParameterFilter { $FilePath -eq 'C:\Installer\setup.exe' }
    }

    It 'gives only the extensions listed in UnsignedExtensions --allowUnsignedExtensions, in a batch of their own' {
        Mock -ModuleName $module Invoke-ProductModify { $true }
        $allowing = $settings.Clone()
        $allowing.UnsignedExtensions = @('Pub.ThemeA')

        InModuleScope $module -Parameters @{ Product = $product; Settings = $allowing } {
            param($Product, $Settings)
            $p = [ToolingProduct]::FromObject($Product)
            $null = Add-ProductExtension -VM ([VMContext]::new($Settings)) -Product $p -InstallPath 'C:\VS' -Links $p.ExtensionLinks()
        }

        Should -Invoke -ModuleName $module Invoke-ProductModify -Times 1 -Exactly -ParameterFilter { $AllowUnsigned -and ($Links -join ',') -eq $themeA }
        Should -Invoke -ModuleName $module Invoke-ProductModify -Times 1 -Exactly -ParameterFilter { -not $AllowUnsigned -and $Links -notcontains $themeA -and $Links.Count -eq 2 }
    }
}

# New projects go on the Dev Drive, so they outlive the Windows evaluation
# (#176). The setting lives on C:, so every settings restore sets it again.
Describe 'ConvertTo-ProjectsLocationSetting' {
    BeforeAll {
        $projectsLocation = {
            param([string]$Settings)
            ([xml]$Settings).SelectSingleNode("/UserSettings/ToolsOptions/ToolsOptionsCategory[@name='Environment']/ToolsOptionsSubCategory[@name='ProjectsAndSolution']/PropertyValue[@name='ProjectsLocation']").InnerText
        }
    }

    It 'replaces the projects location in a settings file, keeping its other settings' {
        $backup = @'
<UserSettings>
  <ApplicationIdentity version="18.0"/>
  <ToolsOptions>
    <ToolsOptionsCategory name="Environment" RegisteredName="Environment">
      <ToolsOptionsSubCategory name="ProjectsAndSolution" RegisteredName="ProjectsAndSolution" PackageName="Visual Studio Environment Package">
        <PropertyValue name="ProjectsLocation">C:\Users\dev\source\repos</PropertyValue>
        <PropertyValue name="ShowOutputWindowBeforeBuild">true</PropertyValue>
      </ToolsOptionsSubCategory>
    </ToolsOptionsCategory>
  </ToolsOptions>
</UserSettings>
'@

        $settings = InModuleScope $module -Parameters @{ Backup = $backup } { param($Backup) ConvertTo-ProjectsLocationSetting -Settings $Backup -Path 'W:\source\repos' }

        & $projectsLocation $settings | Should -Be 'W:\source\repos'
        ([xml]$settings).SelectSingleNode("//PropertyValue[@name='ShowOutputWindowBeforeBuild']").InnerText | Should -Be 'true'
    }

    It 'adds the projects location to a settings file that has none' {
        $backup = '<UserSettings><ApplicationIdentity version="18.0"/><Category name="Environment_Group" RegisteredName="Environment_Group"/></UserSettings>'

        $settings = InModuleScope $module -Parameters @{ Backup = $backup } { param($Backup) ConvertTo-ProjectsLocationSetting -Settings $Backup -Path 'W:\source\repos' }

        & $projectsLocation $settings | Should -Be 'W:\source\repos'
        ([xml]$settings).SelectSingleNode("//Category[@name='Environment_Group']") | Should -Not -BeNullOrEmpty
    }

    It 'makes a settings file holding only the projects location when there is no backup' {
        $settings = InModuleScope $module { ConvertTo-ProjectsLocationSetting -Settings '' -Path 'W:\source\repos' }

        & $projectsLocation $settings | Should -Be 'W:\source\repos'
    }
}

Describe 'Restore-GuestVisualStudioSetting' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-GuestVisualStudio { [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; DevEnvPath = 'C:\VS\devenv.exe' } }
        $copied = @{ Settings = $null }
        Mock -ModuleName $module Copy-ToGuest { $copied.Settings = Get-Content -LiteralPath $HostPath -Raw }
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { }
        $devDrive = $settings.Clone()
        $devDrive.UseDevDrive = $true
        $devDrive.DevDriveLetter = 'W'
        $devDrive.VSSettingsBackup = Join-Path $TestDrive 'missing.vssettings'
    }

    It 'points the projects location at the letter the Dev Drive actually got, even with no settings backup' {
        InModuleScope $module -Parameters @{ Settings = $devDrive } {
            param($Settings)
            $vm = [VMContext]::new($Settings)
            $vm.Runtime.DevDriveLetter = 'X'
            Restore-GuestVisualStudioSetting -VM $vm
        }

        $copied.Settings | Should -BeLike '*X:\source\repos*'
        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'X:\source\repos' }
    }

    It 'carries the settings backup with the projects location changed' {
        $devDrive.VSSettingsBackup = Join-Path $TestDrive 'VisualStudio.vssettings'
        Set-Content -LiteralPath $devDrive.VSSettingsBackup -Value '<UserSettings><Category name="Environment_Group" RegisteredName="Environment_Group"/></UserSettings>'

        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        $copied.Settings | Should -BeLike '*Environment_Group*'
        $copied.Settings | Should -BeLike '*W:\source\repos*'
    }

    It 'skips the restore with no settings backup when the Dev Drive is turned off' {
        $devDrive.UseDevDrive = $false

        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 0 -Exactly
    }
}

Describe 'The default tooling list' {
    It 'loads, and holds none of the extensions the installer refused as unsigned (#112)' {
        $links = InModuleScope $module {
            $record = [ToolingRecord]::FromObject((Get-DefaultSetting).Tooling)
            @($record.Products | ForEach-Object { $_.ExtensionLinks() })
        }

        $links.Count | Should -BeGreaterThan 0
        foreach ($unsigned in 'TeamXavalon.XAMLStyler2022', 'SergiyEgoshyn.HiberbeeTheme', 'AustinStanding.vsthememidnightdeep', 'AgitoReiKen.zerovstheme') {
            $links | Should -Not -Contain "https://marketplace.visualstudio.com/items?itemName=$unsigned"
        }
    }
}

Describe 'Test-InstallSucceeded' {
    It 'returns <Expected> for exit code <Code>' -ForEach @(
        @{ Code = 0; Expected = $true }
        @{ Code = 3010; Expected = $true }
        @{ Code = 1641; Expected = $true }
        @{ Code = 1; Expected = $false }
        @{ Code = $null; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Code = $Code } { param($Code) Test-InstallSucceeded -ExitCode $Code } | Should -Be $Expected
    }
}
