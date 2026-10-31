# Profile.ps1 - The settings files and the VM profiles.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
#   <Root>\Shared\Config\LazyVM.Settings.json   the shared template
#   <Root>\<Name>\Config\VM.json                one VM's living configuration
#   <Root>\<Name>\Config\VM.Template.json       the VM.json it was built from
#
# The shared template (the defaults, then LazyVM.Settings.json, which lists
# only the settings it changes) is used only to create a VM. From then on
# the VM's VM.json is its one source of truth: it holds every setting and
# the tooling list, so it can rebuild the VM or be copied for another one,
# and LazyVM keeps it up to date as the VM changes (Update-VMProfile),
# keeping recent versions in <Name>\Config\History (ProfileHistory.ps1).
# A copy of the schema is kept
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
    <# A VM's Config folder: its profile, the profile it was built from, and their history. #>
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
      Makes sure the Config folder has up-to-date copies of the schemas, for
      the editor (the settings schema, and the template schema the user's
      config templates in Shared\Templates point at), and a settings file to
      open, so there is always somewhere obvious to change a setting.
    #>
    param([Parameter(Mandatory)][string]$ConfigDir)

    New-Folder -Path $ConfigDir

    foreach ($schemaFileName in $script:SchemaFileName, $script:TemplateSchemaFileName) {
        $source = Join-Path -Path $script:DataDir -ChildPath $schemaFileName
        $copy = Join-Path -Path $ConfigDir -ChildPath $schemaFileName
        $schemaText = [IO.File]::ReadAllText($source)
        if (-not (Test-Path -LiteralPath $copy) -or [IO.File]::ReadAllText($copy) -ne $schemaText) {
            Write-TextFileAtomic -Path $copy -Text $schemaText
        }
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

function Get-SharedTemplateSetting {
    <#
      The shared template: every setting at its default, then
      LazyVM.Settings.json applied over them. Values are as written, with
      {VM} and relative paths left in, so they suit any VM. Returns the
      values, where each came from, and any warning from the settings file.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Unattended,
        [switch]$ReadOnly
    )

    $values = Get-DefaultSetting
    $sources = @{}
    foreach ($key in $values.Keys) { $sources[$key] = 'Default' }
    $warning = $null

    $hostFile = Join-Path -Path (Get-ConfigDir -Root $Root) -ChildPath $script:SettingsFileName
    if (Test-Path -LiteralPath $hostFile -PathType Leaf) {
        $loaded = Import-SettingsFile -Path $hostFile -Unattended:$Unattended -ReadOnly:$ReadOnly
        $warning = $loaded.Warning
        foreach ($key in $loaded.Values.Keys) {
            $values[$key] = $loaded.Values[$key]
            $sources[$key] = $script:SettingsFileName
        }
    }

    return [pscustomobject]@{
        Values   = $values
        Sources  = $sources
        HostFile = $hostFile
        Warning  = $warning
    }
}

function Get-PerVMSettingName {
    <#
      Settings that belong to one VM: file locations, the guest computer
      name, the maintenance time, the recorded identity of its disks and
      what LazyVM recorded inside it. A VM copied with -From takes these
      from the shared template, which names everything after the VM and
      records nothing, rather than from the VM it copies; a config template
      cannot hold them.
    #>
    [OutputType([string[]])]
    param()

    return @($script:HostPathSettings) + @('GuestComputerName', 'MaintenanceTime') + @($script:DataDiskIdentitySettings) + @($script:RecordedGuestStateSettings)
}

function Get-ShareableSetting {
    <#
      A VM's settings, tooling list included, without the ones each VM has
      its own of (Get-PerVMSettingName): what New-LazyVM -From copies and
      Export-LazyVMTemplate saves. Only reads: a caller that needs an older
      VM's Tooling.json folds it in first (Move-ToolingIntoProfile).
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $perVM = Get-PerVMSettingName
    $settings = Read-SettingsFile -Path (Get-VMProfilePath -Root $Root -Name $Name)
    $shareable = @{}
    foreach ($key in $settings.Keys) {
        if ($perVM -notcontains $key) { $shareable[$key] = $settings[$key] }
    }
    return $shareable
}

function New-VMProfile {
    <#
      Creates <Name>\Config\VM.json holding every setting: the shared
      template's values, with -ConfigTemplate the config template's over
      them, or with -From the source VM's, except the settings that must differ
      between VMs, which come from the shared template.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [string]$From,
        [string]$ConfigTemplate
    )

    if (-not (Test-VMName $Name)) {
        throw "'$Name' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit, and not '$script:SharedFolderName'."
    }

    $existing = @(Get-VMProfileName -Root $Root)
    if ($existing | Where-Object { $_ -eq $Name }) {
        throw "A VM named '$Name' already exists."
    }

    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $Root)

    $settings = (Get-SharedTemplateSetting -Root $Root).Values
    if ($ConfigTemplate) {
        $templateValues = Read-VMTemplate -Name $ConfigTemplate -Root $Root
        foreach ($key in $templateValues.Keys) { $settings[$key] = $templateValues[$key] }
    }
    if ($From) {
        $source = $existing | Where-Object { $_ -eq $From } | Select-Object -First 1
        if (-not $source) { throw "There is no VM named '$From' to copy." }
        # The tooling list is copied with the other settings, so an older
        # source VM's Tooling.json must be in its VM.json first. Its history
        # and checkpoints belong to the source VM and stay there.
        $null = Move-ToolingIntoProfile -Root $Root -Name $source
        $sourceSettings = Get-ShareableSetting -Root $Root -Name $source
        foreach ($key in $sourceSettings.Keys) { $settings[$key] = $sourceSettings[$key] }
    }

    $maintenanceTime = Get-NextMaintenanceTime -Root $Root -VMNames $existing
    if ($maintenanceTime) { $settings['MaintenanceTime'] = $maintenanceTime }

    $path = Get-VMProfilePath -Root $Root -Name $Name
    $text = ConvertTo-SettingsJson -Settings $settings -ForProfile
    Write-TextFileAtomic -Path $path -Text $text
    $null = Save-ProfileVersion -Root $Root -Name $Name -Text $text -Stamp (Get-Stamp)
    return $path
}

function ConvertTo-ComparableJson {
    <# A value as compact JSON with every table's keys sorted, so two values compare equal whatever their key order. #>
    param([AllowNull()]$Value)

    $sorted = {
        param($Item)
        if ($Item -is [System.Collections.IDictionary]) {
            $table = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object)) { $table[$key] = & $sorted $Item[$key] }
            return $table
        }
        if ($Item -is [System.Collections.IList]) {
            return , @(foreach ($element in $Item) { & $sorted $element })
        }
        return $Item
    }
    return ConvertTo-Json -InputObject (& $sorted $Value) -Depth 20 -Compress
}

function Update-VMProfile {
    <#
      The one way VM.json changes after it is created. Applies $Change (setting
      name -> new value), checks the result against the schema, writes it in
      a single step and keeps that version in History, named after $Stamp
      (now, by default), removing versions no longer needed. Logs each
      setting that changed and returns their names; returns nothing, and
      writes nothing, when no value differs.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Change,
        [Parameter(Mandatory)][string]$Reason,
        [ValidatePattern('^\d{8}-\d{6}$')][string]$Stamp
    )

    $path = Get-VMProfilePath -Root $Root -Name $Name
    $current = Read-SettingsFile -Path $path

    $updated = @{}
    foreach ($key in $current.Keys) { $updated[$key] = $current[$key] }
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($Change.Keys | Sort-Object)) {
        # Not $name: that is $Name, the VM, whatever the case.
        $setting = Find-SettingName -Name $key
        if (-not $setting) { throw "'$key' is not a setting, so it cannot be recorded in $path." }
        if ($current.ContainsKey($setting) -and (ConvertTo-ComparableJson $current[$setting]) -eq (ConvertTo-ComparableJson $Change[$key])) { continue }
        $updated[$setting] = $Change[$key]
        $changed.Add($setting)
    }
    if ($changed.Count -eq 0) { return @() }

    $problems = @(Get-SchemaProblem -Values $updated)
    if ($problems.Count -gt 0) {
        throw (Format-ProblemList -Heading "VM.json was left as it was: the change has {0} problem(s):`n  $path" -Problems $problems)
    }

    $text = ConvertTo-SettingsJson -Settings $updated -ForProfile
    Write-TextFileAtomic -Path $path -Text $text
    if (-not $Stamp) { $Stamp = Get-Stamp }
    $null = Save-ProfileVersion -Root $Root -Name $Name -Text $text -Stamp $Stamp
    Remove-OldProfileVersion -Root $Root -Name $Name -Needed (Get-ToolingCheckpointStamp -Name $Name)

    $what = if ($changed.Count -le 10) { $changed -join ', ' } else { "$($changed.Count) settings" }
    Write-LogEntry "Updated $path ($Reason): $what" 'INFO'
    return @($changed)
}

function Sync-VMProfile {
    <#
      Brings a VM's VM.json up to date before a build, maintenance or a
      rebuild uses it:
        * fills in every setting it lacks from the shared template: all of
          them for a profile made before VM.json held every setting, or a
          setting added by a newer LazyVM;
        * keeps a copy of it as VM.Template.json the first time, written once
          and never changed afterwards.
      A VM.json that cannot be read is never written over: the run goes on
      with the settings it already has and the problem is logged.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $root = $VM.Settings.Root
    $name = $VM.Name
    $path = Get-VMProfilePath -Root $root -Name $name
    try {
        $current = Read-SettingsFile -Path $path
    }
    catch {
        Write-LogEntry "VM.json was not brought up to date because it cannot be read: $($_.Exception.Message)" 'WARN'
        return
    }

    $template = (Get-SharedTemplateSetting -Root $root -Unattended:(Test-Unattended)).Values
    $missing = @{}
    foreach ($key in $template.Keys) {
        if (-not $current.ContainsKey($key)) { $missing[$key] = $template[$key] }
    }
    if ($missing.Count -gt 0) {
        $null = Update-VMProfile -Root $root -Name $name -Change $missing -Reason 'filled in from the shared template'
    }

    $templatePath = Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath $script:ProfileTemplateFileName
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        Copy-Item -LiteralPath $path -Destination $templatePath
        Write-LogEntry "Kept a copy of the configuration this VM is built from: $templatePath" 'INFO'
    }
}

function Initialize-BuildTarget {
    <#
      Everything Build-LazyVM needs before it can start, set up on first use
      so a single command is enough: the LazyVM folder, recorded once, and
      the VM's profile, from -ConfigTemplate when one is given. Says what it
      set up. A VM that already has a profile keeps it: its VM.json, not a
      config template, decides how it is built.
    #>
    param(
        [string]$Name,
        [string]$ConfigTemplate
    )

    $root = Get-RegisteredRoot
    if (-not $root) {
        $root = Get-DefaultRoot
        New-Folder -Path $root
        Set-RegisteredRoot -Path $root
        Write-Information "LazyVM keeps its VMs in $root. To use another folder, run Set-LazyVMRoot first." -InformationAction Continue
    }

    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $root)

    $existing = @(Get-VMProfileName -Root $root)
    if (-not $Name -and $existing.Count -eq 0) {
        throw 'Give the new VM a name, for example: Build-LazyVM -Name DevBox'
    }
    if ($Name -and -not ($existing | Where-Object { $_ -eq $Name })) {
        $null = New-VMProfile -Root $root -Name $Name -ConfigTemplate $ConfigTemplate
        $from = if ($ConfigTemplate) { " from the config template '$ConfigTemplate'" } else { '' }
        Write-Information "Created the profile for '$Name'$from." -InformationAction Continue
        return
    }
    if ($ConfigTemplate) {
        $vm = if ($Name) { "'$Name'" } else { 'The VM' }
        Write-Warning "$vm already has a profile, so -ConfigTemplate $ConfigTemplate was not used: its VM.json decides how it is built."
    }
}
