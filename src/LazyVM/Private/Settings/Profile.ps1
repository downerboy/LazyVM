# Profile.ps1 - The settings files and the VM profiles.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
#   <Root>\Shared\Config\LazyVM.Settings.json   for every VM on this host
#   <Root>\<Name>\Config\VM.json                for one VM, applied last
#
# Each file lists only the settings it changes. A copy of the schema is kept
# beside the host-wide file, so an editor such as VS Code offers
# autocomplete, shows each setting's description and default on hover, and
# underlines mistakes.

function Test-VMName {
    <#
      VM names become folder names, file names, task names and, by default,
      the guest's computer name, which Windows limits to 15 characters.
      'Shared' is taken by the folder every VM uses.
    #>
    param([string]$Name)

    if ($Name -eq $script:SharedFolderName) { return $false }
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')
}

function Get-ConfigDir {
    <# The folder holding the host-wide settings file and the schema. #>
    param([Parameter(Mandatory)][string]$Root)

    return Join-Path -Path (Join-Path -Path $Root -ChildPath $script:SharedFolderName) -ChildPath $script:ConfigFolderName
}

function Get-VMRoot {
    <# The one folder that holds everything belonging to a VM: <Root>\<Name>. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    return Join-Path -Path $Root -ChildPath $Name
}

function Get-VMProfileDir {
    <# A VM's Config folder: its profile, tooling list and tooling history. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    return Join-Path -Path (Get-VMRoot -Root $Root -Name $Name) -ChildPath $script:ConfigFolderName
}

function Get-VMProfilePath {
    <# A VM's profile file. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    return Join-Path -Path (Get-VMProfileDir -Root $Root -Name $Name) -ChildPath $script:ProfileFileName
}

function Get-VMProfileName {
    <# The VMs this host knows about: each folder in the LazyVM folder that holds a profile. #>
    param([Parameter(Mandatory)][string]$Root)

    $folders = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Test-VMName $_.Name) -and (Test-Path -LiteralPath (Get-VMProfilePath -Root $Root -Name $_.Name) -PathType Leaf) })
    return @($folders | ForEach-Object { $_.Name } | Sort-Object)
}

function Resolve-VMSelection {
    <#
      Which VM this run is for: the one named, or the only one there is.
      Several VMs and no name is an error rather than a guess, because the
      wrong guess would maintain or rebuild the wrong machine.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Requested
    )

    $names = @(Get-VMProfileName -Root $Root)

    if ($Requested) {
        $match = $names | Where-Object { $_ -eq $Requested } | Select-Object -First 1
        if (-not $match) {
            $known = if ($names.Count -gt 0) { $names -join ', ' } else { 'none yet' }
            throw "There is no VM named '$Requested' (VMs on this host: $known). Create one with: New-LazyVM -Name $Requested"
        }
        return $match
    }

    if ($names.Count -eq 1) {
        return $names[0]
    }
    if ($names.Count -eq 0) {
        throw 'There are no VMs yet. Create the first one with: New-LazyVM -Name <Name>'
    }
    throw "This host has several VMs ($($names -join ', ')). Say which one with -Name."
}

function ConvertTo-SettingsJson {
    <#
      A settings table as the JSON written to a settings file, pointing at the
      schema copy in Shared\Config: beside the host file, and from a VM
      profile in <Name>\Config, two levels up and into Shared\Config.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [switch]$ForProfile
    )

    $reference = if ($ForProfile) { "../../$script:SharedFolderName/$script:ConfigFolderName/$script:SchemaFileName" } else { "./$script:SchemaFileName" }
    $document = [ordered]@{ '$schema' = $reference }
    foreach ($key in @($Settings.Keys | Sort-Object)) { $document[$key] = $Settings[$key] }
    return (ConvertTo-Json -InputObject $document -Depth 20) + [Environment]::NewLine
}

function Initialize-ConfigFolder {
    <#
      Makes sure the Config folder has an up-to-date copy of the schema, for
      the editor, and a settings file to open, so there is always somewhere
      obvious to change a setting.
    #>
    param([Parameter(Mandatory)][string]$ConfigDir)

    New-Folder -Path $ConfigDir

    $source = Join-Path -Path $script:DataDir -ChildPath $script:SchemaFileName
    $copy = Join-Path -Path $ConfigDir -ChildPath $script:SchemaFileName
    $schemaText = [IO.File]::ReadAllText($source)
    if (-not (Test-Path -LiteralPath $copy) -or [IO.File]::ReadAllText($copy) -ne $schemaText) {
        Write-TextFileAtomic -Path $copy -Text $schemaText
    }

    $settingsFile = Join-Path -Path $ConfigDir -ChildPath $script:SettingsFileName
    if (-not (Test-Path -LiteralPath $settingsFile)) {
        Write-TextFileAtomic -Path $settingsFile -Text (ConvertTo-SettingsJson -Settings @{})
    }
}

function Get-NextMaintenanceTime {
    <#
      An hour after the latest maintenance time the VMs use, wrapping at
      midnight, so two VMs are never maintained at once. A profile that
      cannot be read counts as using the default time. $null when there are
      no VMs.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$VMNames
    )

    $default = (Get-DefaultSetting)['MaintenanceTime']
    $latest = $null
    foreach ($vmName in $VMNames) {
        $time = $default
        try {
            $vmSettings = Read-SettingsFile -Path (Get-VMProfilePath -Root $Root -Name $vmName)
            if ($vmSettings.ContainsKey('MaintenanceTime')) { $time = $vmSettings['MaintenanceTime'] }
        }
        catch {
            Write-Verbose "Could not read the profile of '$vmName': $($_.Exception.Message)"
        }
        $parsed = [datetime]::ParseExact($time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        if (-not $latest -or $parsed.TimeOfDay -gt $latest.TimeOfDay) { $latest = $parsed }
    }
    if (-not $latest) { return $null }
    return $latest.AddHours(1).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function New-VMProfile {
    <#
      Creates <Name>\Config\VM.json. With -From, the new VM takes the
      source VM's settings and tooling list, except the settings that must
      differ between VMs: file locations, the guest computer name and the
      maintenance time. Those come from the defaults, which name everything
      after the VM.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [string]$From
    )

    if (-not (Test-VMName $Name)) {
        throw "'$Name' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit, and not '$script:SharedFolderName'."
    }

    $existing = @(Get-VMProfileName -Root $Root)
    if ($existing | Where-Object { $_ -eq $Name }) {
        throw "A VM named '$Name' already exists."
    }

    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $Root)

    $settings = @{}
    $source = $null
    if ($From) {
        $source = $existing | Where-Object { $_ -eq $From } | Select-Object -First 1
        if (-not $source) { throw "There is no VM named '$From' to copy." }
        $perVM = @($script:HostPathSettings) + @('GuestComputerName', 'MaintenanceTime')
        $sourceSettings = Read-SettingsFile -Path (Get-VMProfilePath -Root $Root -Name $source)
        foreach ($key in $sourceSettings.Keys) {
            if ($perVM -notcontains $key) { $settings[$key] = $sourceSettings[$key] }
        }
    }

    $maintenanceTime = Get-NextMaintenanceTime -Root $Root -VMNames $existing
    if ($maintenanceTime) { $settings['MaintenanceTime'] = $maintenanceTime }

    $path = Get-VMProfilePath -Root $Root -Name $Name
    Write-TextFileAtomic -Path $path -Text (ConvertTo-SettingsJson -Settings $settings -ForProfile)

    # The source VM's tooling list is what the new VM is built with. Its
    # history and checkpoints belong to the source VM and stay there.
    if ($source) {
        $sourceTooling = Join-Path -Path (Get-VMProfileDir -Root $Root -Name $source) -ChildPath $script:ToolingFileName
        if (Test-Path -LiteralPath $sourceTooling -PathType Leaf) {
            Copy-Item -LiteralPath $sourceTooling -Destination (Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath $script:ToolingFileName)
        }
    }
    return $path
}

function Initialize-BuildTarget {
    <#
      Everything Build-LazyVM needs before it can start, set up on first use
      so a single command is enough: the LazyVM folder, recorded once, and
      the VM's profile. Says what it set up.
    #>
    param([string]$Name)

    $root = Get-RegisteredRoot
    if (-not $root) {
        $root = Get-DefaultRoot
        New-Folder -Path $root
        Set-RegisteredRoot -Path $root
        Write-Information "LazyVM keeps its VMs in $root. To use another folder, run Set-LazyVMRoot first." -InformationAction Continue
    }

    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $root)

    $existing = @(Get-VMProfileName -Root $root)
    if ($Name) {
        if (-not ($existing | Where-Object { $_ -eq $Name })) {
            $null = New-VMProfile -Root $root -Name $Name
            Write-Information "Created the profile for '$Name'." -InformationAction Continue
        }
    }
    elseif ($existing.Count -eq 0) {
        throw 'Give the new VM a name, for example: Build-LazyVM -Name DevBox'
    }
}
