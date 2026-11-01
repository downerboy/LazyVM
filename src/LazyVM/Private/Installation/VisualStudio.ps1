# VisualStudio.ps1 - Visual Studio Installer products: finding, installing, settings.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Visual Studio Installer manages Visual Studio of any edition and
# version, and also SSMS 21 and later. Each product in the tooling list is
# installed from its own channel's bootstrapper with its recorded workloads
# and components. Its extensions are added afterwards, in a step of their
# own: the installer refuses a whole install when any one extension in it is
# unsigned, and one theme must never cost the product itself (#109).

# Where the installer's own logs are. It runs as SYSTEM, whose temporary
# folder is C:\Windows\SystemTemp from Windows 11 24H2.
$script:GuestInstallerLogHint = 'Guest log: C:\Windows\SystemTemp\dd_*.log (C:\Windows\Temp before Windows 11 24H2)'

# What the guest records for a Visual Studio whose settings LazyVM has started
# to apply but devenv has not yet applied; once it has, the guest records the
# settings backup's hash instead (Write-VisualStudioSettingMarker, #266).
# Used only by Write-VisualStudioSettingMarker and Test-VisualStudioSettingPending.
$script:VisualStudioSettingPending = 'Pending'

function Get-GuestInstallerProduct {
    <# Every product the Visual Studio Installer manages in the guest. Throws when the guest cannot be asked. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return @(Invoke-GuestScript -VM $VM -Activity 'Visual Studio Installer product detection' -TimeoutMinutes 5 -ScriptBlock {
            foreach ($instance in @(Get-GuestInstallerInstance)) {
                [pscustomobject]@{
                    InstanceId   = $instance.instanceId
                    ProductId    = $instance.productId
                    ChannelId    = $instance.channelId
                    DisplayName  = $instance.displayName
                    Version      = $instance.installationVersion
                    ProductLine  = $instance.catalog.productLineVersion
                    InstallPath  = $instance.installationPath
                    DevEnvPath   = $instance.productPath
                    IsComplete   = $instance.isComplete
                    IsLaunchable = $instance.isLaunchable
                }
            }
        })
}

function Get-GuestVisualStudio {
    <#
      The newest Visual Studio of any edition and version, or $null. SSMS is
      left out: vswhere lists it beside Visual Studio, and taking it for
      Visual Studio would skip the Visual Studio install.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $products = @(Get-GuestInstallerProduct -VM $VM | Where-Object { [ToolingProduct]::IsVisualStudio($_.ProductId) })
    if ($products.Count -eq 0) { return $null }
    return ($products | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
}

function Get-ProductBootstrapperUrl {
    <#
      The bootstrapper for a product's channel, from InstallerBootstrappers,
      or $null. {edition} becomes the product's edition:
      Microsoft.VisualStudio.Product.Community -> vs_community.exe.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bootstrappers,
        [Parameter(Mandatory)][ToolingProduct]$Product
    )

    $key = @($Bootstrappers.Keys) | Where-Object { $_ -eq $Product.ChannelId } | Select-Object -First 1
    if (-not $key) { return $null }
    return ("$($Bootstrappers[$key])" -replace '\{edition\}', $Product.Edition())
}

function Get-MissingProductExtension {
    <#
      The extensions a product in the tooling list has that the guest's copy
      of it lacks: each as @{ Id; DisplayName; Publisher; Link }, Link being
      its Marketplace link, or $null when it has none. $Observed is the
      matching product from the guest's tooling record, or $null.
    #>
    param(
        [Parameter(Mandatory)][ToolingProduct]$Product,
        [AllowNull()][ToolingProduct]$Observed
    )

    $nowLinks = if ($Observed) { @($Observed.Extensions) } else { @() }
    $nowIds = if ($Observed) { @($Observed.UserExtensions | ForEach-Object { $_.Id }) } else { @() }

    $missing = @()
    foreach ($link in @($Product.Extensions | Where-Object { $_ })) {
        if ($nowLinks -notcontains $link) { $missing += @{ Id = $null; DisplayName = $link; Publisher = $null; Link = $link } }
    }
    foreach ($extension in @($Product.UserExtensions)) {
        if ($nowIds -contains $extension.Id) { continue }
        $link = $extension.Link()
        if ($link -and $nowLinks -contains $link) { continue }
        $missing += @{ Id = $extension.Id; DisplayName = $extension.DisplayName; Publisher = $extension.Publisher; Link = $link }
    }
    return $missing
}

function Get-ExtensionItemName {
    <# A Marketplace link's item name, Publisher.Name: the part after itemName=. #>
    param([Parameter(Mandatory)][string]$Link)

    return ($Link -split 'itemName=', 2)[-1]
}

function Test-UnsignedExtensionAllowed {
    <#
      True when one of these Marketplace links is for an extension the
      UnsignedExtensions setting lets the installer take unsigned.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Links = @(),
        [AllowEmptyCollection()][string[]]$Allowed = @()
    )

    foreach ($link in $Links) {
        if ($Allowed -contains (Get-ExtensionItemName -Link $link)) { return $true }
    }
    return $false
}

function ConvertTo-VsConfig {
    <# The .vsconfig the Visual Studio Installer takes: the product's components and, for a modify, these extension links. #>
    param(
        [Parameter(Mandatory)][ToolingProduct]$Product,
        [AllowEmptyCollection()][string[]]$Links = @()
    )

    $config = [ordered]@{ version = '1.0'; components = @($Product.Components) }
    if ($Links.Count -gt 0) { $config['extensions'] = @($Links) }
    return $config | ConvertTo-Json -Depth 4
}

function Install-ToolingProduct {
    <#
      Installs each Visual Studio Installer product in the tooling list that
      the guest does not have yet, with its workloads and components, then
      adds its Marketplace extensions (Add-ProductExtension). A product
      already there gets any of its extensions it is missing, after a repair
      when an interrupted install left it incomplete. Per-user
      extensions with no Marketplace link are reported afterwards by
      Write-ToolingReinstallReport.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingRecord]$Tooling
    )

    try { $installed = @(Get-GuestInstallerProduct -VM $VM) }
    catch {
        Write-LogError 'Could not tell which Visual Studio Installer products the guest has, so none were installed' $_
        return
    }

    $observed = $null
    foreach ($product in @($Tooling.Products)) {
        $label = $product.DisplayName
        $present = $installed | Where-Object { [ToolingProduct]::KeyFor($_.ProductId, $_.ChannelId) -eq $product.Key() } | Select-Object -First 1
        if ($present -and -not (Test-InstallerProductComplete -Product $present)) {
            if (-not (Repair-ToolingProduct -VM $VM -Product $product -InstallPath $present.InstallPath)) { continue }
        }
        elseif ($present) { Write-LogEntry "$label already installed" 'OK' }
        if ($present) {
            if ($product.ExtensionLinks().Count -gt 0) {
                if (-not $observed) { $observed = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude }
                $links = @(Get-MissingProductExtension -Product $product -Observed $observed.FindProduct($product.Key()) | Where-Object { $_.Link } | ForEach-Object { $_.Link })
                if ($links.Count -gt 0) { $null = Add-ProductExtension -VM $VM -Product $product -InstallPath $present.InstallPath -Links $links }
            }
            continue
        }

        $url = Get-ProductBootstrapperUrl -Bootstrappers $VM.Settings.InstallerBootstrappers -Product $product
        if (-not $url) {
            Write-LogEntry "$label - no bootstrapper is known for channel '$($product.ChannelId)'; add one to InstallerBootstrappers" 'ERROR'
            continue
        }

        $extensions = $product.ExtensionLinks()
        $edition = $product.Edition()
        Write-LogEntry "Installing $label from $url ($(@($product.Components).Count) workload/component id(s); up to $($VM.Settings.VSInstallMinutes) minutes)..." 'INFO'
        try {
            $prepared = Invoke-GuestScript -VM $VM -Activity "$label download" -TimeoutMinutes 15 `
                -ArgumentList @($url, "bootstrap-$edition.exe", $VM.Settings.GuestSetupDir, (ConvertTo-VsConfig -Product $product), $product.IncludeRecommended) -ScriptBlock {
                param($url, $bootstrapperName, $setupDir, $configJson, $includeRecommended)
                $ErrorActionPreference = 'Stop'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                New-GuestFolder -Path $setupDir

                $bootstrapper = Join-Path $setupDir $bootstrapperName
                Invoke-WebRequest -Uri $url -OutFile $bootstrapper -UseBasicParsing -TimeoutSec 600

                # Without a byte-order mark: the installer reads it as JSON.
                $configPath = Join-Path $setupDir "$bootstrapperName.vsconfig"
                [IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))

                $arguments = @('--quiet', '--wait', '--norestart', '--config', "`"$configPath`"")
                if ($includeRecommended) { $arguments += '--includeRecommended' }
                return [pscustomobject]@{ FilePath = $bootstrapper; Arguments = $arguments }
            }
            $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $prepared.FilePath -ArgumentList $prepared.Arguments `
                -Name "install-$edition" -TimeoutMinutes $VM.Settings.VSInstallMinutes -Activity "the $label install"
            if (-not (Test-InstallExitCode -Product $label -ExitCode $exitCode)) {
                Write-LogEntry "  $script:GuestInstallerLogHint" 'INFO'
                continue
            }
        }
        catch {
            Write-LogError "$label install failed" $_
            continue
        }

        if ($extensions.Count -eq 0) { continue }
        try {
            $added = Get-GuestInstallerProduct -VM $VM | Where-Object { [ToolingProduct]::KeyFor($_.ProductId, $_.ChannelId) -eq $product.Key() } | Select-Object -First 1
        }
        catch {
            Write-LogError "Could not find $label after its install, so its extensions were not added" $_
            continue
        }
        if (-not $added) {
            Write-LogEntry "$label is not listed by the installer after its install, so its extensions were not added" 'WARN'
            continue
        }
        $null = Add-ProductExtension -VM $VM -Product $product -InstallPath $added.InstallPath -Links $extensions
    }
}

function Test-InstallerProductComplete {
    <#
      Whether a product the installer lists is fully installed. An
      interrupted install leaves an instance vswhere still lists, with
      isComplete or isLaunchable false (#26); a flag vswhere did not report
      counts as true.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Product)

    return ($Product.IsComplete -ne $false -and $Product.IsLaunchable -ne $false)
}

function Repair-ToolingProduct {
    <#
      Repairs an incomplete product in place with the Visual Studio
      Installer's repair command, which finishes an interrupted install.
      Returns whether the installer succeeded, and logs the result.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingProduct]$Product,
        [Parameter(Mandatory)][string]$InstallPath
    )

    $label = $Product.DisplayName
    Write-LogEntry "$label is incomplete at $InstallPath, so it is being repaired (up to $($VM.Settings.VSInstallMinutes) minutes)..." 'WARN'
    try {
        $installer = Invoke-GuestScript -VM $VM -Activity "$label repair" -TimeoutMinutes 5 -ScriptBlock {
            $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
            if (-not (Test-Path $installer)) { throw 'the Visual Studio Installer is not in the guest' }
            return $installer
        }
        $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $installer -ArgumentList @('repair', '--installPath', "`"$InstallPath`"", '--quiet', '--norestart') `
            -Name "repair-$($Product.Edition())" -TimeoutMinutes $VM.Settings.VSInstallMinutes -Activity "the $label repair"
        if (Test-InstallExitCode -Product $label -ExitCode $exitCode) { return $true }
        Write-LogEntry "  $script:GuestInstallerLogHint" 'INFO'
        return $false
    }
    catch {
        Write-LogError "$label repair failed" $_
        return $false
    }
}

function Add-ProductExtension {
    <#
      Adds Marketplace extensions to a product that is already installed, for
      all users, with the Visual Studio Installer's modify command. Returns
      the links of the extensions the installer refused, and logs them.

      The installer refuses a whole batch when one extension in it is
      unsigned, and --allowUnsignedExtensions lets every unsigned extension in
      a batch in. So the extensions listed in UnsignedExtensions go in a batch
      of their own, the only one given that switch, and a refused batch is
      tried again one extension at a time: the rest still go in, and each
      refused extension is named.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingProduct]$Product,
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string[]]$Links
    )

    $label = $Product.DisplayName
    Write-LogEntry "Adding $($Links.Count) extension(s) to $label..." 'INFO'

    $allowed = @($VM.Settings.UnsignedExtensions)
    $batches = @(
        @{ AllowUnsigned = $true; Links = @($Links | Where-Object { Test-UnsignedExtensionAllowed -Links @($_) -Allowed $allowed }) }
        @{ AllowUnsigned = $false; Links = @($Links | Where-Object { -not (Test-UnsignedExtensionAllowed -Links @($_) -Allowed $allowed) }) }
    )
    $refused = [System.Collections.Generic.List[string]]::new()
    foreach ($batch in $batches) {
        if ($batch.Links.Count -eq 0) { continue }
        if (Invoke-ProductModify -VM $VM -Product $Product -InstallPath $InstallPath -Links $batch.Links -AllowUnsigned:$batch.AllowUnsigned) { continue }
        if ($batch.Links.Count -eq 1) { $refused.Add($batch.Links[0]); continue }

        Write-LogEntry "  The installer refused $($batch.Links.Count) extension(s) together; adding them one at a time..." 'INFO'
        foreach ($link in $batch.Links) {
            if (-not (Invoke-ProductModify -VM $VM -Product $Product -InstallPath $InstallPath -Links @($link) -AllowUnsigned:$batch.AllowUnsigned)) { $refused.Add($link) }
        }
    }

    $count = $Links.Count - $refused.Count
    if ($refused.Count -eq 0) {
        Write-LogEntry "$label - $count extension(s) added" 'OK'
        return @()
    }
    if ($count -gt 0) { Write-LogEntry "$label - $count extension(s) added" 'OK' }
    Write-LogList -Heading "$label - $($refused.Count) extension(s) refused by the Visual Studio Installer:" -Items @($refused | ForEach-Object { Get-ExtensionItemName -Link $_ }) -Level WARN
    Write-LogEntry '  An unsigned extension is installed only when its item name is in the UnsignedExtensions setting; otherwise install it by hand from Extensions > Manage Extensions.' 'INFO'
    Write-LogEntry "  $script:GuestInstallerLogHint" 'INFO'
    return @($refused)
}

function Invoke-ProductModify {
    <#
      One modify of an installed product, adding these extension links, with
      --allowUnsignedExtensions only when -AllowUnsigned is given. Returns
      whether the installer succeeded; a failure is the caller's to report.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingProduct]$Product,
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string[]]$Links,
        [switch]$AllowUnsigned
    )

    $label = $Product.DisplayName
    try {
        $prepared = Invoke-GuestScript -VM $VM -Activity "$label extension list" -TimeoutMinutes 5 `
            -ArgumentList @($VM.Settings.GuestSetupDir, (ConvertTo-VsConfig -Product $Product -Links $Links), $InstallPath, [bool]$AllowUnsigned) -ScriptBlock {
            param($setupDir, $configJson, $installPath, $allowUnsigned)
            $ErrorActionPreference = 'Stop'
            New-GuestFolder -Path $setupDir
            $configPath = Join-Path $setupDir 'extensions.vsconfig'
            [IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
            $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
            if (-not (Test-Path $installer)) { throw 'the Visual Studio Installer is not in the guest' }
            $arguments = @('modify', '--installPath', "`"$installPath`"", '--config', "`"$configPath`"", '--quiet', '--norestart')
            if ($allowUnsigned) { $arguments += '--allowUnsignedExtensions' }
            return [pscustomobject]@{ FilePath = $installer; Arguments = $arguments }
        }
        $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $prepared.FilePath -ArgumentList $prepared.Arguments `
            -Name 'add-extensions' -TimeoutMinutes 60 -Activity "adding extensions to $label"
        return (Test-InstallSucceeded -ExitCode $exitCode)
    }
    catch {
        Write-LogError "Adding extensions to $label failed" $_
        return $false
    }
}

function ConvertTo-ProjectsLocationSetting {
    <#
      A .vssettings file's text with Visual Studio's projects location
      (Projects and Solutions > Locations) set to $Path. With no $Settings,
      the file holds that one setting.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Settings = '',
        [Parameter(Mandatory)][string]$Path
    )

    $document = [xml]$(if ($Settings) { $Settings } else { '<UserSettings/>' })
    $parent = $document.DocumentElement
    foreach ($step in @(
            @{ Element = 'ToolsOptions'; Attributes = [ordered]@{} }
            @{ Element = 'ToolsOptionsCategory'; Attributes = [ordered]@{ name = 'Environment'; RegisteredName = 'Environment' } }
            @{ Element = 'ToolsOptionsSubCategory'; Attributes = [ordered]@{ name = 'ProjectsAndSolution'; RegisteredName = 'ProjectsAndSolution'; PackageName = 'Visual Studio Environment Package' } }
            @{ Element = 'PropertyValue'; Attributes = [ordered]@{ name = 'ProjectsLocation' } }
        )) {
        $node = $parent.ChildNodes | Where-Object { $_.LocalName -eq $step.Element -and (-not $step.Attributes.Contains('name') -or $_.GetAttribute('name') -eq $step.Attributes['name']) } | Select-Object -First 1
        if (-not $node) {
            $node = $parent.AppendChild($document.CreateElement($step.Element))
            foreach ($attribute in $step.Attributes.GetEnumerator()) { $node.SetAttribute($attribute.Key, $attribute.Value) }
        }
        $parent = $node
    }
    $parent.InnerText = $Path
    return $document.OuterXml
}

function Get-VisualStudioSettingToApply {
    <#
      The Visual Studio settings the settings restore applies, as
      @{ Text; HasBackup; BackupHash; ProjectsLocation }, or $null when there
      are none: the settings backup (VSSettingsBackup) with, on a Dev Drive,
      the projects location (ProjectsLocation, otherwise $null) pointed at
      source\repos on it (#176). With no backup (HasBackup false), Text holds
      only that setting. BackupHash, the SHA256 of the backup file as it is
      (of no bytes when there is none), is what the guest records once the
      settings are applied (#266). It is a record only: Text depends on the
      Dev Drive's letter in this run, the backup does not.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $backup = $VM.Settings.VSSettingsBackup
    $hasBackup = Test-Path -LiteralPath $backup
    $text = if ($hasBackup) { Get-Content -LiteralPath $backup -Raw } else { '' }
    $projects = $null
    if ($VM.Settings.UseDevDrive) {
        $projects = "$($VM.Runtime.DevDriveLetter):\source\repos"
        $text = ConvertTo-ProjectsLocationSetting -Settings $text -Path $projects
    }
    if (-not $text) { return $null }
    $bytes = [byte[]]::new(0)
    if ($hasBackup) { $bytes = [IO.File]::ReadAllBytes((Convert-Path -LiteralPath $backup)) }
    return [pscustomobject]@{
        Text             = $text
        HasBackup        = $hasBackup
        BackupHash       = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        ProjectsLocation = $projects
    }
}

function Get-VisualStudioSettingTarget {
    <#
      What the settings restore applies and where, as
      @{ VisualStudio; Settings } (Get-GuestVisualStudio,
      Get-VisualStudioSettingToApply), or $null, saying why, when there is
      nothing to apply or nothing to apply it to: Visual Studio turned off in
      the settings, no settings, or no Visual Studio in the guest.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.InstallVisualStudio) {
        Write-LogEntry 'Visual Studio turned off in the settings (InstallVisualStudio) - skipping its settings' 'INFO'
        return $null
    }
    $settings = Get-VisualStudioSettingToApply -VM $VM
    if (-not $settings -or -not $settings.HasBackup) {
        Write-LogEntry "No Visual Studio settings backup at $($VM.Settings.VSSettingsBackup)$(if (-not $settings) { ' - skipping' })" 'INFO'
        Write-LogEntry '  A capture saves one, or export one: Visual Studio -> Tools -> Import and Export Settings -> Export all settings' 'INFO'
        if (-not $settings) { return $null }
    }
    $vs = Get-GuestVisualStudio -VM $VM
    if (-not $vs) {
        Write-LogEntry 'Visual Studio is not installed in the guest - skipping its settings' 'WARN'
        return $null
    }
    Write-LogEntry "Found $($vs.DisplayName) at $($vs.DevEnvPath)" 'INFO'
    return [pscustomobject]@{ VisualStudio = $vs; Settings = $settings }
}

function Test-VisualStudioSettingPending {
    <#
      Whether the guest's record $Marker (Get-GuestVisualStudioSettingMarker)
      says it is still to have its Visual Studio settings applied: a build or
      restore started applying them and devenv has not (#266).
    #>
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Marker)

    return $Marker -eq $script:VisualStudioSettingPending
}

function Write-VisualStudioSettingMarker {
    <#
      Records in the guest what it has of the settings of the Visual Studio
      with instance $InstanceId: -Pending, LazyVM has started to apply them
      and devenv has not yet, or -AppliedHash, the BackupHash of the settings
      it has (#266). Kept per user and per Visual Studio instance, as Visual
      Studio keeps its settings.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Applied')]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory, ParameterSetName = 'Pending')][switch]$Pending,
        [Parameter(Mandatory, ParameterSetName = 'Applied')][string]$AppliedHash
    )

    $value = if ($Pending) { $script:VisualStudioSettingPending } else { $AppliedHash }
    $null = Invoke-GuestScript -VM $VM -Activity 'recording the Visual Studio settings' -TimeoutMinutes 2 -ArgumentList @($InstanceId, $value) -ScriptBlock {
        param($instanceId, $value)
        Set-GuestVisualStudioSettingMarker -InstanceId $instanceId -Value $value
    }
}

function Restore-GuestVisualStudioSetting {
    <#
      Applies the Visual Studio settings in VSSettingsBackup, which a capture
      refreshes (Get-VisualStudioSettingTarget, Import-GuestVisualStudioSetting).
      The guest records them as pending first, so nightly maintenance applies
      them when this fails (#266). On a fresh build Visual Studio's first
      launch is answered first (Complete-GuestVisualStudioFirstLaunch, #268);
      when it cannot be, the import is left to nightly maintenance and the
      build goes on. devenv applies settings only in the guest user's desktop
      session, so this fails at once when they are not signed in.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $target = Get-VisualStudioSettingTarget -VM $VM
    if (-not $target) { return }
    Write-VisualStudioSettingMarker -VM $VM -InstanceId $target.VisualStudio.InstanceId -Pending
    $account = $VM.Runtime.GuestAdminUser
    if (@(Get-GuestSignedInUser -VM $VM) -notcontains $account) {
        throw "'$account' is not signed in to the guest, and devenv applies Visual Studio settings only in their desktop session. The settings import is retried automatically by nightly maintenance"
    }
    if (-not (Complete-GuestVisualStudioFirstLaunch -VM $VM -VisualStudio $target.VisualStudio)) {
        Write-LogEntry '  The Visual Studio settings import is retried automatically by nightly maintenance, once Visual Studio has been opened and closed in the VM' 'WARN'
        return
    }
    Import-GuestVisualStudioSetting -VM $VM -VisualStudio $target.VisualStudio -Settings $target.Settings
}

function Import-GuestVisualStudioSetting {
    <#
      Applies $Settings (Get-VisualStudioSettingToApply) to the Visual Studio
      $VisualStudio (Get-GuestVisualStudio) in the signed-in guest user's
      desktop session, then records them as applied in the guest. The
      settings store is per-user, and devenv /ResetSettings, the only
      documented way to apply a .vssettings file, opens the IDE. devenv gets
      ten minutes ($devenvMinutes) to apply the file and exit; one still open
      then is waiting on a dialog, such as the sign-in and theme choice of
      its first launch, that no one will answer, so it is stopped with
      everything it started (#262). With a Dev Drive, the projects location
      is pointed at source\repos on it, so new projects outlive the Windows
      evaluation (#176); the setting lives on C:, so every restore sets it
      again. With no backup, the file applied holds only that setting, and
      the reset leaves the rest at the defaults a new install has anyway.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][object]$VisualStudio,
        [Parameter(Mandatory)][object]$Settings
    )

    $guestPath = Join-Path $VM.Settings.GuestSetupDir 'VisualStudio.vssettings'
    $staging = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("LazyVM-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Folder -Path $staging
        $staged = Join-Path -Path $staging -ChildPath 'VisualStudio.vssettings'
        [IO.File]::WriteAllText($staged, $Settings.Text, [Text.UTF8Encoding]::new($false))
        Copy-ToGuest -VM $VM -HostPath $staged -GuestPath $guestPath
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    # The guest task gets a few minutes more than devenv, so it is the guest
    # that stops devenv and says why, not the host giving up on the task.
    $devenvMinutes = 10
    $projects = $Settings.ProjectsLocation
    Invoke-GuestScriptAsInteractiveUser -VM $VM -TaskName "${script:TaskPrefix}VSSettings" -Activity 'Visual Studio settings restore' -TimeoutMinutes ($devenvMinutes + 3) `
        -ArgumentList @($VisualStudio.DevEnvPath, $guestPath, $projects, $devenvMinutes) -ScriptBlock {
        param($devenv, $settingsPath, $projects, $devenvMinutes)
        if (-not (Test-Path $devenv)) { throw "devenv.exe not found at $devenv" }
        if ($projects) { $null = New-Item -ItemType Directory -Path $projects -Force }
        $process = Start-Process -FilePath $devenv -ArgumentList '/NoSplash', '/ResetSettings', "`"$settingsPath`"", '/Command', 'Exit' -PassThru
        if (-not $process.WaitForExit($devenvMinutes * 60000)) {
            $null = taskkill.exe /PID $process.Id /T /F
            throw "devenv did not exit within $devenvMinutes minute(s) and was stopped - it was most likely waiting on a dialog, such as the sign-in and theme choice of its first launch. The settings import is retried automatically: nightly maintenance applies them once Visual Studio has been opened and closed in the VM"
        }
        if ($process.ExitCode -ne 0) { throw "devenv exited with $($process.ExitCode)" }
    }
    Write-VisualStudioSettingMarker -VM $VM -InstanceId $VisualStudio.InstanceId -AppliedHash $Settings.BackupHash
    if ($Settings.HasBackup) { Write-LogEntry 'Visual Studio settings restored' 'OK' }
    if ($projects) { Write-LogEntry "Visual Studio creates new projects in $projects, on the Dev Drive" 'OK' }
}
