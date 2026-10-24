# VisualStudio.ps1 - Visual Studio Installer products: finding, installing, settings.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Visual Studio Installer manages Visual Studio of any edition and
# version, and also SSMS 21 and later. Each product in the tooling list is
# installed from its own channel's bootstrapper with its recorded workloads,
# components and extensions.

function Get-GuestInstallerProduct {
    <# Every product the Visual Studio Installer manages in the guest. Throws when the guest cannot be asked. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return @(Invoke-GuestScript -VM $VM -Activity 'Visual Studio Installer product detection' -TimeoutMinutes 5 -ScriptBlock {
            foreach ($instance in @(Get-GuestInstallerInstance)) {
                [pscustomobject]@{
                    InstanceId  = $instance.instanceId
                    ProductId   = $instance.productId
                    ChannelId   = $instance.channelId
                    DisplayName = $instance.displayName
                    Version     = $instance.installationVersion
                    ProductLine = $instance.catalog.productLineVersion
                    InstallPath = $instance.installationPath
                    DevEnvPath  = $instance.productPath
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

    $products = @(Get-GuestInstallerProduct -VM $VM | Where-Object { $_.ProductId -notlike '*.Ssms' })
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

function Test-UnsignedExtensionAllowed {
    <#
      True when one of these Marketplace links is for an extension the
      UnsignedExtensions setting lets the installer take unsigned. Only then
      is --allowUnsignedExtensions passed, so an unsigned extension never
      gets in without someone having decided it may.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Links = @(),
        [AllowEmptyCollection()][string[]]$Allowed = @()
    )

    foreach ($link in $Links) {
        $item = ($link -split 'itemName=', 2)[-1]
        if ($Allowed -contains $item) { return $true }
    }
    return $false
}

function ConvertTo-VsConfig {
    <# The .vsconfig the Visual Studio Installer takes: the product's components and these extension links. #>
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
      the guest does not have yet. A product already there gets any of its
      Marketplace extensions it is missing. Extensions go in the .vsconfig as
      Marketplace links, which the installer installs for all users. Per-user
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
        if ($present) {
            Write-LogEntry "$label already installed" 'OK'
            if ($product.ExtensionLinks().Count -gt 0) {
                if (-not $observed) { $observed = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude }
                $links = @(Get-MissingProductExtension -Product $product -Observed $observed.FindProduct($product.Key()) | Where-Object { $_.Link } | ForEach-Object { $_.Link })
                if ($links.Count -gt 0) { Add-ProductExtension -VM $VM -Product $product -InstallPath $present.InstallPath -Links $links }
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
        Write-LogEntry "Installing $label from $url ($(@($product.Components).Count) workload/component id(s), $($extensions.Count) extension(s); up to $($VM.Settings.VSInstallMinutes) minutes)..." 'INFO'
        try {
            $prepared = Invoke-GuestScript -VM $VM -Activity "$label download" -TimeoutMinutes 15 `
                -ArgumentList @($url, "bootstrap-$edition.exe", $VM.Settings.GuestSetupDir, (ConvertTo-VsConfig -Product $product -Links $extensions), $product.IncludeRecommended, (Test-UnsignedExtensionAllowed -Links $extensions -Allowed $VM.Settings.UnsignedExtensions)) -ScriptBlock {
                param($url, $bootstrapperName, $setupDir, $configJson, $includeRecommended, $allowUnsigned)
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
                # Only for extensions listed in UnsignedExtensions.
                if ($allowUnsigned) { $arguments += '--allowUnsignedExtensions' }
                return [pscustomobject]@{ FilePath = $bootstrapper; Arguments = $arguments }
            }
            $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $prepared.FilePath -ArgumentList $prepared.Arguments `
                -Name "install-$edition" -TimeoutMinutes $VM.Settings.VSInstallMinutes -Activity "the $label install"
            if (-not (Test-InstallExitCode -Product $label -ExitCode $exitCode)) {
                Write-LogEntry '  Guest log: C:\Windows\Temp\dd_bootstrapper_*.log and dd_setup_*.log' 'INFO'
            }
        }
        catch {
            Write-LogError "$label install failed" $_
        }
    }
}

function Add-ProductExtension {
    <#
      Adds Marketplace extensions to a product that is already installed, for
      all users, with the Visual Studio Installer's modify command: for a
      product installed before its extensions were in the tooling list, or
      whose first install stopped before they went in.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingProduct]$Product,
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string[]]$Links
    )

    $label = $Product.DisplayName
    Write-LogEntry "Adding $($Links.Count) extension(s) to $label..." 'INFO'
    try {
        $prepared = Invoke-GuestScript -VM $VM -Activity "$label extension list" -TimeoutMinutes 5 `
            -ArgumentList @($VM.Settings.GuestSetupDir, (ConvertTo-VsConfig -Product $Product -Links $Links), $InstallPath, (Test-UnsignedExtensionAllowed -Links $Links -Allowed $VM.Settings.UnsignedExtensions)) -ScriptBlock {
            param($setupDir, $configJson, $installPath, $allowUnsigned)
            $ErrorActionPreference = 'Stop'
            New-GuestFolder -Path $setupDir
            $configPath = Join-Path $setupDir 'extensions.vsconfig'
            [IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
            $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
            if (-not (Test-Path $installer)) { throw 'the Visual Studio Installer is not in the guest' }
            $arguments = @('modify', '--installPath', "`"$installPath`"", '--config', "`"$configPath`"", '--quiet', '--norestart')
            # Only for extensions listed in UnsignedExtensions.
            if ($allowUnsigned) { $arguments += '--allowUnsignedExtensions' }
            return [pscustomobject]@{ FilePath = $installer; Arguments = $arguments }
        }
        $exitCode = Invoke-GuestInstaller -VM $VM -FilePath $prepared.FilePath -ArgumentList $prepared.Arguments `
            -Name 'add-extensions' -TimeoutMinutes 60 -Activity "adding extensions to $label"
        $null = Test-InstallExitCode -Product "$label extensions" -ExitCode $exitCode
    }
    catch {
        Write-LogError "Adding extensions to $label failed" $_
    }
}

function Restore-GuestVisualStudioSetting {
    <#
      Applies the Visual Studio settings in VSSettingsBackup, which a capture
      refreshes, in the guest user's desktop session: the settings store is
      per-user, and devenv needs a real session to write it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $backup = $VM.Settings.VSSettingsBackup
    if (-not (Test-Path -LiteralPath $backup)) {
        Write-LogEntry "No Visual Studio settings backup at $backup - skipping" 'INFO'
        Write-LogEntry '  A capture saves one, or export one: Visual Studio -> Tools -> Import and Export Settings -> Export all settings' 'INFO'
        return
    }

    $vs = Get-GuestVisualStudio -VM $VM
    if (-not $vs) {
        Write-LogEntry 'Visual Studio is not installed in the guest - skipping the settings restore' 'WARN'
        return
    }
    Write-LogEntry "Found $($vs.DisplayName) at $($vs.DevEnvPath)" 'INFO'

    $guestPath = Join-Path $VM.Settings.GuestSetupDir 'VisualStudio.vssettings'
    Copy-ToGuest -VM $VM -HostPath $backup -GuestPath $guestPath

    Invoke-GuestScriptAsInteractiveUser -VM $VM -TaskName "${script:TaskPrefix}VSSettings" -Activity 'Visual Studio settings restore' -TimeoutMinutes 25 `
        -ArgumentList @($vs.DevEnvPath, $guestPath) -ScriptBlock {
        param($devenv, $settingsPath)
        if (-not (Test-Path $devenv)) { throw "devenv.exe not found at $devenv" }
        $process = Start-Process -FilePath $devenv -ArgumentList '/NoSplash', '/ResetSettings', "`"$settingsPath`"", '/Command', 'Exit' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "devenv exited with $($process.ExitCode)" }
    }
    Write-LogEntry 'Visual Studio settings restored' 'OK'
}
