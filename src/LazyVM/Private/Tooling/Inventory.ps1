# Inventory.ps1 - Inventory of the tooling installed in the guest (Get-LazyVMTooling).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  TOOLING INVENTORY
#
#  Reads what is installed in the guest without changing anything:
#    - every product the Visual Studio Installer manages (Visual Studio of any
#      version and edition, SSMS 21+, Build Tools), each with its exported
#      .vsconfig of workloads and components
#    - Visual Studio extensions, both instance-wide (in the export) and the
#      per-user ones installed from Manage Extensions (read from their
#      manifests, which the export does not include)
#    - winget packages, by identifier and source
#    - every other program in the Windows uninstall list
#
#  Get-LazyVMTooling runs this on its own and saves the result on the host, so the
#  data can be checked before anything is built on it.
# ─────────────────────────────────────────────────────────────────────────────

function Get-GuestToolingInventory {
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'tooling inventory' -TimeoutMinutes 30 `
        -ArgumentList @($VM.Settings.GuestSetupDir, @($VM.Settings.ToolingWingetCheck)) -ScriptBlock {
        param($setupDir, $wingetCheck)
        $ErrorActionPreference = 'Stop'
        New-GuestFolder -Path $setupDir

        $notes = [System.Collections.Generic.List[string]]::new()

        # ── products managed by the Visual Studio Installer ────────────────
        $products = @()
        $vsInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vs_installer.exe'
        $instances = @(Get-GuestInstallerInstance)
        if ($instances.Count -eq 0) { $notes.Add('no Visual Studio Installer products are installed') }
        foreach ($instance in $instances) {
            $product = [ordered]@{
                InstanceId     = $instance.instanceId
                ProductId      = $instance.productId
                ChannelId      = $instance.channelId
                DisplayName    = $instance.displayName
                Version        = $instance.installationVersion
                ProductLine    = $instance.catalog.productLineVersion
                InstallPath    = $instance.installationPath
                IsComplete     = $instance.isComplete
                Components     = @()
                ExportedExtensions = @()
                UserExtensions = @()
            }

            # Workloads, components and instance-wide marketplace extensions,
            # as the installer itself would reproduce them.
            if (Test-Path $vsInstaller) {
                $configPath = Join-Path $setupDir "inventory-$($instance.instanceId).vsconfig"
                Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                $proc = Start-Process -FilePath $vsInstaller -Wait -PassThru -NoNewWindow -ArgumentList @(
                    'export', '--installPath', "`"$($instance.installationPath)`"", '--config', "`"$configPath`"", '--quiet'
                )
                if (Test-Path $configPath) {
                    try {
                        $config = Get-Content $configPath -Raw | ConvertFrom-Json
                        $product.Components = @($config.components)
                        if ($config.PSObject.Properties['extensions']) { $product.ExportedExtensions = @($config.extensions) }
                    }
                    catch { $notes.Add("could not read the exported configuration for $($instance.displayName): $($_.Exception.Message)") }
                    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                }
                else { $notes.Add("export produced no configuration for $($instance.displayName) (exit $($proc.ExitCode))") }
            }

            # Per-user extensions live in a folder named <version>_<instanceId>,
            # which ties each one to its product instance.
            $userRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio'
            $instanceDirs = @(Get-ChildItem -Path $userRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*_$($instance.instanceId)" })
            foreach ($dir in $instanceDirs) {
                $extensionsDir = Join-Path $dir.FullName 'Extensions'
                foreach ($manifestFile in @(Get-ChildItem -Path $extensionsDir -Filter 'extension.vsixmanifest' -Recurse -File -ErrorAction SilentlyContinue)) {
                    try {
                        [xml]$manifest = Get-Content -Path $manifestFile.FullName -Raw
                        $metadata = $manifest.PackageManifest.Metadata
                        if (-not $metadata -or -not $metadata.Identity) { continue }
                        $product.UserExtensions += [ordered]@{
                            Id          = $metadata.Identity.Id
                            Version     = $metadata.Identity.Version
                            Publisher   = $metadata.Identity.Publisher
                            DisplayName = "$($metadata.DisplayName)"
                            MoreInfo    = "$($metadata.MoreInfo)"
                            Folder      = $manifestFile.Directory.FullName.Substring($extensionsDir.Length).TrimStart('\')
                        }
                    }
                    catch { $notes.Add("could not read $($manifestFile.FullName): $($_.Exception.Message)") }
                }
            }

            $products += $product
        }

        # ── winget packages ─────────────────────────────────────────────────
        $winget = Find-GuestWinget

        $wingetPackages = @()
        if ($winget) {
            $exportFile = Join-Path $setupDir 'inventory-winget.json'
            Remove-Item $exportFile -Force -ErrorAction SilentlyContinue
            & $winget export --output $exportFile --include-versions --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            if (Test-Path $exportFile) {
                $export = Get-Content $exportFile -Raw | ConvertFrom-Json
                foreach ($source in @($export.Sources)) {
                    foreach ($package in @($source.Packages)) {
                        $wingetPackages += [ordered]@{
                            Id      = $package.PackageIdentifier
                            Version = "$($package.Version)"
                            Source  = $source.SourceDetails.Name
                        }
                    }
                }
                Remove-Item $exportFile -Force -ErrorAction SilentlyContinue
            }
            else { $notes.Add("winget export produced no file (exit $LASTEXITCODE)") }

            # Packages winget can match but leaves out of its export.
            foreach ($id in @($wingetCheck)) {
                if (-not $id) { continue }
                if (@($wingetPackages | Where-Object { $_.Id -eq $id }).Count -gt 0) { continue }
                $listed = & $winget list --id $id --exact --accept-source-agreements --disable-interactivity 2>&1
                if ($LASTEXITCODE -eq 0 -and ($listed -join ' ') -match [regex]::Escape($id)) {
                    $wingetPackages += [ordered]@{ Id = $id; Version = ''; Source = 'winget' }
                }
            }

            # Programs winget's source has although they were installed some
            # other way: winget matches them in its list, so a rebuild can
            # install them with winget (#24). UTF-8, so a name cut short with
            # an ellipsis keeps the columns where the header says.
            try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { $notes.Add("could not set the console to UTF-8: $($_.Exception.Message)") }
            $listed = @(& $winget list --source winget --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
            if ($LASTEXITCODE -eq 0) {
                foreach ($id in @(ConvertFrom-GuestWingetList -Lines $listed)) {
                    if (@($wingetPackages | Where-Object { $_.Id -eq $id }).Count -gt 0) { continue }
                    $wingetPackages += [ordered]@{ Id = $id; Version = ''; Source = 'winget' }
                }
            }
            else { $notes.Add("winget list found no packages from its source (exit $LASTEXITCODE)") }
        }
        else { $notes.Add('winget is not available in the guest') }

        # ── everything in the Windows uninstall list ───────────────────────
        # Updates, components of other products and entries with no name are
        # left out: they are not things anyone installs on their own.
        $uninstallKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $programs = @()
        foreach ($key in $uninstallKeys) {
            foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
                $properties = $entry.PSObject.Properties
                if (-not $properties['DisplayName'] -or -not $entry.DisplayName) { continue }
                if ($properties['SystemComponent'] -and $entry.SystemComponent -eq 1) { continue }
                if ($properties['ParentKeyName'] -and $entry.ParentKeyName) { continue }
                if ($properties['ReleaseType'] -and "$($entry.ReleaseType)" -match 'Update|Hotfix') { continue }
                $programs += [ordered]@{
                    Name      = "$($entry.DisplayName)"
                    Version   = if ($properties['DisplayVersion']) { "$($entry.DisplayVersion)" } else { '' }
                    Publisher = if ($properties['Publisher']) { "$($entry.Publisher)" } else { '' }
                    Key       = $entry.PSChildName
                    InstallDate = if ($properties['InstallDate']) { "$($entry.InstallDate)" } else { '' }
                    Scope     = if ($key -like 'HKCU:*') { 'user' } else { 'machine' }
                }
            }
        }
        # The same program can be listed under both registry views.
        $programs = @($programs | Group-Object { "$($_.Name)|$($_.Version)" } |
                ForEach-Object { $_.Group[0] } | Sort-Object { $_.Name })

        return [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            UserName       = $env:USERNAME
            TakenAt        = (Get-Date).ToString('o')
            Products       = @($products)
            WingetPackages = @($wingetPackages)
            Programs       = @($programs)
            Notes          = @($notes)
        }
    }
}

function Get-GuestToolingReport {
    <#
      Get-LazyVMTooling: what is installed in the guest now, and what the
      next maintenance run would record. Saves the raw inventory on the host.
      Read-only in the guest; nothing is recorded.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $null = Open-GuestSession -VM $VM -Purpose 'take the inventory'
    $inventory = Get-GuestToolingInventory -VM $VM

    $toolingDir = Join-Path $VM.Settings.StateDir 'tooling'
    $path = Join-Path $toolingDir ('inventory-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-TextFileAtomic -Path $path -Text (ConvertTo-Json -InputObject $inventory -Depth 8)

    $recorded = Read-VMTooling -VM $VM
    $observed = ConvertTo-ToolingRecord -Inventory $inventory -WingetExclude $VM.Settings.ToolingWingetExclude
    Add-MarketplaceItem -Record $observed -Previous $recorded

    # Per-user extensions a rebuild cannot reinstall from the marketplace.
    $unmatched = @(
        foreach ($product in @($observed.Products)) {
            foreach ($extension in @($product.UserExtensions)) {
                if (-not $extension.MarketplaceItem) {
                    "$($extension.DisplayName) [$($extension.Id)] in $($product.DisplayName)"
                }
            }
        }
    )

    $pending = @()
    if ($recorded) {
        Merge-AwaitingReinstall -Record $observed -Previous $recorded
        $pending = @(Compare-ToolingRecord -Old $recorded -New $observed)
    }
    else {
        $pending = @('No tooling list recorded yet: the next maintenance run records this as the first one.')
    }

    return [pscustomobject]@{
        PSTypeName          = 'LazyVM.Tooling'
        Name                = $VM.Name
        Products            = @($observed.Products)
        WingetPackages      = @($observed.WingetPackages)
        Programs            = @($observed.Programs)
        UnmatchedExtensions = $unmatched
        PendingChanges      = $pending
        Notes               = @($inventory.Notes)
        SavedTo             = $path
    }
}
