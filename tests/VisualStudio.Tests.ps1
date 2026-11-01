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
        InstallVisualStudio    = $true
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
    BeforeAll {
        # Mock replaces only a command that exists, and taskkill.exe exists only on Windows.
        function taskkill.exe { }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-GuestVisualStudio { [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; DevEnvPath = 'C:\VS\devenv.exe'; InstanceId = 'a1b2c3d4' } }
        $markers = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-VisualStudioSettingMarker { $markers.Add("$InstanceId=$(if (Get-Variable -Name Pending -ValueOnly -ErrorAction SilentlyContinue) { 'Pending' } else { Get-Variable -Name AppliedHash -ValueOnly })") }
        $copied = @{ Settings = $null }
        Mock -ModuleName $module Copy-ToGuest { $copied.Settings = Get-Content -LiteralPath $HostPath -Raw }
        $task = @{ Work = $null; Devenv = $null }
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { $task.Work = $ScriptBlock }
        Mock -ModuleName $module Get-GuestSignedInUser { @('devadmin') }
        Mock -ModuleName $module Complete-GuestVisualStudioFirstLaunch { $true }
        $devDrive = $settings.Clone()
        $devDrive.UseDevDrive = $true
        $devDrive.DevDriveLetter = 'W'
        $devDrive.GuestAdminUser = 'devadmin'
        $devDrive.VSSettingsBackup = Join-Path $TestDrive 'missing.vssettings'

        <#
          The task's work as the guest runs it: from its text, so it binds to
          the mocks here. $DevenvProcess stands for the devenv process it starts.
        #>
        $runWork = {
            param($DevenvProcess)
            $task.Devenv = $DevenvProcess
            Mock Test-Path { $true }
            Mock New-Item { }
            Mock Start-Process { $task.Devenv }
            Mock taskkill.exe { }
            $work = [scriptblock]::Create($task.Work.ToString())
            & $work 'C:\VS\devenv.exe' 'C:\LazyVMSetup\VisualStudio.vssettings' $null 10
        }
        $newDevenv = {
            param([bool]$Exits, [int]$ExitCode = 0)
            $process = [pscustomobject]@{ Id = 4242; ExitCode = $ExitCode }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value ([scriptblock]::Create("param(`$milliseconds) `$$Exits"))
            return $process
        }
    }

    It 'fails at once, before starting devenv, when the guest account is not signed in (#262)' {
        Mock -ModuleName $module Get-GuestSignedInUser { @() }

        { InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) } } |
            Should -Throw "*'devadmin' is not signed in*retried automatically*"
        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 0 -Exactly
    }

    It 'records the settings as pending in the guest before starting devenv, and their hash once they are applied (#266)' {
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { $markers.Add('devenv') }

        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        $expected = InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) (Get-VisualStudioSettingToApply -VM ([VMContext]::new($Settings))).BackupHash }
        $markers -join ',' | Should -Be "a1b2c3d4=Pending,devenv,a1b2c3d4=$expected"
    }

    It 'leaves the settings recorded as pending when devenv fails, so nightly maintenance tries again (#266)' {
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { throw 'devenv did not exit' }

        { InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) } } | Should -Throw '*devenv did not exit*'

        $markers -join ',' | Should -Be 'a1b2c3d4=Pending'
    }

    It 'gives the guest task longer than devenv gets, so the guest is the one to say why devenv did not finish (#262)' {
        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -gt $ArgumentList[-1] }
    }

    It 'stops devenv and everything it started when it does not exit in time, and says why (#262)' {
        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        { & $runWork (& $newDevenv -Exits $false) } | Should -Throw '*did not exit within 10 minute(s)*first launch*retried automatically*'
        Should -Invoke taskkill.exe -Times 1 -Exactly -ParameterFilter { "$args" -eq '/PID 4242 /T /F' }
    }

    It 'applies the settings when devenv exits cleanly (#262)' {
        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        { & $runWork (& $newDevenv -Exits $true) } | Should -Not -Throw
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '/ResetSettings' -and -not $Wait }
        Should -Invoke taskkill.exe -Times 0 -Exactly
    }

    It 'reports the exit code when devenv fails (#262)' {
        InModuleScope $module -Parameters @{ Settings = $devDrive } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) }

        { & $runWork (& $newDevenv -Exits $true -ExitCode 1) } | Should -Throw '*devenv exited with 1*'
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

Describe 'Get-VisualStudioSettingToApply (#266)' {
    BeforeEach {
        $vmSettings = $settings.Clone()
        $vmSettings.UseDevDrive = $true
        $vmSettings.DevDriveLetter = 'W'
        $vmSettings.VSSettingsBackup = Join-Path $TestDrive 'VisualStudio.vssettings'
        Set-Content -LiteralPath $vmSettings.VSSettingsBackup -Value '<UserSettings><Category name="Environment_Group"/></UserSettings>'
        $toApply = { param($Settings) InModuleScope $module -Parameters @{ Settings = $Settings } { param($Settings) Get-VisualStudioSettingToApply -VM ([VMContext]::new($Settings)) } }
    }

    It 'is the settings backup with the projects location on the Dev Drive' {
        $result = & $toApply $vmSettings

        $result.Text | Should -BeLike '*Environment_Group*W:\source\repos*'
        $result.HasBackup | Should -BeTrue
    }

    It 'records the backup file as it is, whatever letter the Dev Drive has in this run' {
        $fileHash = (Get-FileHash -LiteralPath $vmSettings.VSSettingsBackup -Algorithm SHA256).Hash

        (& $toApply $vmSettings).BackupHash | Should -Be $fileHash
        $vmSettings.DevDriveLetter = 'X'
        (& $toApply $vmSettings).BackupHash | Should -Be $fileHash
    }

    It 'is only the projects location with no settings backup' {
        Remove-Item -LiteralPath $vmSettings.VSSettingsBackup

        $result = & $toApply $vmSettings

        $result.HasBackup | Should -BeFalse
        $result.Text | Should -BeLike '*W:\source\repos*'
        $result.BackupHash | Should -Match '^[0-9A-F]{64}$'
    }

    It 'is nothing with no settings backup and no Dev Drive' {
        $vmSettings.UseDevDrive = $false
        Remove-Item -LiteralPath $vmSettings.VSSettingsBackup

        & $toApply $vmSettings | Should -BeNullOrEmpty
    }
}

Describe 'Get-VisualStudioSettingTarget (#266)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-GuestVisualStudio { [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; DevEnvPath = 'C:\VS\devenv.exe'; InstanceId = 'a1b2c3d4' } }
        $vmSettings = $settings.Clone()
        $vmSettings.UseDevDrive = $true
        $vmSettings.DevDriveLetter = 'W'
        $vmSettings.VSSettingsBackup = Join-Path $TestDrive 'missing.vssettings'
        $target = { InModuleScope $module -Parameters @{ Settings = $vmSettings } { param($Settings) Get-VisualStudioSettingTarget -VM ([VMContext]::new($Settings)) } }
    }

    It 'is the Visual Studio and the settings to apply to it' {
        $result = & $target

        $result.VisualStudio.InstanceId | Should -Be 'a1b2c3d4'
        $result.Settings.ProjectsLocation | Should -Be 'W:\source\repos'
    }

    It 'is nothing, without asking the guest, when there are no settings to apply' {
        $vmSettings.UseDevDrive = $false

        & $target | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $module Get-GuestVisualStudio -Times 0 -Exactly
    }

    It 'is nothing when Visual Studio is not installed' {
        Mock -ModuleName $module Get-GuestVisualStudio { $null }

        & $target | Should -BeNullOrEmpty
    }
}

Describe 'Test-VisualStudioSettingPending (#266)' {
    It 'is <Expected> when the guest records "<Marker>" (nothing: a VM built before LazyVM recorded it)' -ForEach @(
        @{ Marker = $null; Expected = $true }
        @{ Marker = ''; Expected = $true }
        @{ Marker = 'Pending'; Expected = $true }
        @{ Marker = 'HASH'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Marker = $Marker } { param($Marker) Test-VisualStudioSettingPending -Marker $Marker } | Should -Be $Expected
    }
}

Describe 'Write-VisualStudioSettingMarker (#266)' {
    BeforeEach {
        $recorded = @{ Value = $null }
        Mock -ModuleName $module Invoke-GuestScript { $recorded.Value = $ArgumentList[1] }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }
    }

    It 'records <Expected> for <Name>' -ForEach @(
        @{ Name = '-Pending'; Arguments = @{ Pending = $true }; Expected = 'Pending' }
        @{ Name = '-AppliedHash'; Arguments = @{ AppliedHash = 'HASH' }; Expected = 'HASH' }
    ) {
        InModuleScope $module -Parameters @{ VM = $vm; Arguments = $Arguments } { param($VM, $Arguments) Write-VisualStudioSettingMarker -VM $VM -InstanceId 'a1b2c3d4' @Arguments }

        $recorded.Value | Should -Be $Expected
    }

    It 'takes either -Pending or -AppliedHash, not both' {
        { InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Write-VisualStudioSettingMarker -VM $VM -InstanceId 'a1b2c3d4' -Pending -AppliedHash 'HASH' } } | Should -Throw
    }
}

Describe 'Write-VisualStudioSettingFirstOpened (#266)' {
    It 'records the date, without the time, in a form that reads back the same in any culture' {
        $recorded = @{ Arguments = $null }
        Mock -ModuleName $module Invoke-GuestScript { $recorded.Arguments = $ArgumentList }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }

        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Write-VisualStudioSettingFirstOpened -VM $VM -InstanceId 'a1b2c3d4' -Date ([datetime]'2026-10-25T03:15:00') }

        $recorded.Arguments | Should -Be @('a1b2c3d4', '2026-10-25')
    }
}

Describe 'Get-GuestVisualStudioSettingState (#266)' {
    It 'reads the date Visual Studio was first found opened as a date, or nothing when the guest records none' -ForEach @(
        @{ Recorded = '2026-10-25'; Expected = [datetime]'2026-10-25' }
        @{ Recorded = $null; Expected = $null }
    ) {
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Marker = 'Pending'; FirstOpened = $Recorded; OpenedOnce = $true; DevenvRunning = $false } }
        $vm = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }

        $state = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-GuestVisualStudioSettingState -VM $VM -InstanceId 'a1b2c3d4' }

        $state.FirstOpened | Should -Be $Expected
        $state.Marker | Should -Be 'Pending'
    }
}

Describe 'Update-GuestVisualStudioSetting (#266)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        $vs = [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; DevEnvPath = 'C:\VS\devenv.exe'; InstanceId = 'a1b2c3d4' }
        $toApply = [pscustomobject]@{ Text = '<UserSettings/>'; HasBackup = $true; BackupHash = 'HASH'; ProjectsLocation = 'W:\source\repos' }
        Mock -ModuleName $module Get-VisualStudioSettingTarget { [pscustomobject]@{ VisualStudio = $vs; Settings = $toApply } }
        $guest = @{ Marker = 'Pending'; FirstOpened = [datetime]'2026-10-30'; OpenedOnce = $true; DevenvRunning = $false }
        Mock -ModuleName $module Get-GuestVisualStudioSettingState { [pscustomobject]$guest }
        Mock -ModuleName $module Get-GuestSignedInUser { @('devadmin') }
        Mock -ModuleName $module Get-Date { [datetime]'2026-11-01T02:30:00' }
        Mock -ModuleName $module Write-VisualStudioSettingMarker { }
        Mock -ModuleName $module Write-VisualStudioSettingFirstOpened { }
        Mock -ModuleName $module Import-GuestVisualStudioSetting { }
        $vmSettings = $settings.Clone()
        $vmSettings.GuestAdminUser = 'devadmin'
        $update = { InModuleScope $module -Parameters @{ Settings = $vmSettings } { param($Settings) Update-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) } }
    }

    It 'applies the settings when they are pending, Visual Studio has been opened once, its user is signed in and it is closed' {
        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 1 -Exactly -ParameterFilter { $VisualStudio.InstanceId -eq 'a1b2c3d4' -and $Settings.BackupHash -eq 'HASH' }
    }

    It 'does nothing more once the guest records settings as applied, whatever their hash' -ForEach @(
        @{ Marker = 'HASH' }
        @{ Marker = 'OLDHASH' }
    ) {
        $guest.Marker = $Marker

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*applied already*' }
    }

    It 'applies the settings in a VM built before the guest recorded them, as when they are pending' {
        $guest.Marker = $null

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 1 -Exactly
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 0 -Exactly
    }

    It 'records tonight as the night Visual Studio was first found opened, and applies the settings' {
        $guest.FirstOpened = $null

        & $update

        Should -Invoke -ModuleName $module Write-VisualStudioSettingFirstOpened -Times 1 -Exactly -ParameterFilter { $InstanceId -eq 'a1b2c3d4' -and $Date -eq [datetime]'2026-11-01' }
        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 1 -Exactly
    }

    It 'keeps the night Visual Studio was first found opened once it records one' {
        & $update

        Should -Invoke -ModuleName $module Write-VisualStudioSettingFirstOpened -Times 0 -Exactly
    }

    It 'records no first night until Visual Studio has been opened' {
        $guest.OpenedOnce = $false
        $guest.FirstOpened = $null

        & $update

        Should -Invoke -ModuleName $module Write-VisualStudioSettingFirstOpened -Times 0 -Exactly
    }

    It 'still tries on the seventh night since Visual Studio was first found opened' {
        $guest.FirstOpened = [datetime]'2026-10-26'

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 1 -Exactly
    }

    It 'gives up after seven nights: keeps the settings Visual Studio has, records them as applied, and says why once, whatever else it waits for' -ForEach @(
        @{ Waiting = 'nothing'; SignedIn = @('devadmin'); DevenvRunning = $false }
        @{ Waiting = 'its user to sign in'; SignedIn = @(); DevenvRunning = $false }
        @{ Waiting = 'Visual Studio to close'; SignedIn = @('devadmin'); DevenvRunning = $true }
    ) {
        $guest.FirstOpened = [datetime]'2026-10-25'
        $guest.DevenvRunning = $DevenvRunning
        Mock -ModuleName $module Get-GuestSignedInUser { $SignedIn }

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 1 -Exactly -ParameterFilter { $InstanceId -eq 'a1b2c3d4' -and $AppliedHash -eq 'HASH' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*7 nights*2026-10-25*keep*capture*' }
    }

    It 'waits for Visual Studio''s first launch' {
        $guest.OpenedOnce = $false

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*waiting for*first launch*' }
    }

    It 'waits while its user is not signed in' {
        Mock -ModuleName $module Get-GuestSignedInUser { @() }

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like "*'devadmin' is not signed in*" }
    }

    It 'leaves an open Visual Studio alone' {
        $guest.DevenvRunning = $true

        & $update

        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 0 -Exactly
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*Visual Studio is open*' }
    }

    It 'does nothing when there is nothing to apply or nothing to apply it to' {
        Mock -ModuleName $module Get-VisualStudioSettingTarget { $null }

        & $update

        Should -Invoke -ModuleName $module Get-GuestVisualStudioSettingState -Times 0 -Exactly
        Should -Invoke -ModuleName $module Import-GuestVisualStudioSetting -Times 0 -Exactly
    }
}

Describe 'Save-GuestVisualStudioState and the settings still to be applied (#266)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Get-GuestVisualStudio { [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; Version = '18.0'; ProductLine = '2026'; InstanceId = 'a1b2c3d4' } }
        $guest = @{ Marker = 'Pending' }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Settings = 'C:\Users\devadmin\CurrentSettings.vssettings'; NuGetConfig = $null; GitConfig = $null; UserItems = $null; SettingsMarker = $guest.Marker; Notes = @() } }
        Mock -ModuleName $module Copy-FromGuest { $null = New-Item -ItemType Directory -Path (Split-Path -Path $HostPath -Parent) -Force; Set-Content -LiteralPath $HostPath -Value '<UserSettings><Category name="Defaults"/></UserSettings>' }
        Mock -ModuleName $module Write-VisualStudioSettingMarker { }
        $vmSettings = $settings.Clone()
        $vmSettings.UseDevDrive = $false
        $vmSettings.VSSettingsBackup = Join-Path $TestDrive 'VisualStudio.vssettings'
        Set-Content -LiteralPath $vmSettings.VSSettingsBackup -Value '<UserSettings><Category name="FromTheOldVM"/></UserSettings>'
        $captureDir = Join-Path $TestDrive 'capture'
        $capture = { InModuleScope $module -Parameters @{ Settings = $vmSettings; CaptureDir = $captureDir } { param($Settings, $CaptureDir) $null = Save-GuestVisualStudioState -VM ([VMContext]::new($Settings)) -CaptureDir $CaptureDir } }
    }

    It 'keeps the settings backup while the guest records it as pending, so a new install''s defaults never replace it' {
        & $capture

        Get-Content -LiteralPath $vmSettings.VSSettingsBackup -Raw | Should -BeLike '*FromTheOldVM*'
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 0 -Exactly
    }

    It 'keeps the settings backup in a VM built before the guest recorded it, which nightly maintenance applies first' {
        $guest.Marker = $null

        & $capture

        Get-Content -LiteralPath $vmSettings.VSSettingsBackup -Raw | Should -BeLike '*FromTheOldVM*'
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 0 -Exactly
    }

    It 'refreshes the settings backup from the guest and records it as applied there, once the guest has its settings' {
        $guest.Marker = 'OLDHASH'

        & $capture

        Get-Content -LiteralPath $vmSettings.VSSettingsBackup -Raw | Should -BeLike '*Defaults*'
        $refreshed = (Get-FileHash -LiteralPath $vmSettings.VSSettingsBackup -Algorithm SHA256).Hash
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 1 -Exactly -ParameterFilter { $InstanceId -eq 'a1b2c3d4' -and $AppliedHash -eq $refreshed }
    }

    It 'warns, and records nothing, when the settings backup cannot be refreshed' {
        $guest.Marker = 'OLDHASH'
        $vmSettings.VSSettingsBackup = Join-Path $TestDrive 'no-such-folder\VisualStudio.vssettings'

        & $capture

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -like '*could not refresh the Visual Studio settings backup*' -and $Level -eq 'WARN' }
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 0 -Exactly
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

Describe 'Visual Studio only when VM.json says so (#221)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        # The boundary each Visual Studio step reaches when it runs.
        Mock -ModuleName $module Get-GuestVisualStudio { throw 'stop here' }
        Mock -ModuleName $module Read-VMTooling { $null }
    }

    It '<Step> reaches Get-GuestVisualStudio only when InstallVisualStudio is <Install>' -ForEach @(
        foreach ($install in $true, $false) {
            @{ Step = 'Restore-GuestVisualStudioSetting'; Extra = @{}; Install = $install }
            @{ Step = 'Update-GuestVisualStudioSetting'; Extra = @{}; Install = $install }
            @{ Step = 'Save-GuestVisualStudioState'; Extra = @{ CaptureDir = 'D:\State\Captures\1' }; Install = $install }
            @{ Step = 'Restore-GuestVisualStudioState'; Extra = @{ Manifest = 'with Visual Studio' }; Install = $install }
            @{ Step = 'Get-GuestStateFingerprint'; Extra = @{}; Install = $install }
        }
    ) {
        $vmSettings = $settings.Clone()
        $vmSettings.InstallVisualStudio = $Install
        $vmSettings.UseDevDrive = $true
        $vmSettings.DevDriveLetter = 'W'
        $vmSettings.VSSettingsBackup = Join-Path $TestDrive 'missing.vssettings'
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ Thumbprints = @(); VisualStudioSettingsHash = '' } }

        try {
            InModuleScope $module -Parameters @{ Settings = $vmSettings; Step = $Step; Extra = $Extra } {
                param($Settings, $Step, $Extra)
                $arguments = @{ VM = [VMContext]::new($Settings) }
                foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
                if ($arguments.ContainsKey('Manifest')) {
                    $arguments.Manifest = [CaptureManifest]::new()
                    $arguments.Manifest.VisualStudio = [pscustomobject]@{ Files = @{} }
                }
                & $Step @arguments
            }
        }
        catch { $null = $_ }

        Should -Invoke -ModuleName $module Get-GuestVisualStudio -Times ([int]$Install) -Exactly
    }

    It 'builds from a tooling list <Outcome> when InstallVisualStudio is <Install>' -ForEach @(
        @{ Install = $true; Outcome = 'with Visual Studio and SSMS'; Expected = @('Microsoft.VisualStudio.Product.Community', 'Microsoft.VisualStudio.Product.Ssms') }
        @{ Install = $false; Outcome = 'with SSMS but not Visual Studio'; Expected = @('Microsoft.VisualStudio.Product.Ssms') }
    ) {
        $vmSettings = $settings.Clone()
        $vmSettings.InstallVisualStudio = $Install
        $vmSettings.Tooling = @{
            Products = @(
                @{ ProductId = 'Microsoft.VisualStudio.Product.Community'; ChannelId = 'VisualStudio.18.Release' }
                @{ ProductId = 'Microsoft.VisualStudio.Product.Ssms'; ChannelId = 'SSMS.22.SSMS.Release' }
            )
        }

        $products = @(InModuleScope $module -Parameters @{ Settings = $vmSettings } {
                param($Settings)
                (Get-BuildTooling -VM ([VMContext]::new($Settings))).Products | ForEach-Object { $_.ProductId }
            })

        $products | Should -Be $Expected
    }
}
