# Configuration.ps1 - Loads and checks the settings files, and creates VM profiles.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  SETTINGS
#
#  Every setting, with its default and a description, is in the schema
#  Data\LazyVM.Settings.schema.json, which ships with the module. The user's
#  own values live in the LazyVM folder (the root), never in the module, so
#  installing an update cannot touch them:
#
#    <Root>\Config\LazyVM.Settings.json      for every VM on this host
#    <Root>\Config\VMs\<Name>\VM.json        for one VM, applied last
#
#  Each file lists only the settings it changes. A copy of the schema is kept
#  beside them, so an editor such as VS Code offers autocomplete, shows each
#  setting's description and default on hover, and underlines mistakes as
#  they are typed.
#
#  FORGIVING
#  Setting names are matched whatever their case, and a single value where a
#  list belongs counts as a one-item list. Every problem in a file is
#  reported together. Each time a file loads cleanly a copy is kept beside
#  it; an unattended run, such as the scheduled maintenance, that finds the
#  file broken uses that copy and logs a warning instead of stopping.
#
#  ROOT FOLDER
#  The folder that holds everything on the host. Chosen once and stored in
#  the registry (see Get-RegisteredRoot); a -Root parameter, where a command
#  offers one, overrides it for that run. Host paths in the settings are
#  relative to it unless written as full paths (E:\VMs), which is how one
#  large item can live on another drive.
# ─────────────────────────────────────────────────────────────────────────────

# Settings that name a file or folder on the HOST, and so are resolved against
# the root folder. Paths inside the guest (GuestSetupDir, GuestProjectPaths,
# ...) are deliberately absent: they are not host paths.
$script:HostPathSettings = @(
    'VHDXRoot'
    'ISOPath'
    'ISOSearchRoot'
    'SQLIsoPath'
    'SQLDiskPath'
    'DevDrivePath'
    'CheckpointDir'
    'VSSettingsBackup'
    'LogFile'
    'CredStoreDir'
    'StateDir'
)

# Where the root folder is recorded for every later run, including the
# scheduled tasks, which run as SYSTEM.
$script:RootRegistryKey = 'HKLM:\SOFTWARE\LazyVM'

$script:SettingsFileName = 'LazyVM.Settings.json'
$script:ProfileFileName = 'VM.json'
$script:SchemaFileName = 'LazyVM.Settings.schema.json'

function Get-SettingsSchema {
    <# The settings schema, read once per session. #>
    if (-not $script:SettingsSchema) {
        $path = Join-Path -Path $script:DataDir -ChildPath $script:SchemaFileName
        $script:SettingsSchema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }
    return $script:SettingsSchema
}

function ConvertTo-PlainValue {
    <#
      JSON tables come back as case-sensitive ordered tables. Settings are
      looked up by name all through the module, so they become ordinary
      PowerShell tables (case-insensitive), and arrays stay arrays.
    #>
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $Value.Keys) { $table[$key] = ConvertTo-PlainValue -Value $Value[$key] }
        return $table
    }
    if ($Value -is [System.Collections.IList]) {
        # The comma keeps a one-item or empty array an array on the way out.
        return , @(foreach ($item in $Value) { ConvertTo-PlainValue -Value $item })
    }
    return $Value
}

function Get-DefaultSettings {
    <# Every setting at its default, from the schema. A fresh copy each time. #>
    $schema = Get-SettingsSchema
    $settings = @{}
    foreach ($name in $schema.properties.Keys) {
        if ($name -eq '$schema') { continue }
        $settings[$name] = ConvertTo-PlainValue -Value $schema.properties[$name]['default']
    }
    return $settings
}

function Get-SettingDescription {
    <# A setting's description from the schema, or $null for an internal one. #>
    param([Parameter(Mandatory)][string]$Name)

    $schema = Get-SettingsSchema
    if ($schema.properties.Contains($Name)) { return $schema.properties[$Name]['description'] }
    return $null
}

function Format-SchemaProblem {
    <#
      Turns one of Test-Json's messages, such as
        Value is "string" but should be "integer" at '/vCPU'
      into plain words:
        'vCPU' should be a whole number, but is text.
    #>
    param([Parameter(Mandatory)][string]$Message)

    $message = $Message -replace '^The JSON is not valid with the schema: ', ''
    $where = ''
    if ($message -match "^(?<what>.*) at '(?<path>[^']*)'$") {
        $message = $Matches.what
        # /AppSettings/0/Name -> AppSettings item 1, Name
        $parts = @($Matches.path.Trim('/') -split '/' | Where-Object { $_ -ne '' })
        $where = ($parts | ForEach-Object { if ($_ -match '^\d+$') { "item $([int]$_ + 1)" } else { $_ } }) -join ', '
    }

    $kinds = @{
        string  = 'text'
        integer = 'a whole number'
        number  = 'a number'
        boolean = 'true or false'
        array   = 'a list [ ]'
        object  = 'a table { }'
        null    = 'empty'
    }

    $text = switch -Regex ($message) {
        '^All values fail against the false schema$' {
            if ($where -notmatch ',') { "'$where' is not a setting. Check its spelling: Get-LazyVMSetting lists every setting." }
            else { "'$where' is not allowed here." }
            break
        }
        '^Value is "(?<is>\w+)" but should be "(?<want>\w+)"$' {
            "'$where' should be $($kinds[$Matches.want]), but is $($kinds[$Matches.is])."
            break
        }
        default { if ($where) { "'$where': $message" } else { $message } }
    }
    return $text
}

function Read-SettingsFile {
    <#
      Reads one settings file, checks it against the schema and returns the
      values it sets. Throws, listing every problem at once, if it cannot be
      used; nothing from a file with problems is ever applied.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }

    try {
        $parsed = $text | ConvertFrom-Json -AsHashtable
    }
    catch {
        $reason = $_.Exception.Message -replace '^Conversion from JSON failed with error: ', ''
        throw "This settings file is not valid JSON:`n  $Path`n  $reason`n  Settings look like this: { `"vCPU`": 8, `"UseDevDrive`": false }"
    }
    if ($parsed -isnot [System.Collections.IDictionary]) {
        throw "This settings file must be a table of settings in { }:`n  $Path"
    }

    # Forgiving: names in any case take the schema's spelling, and a single
    # value where a list belongs becomes a one-item list.
    $schema = Get-SettingsSchema
    $values = [ordered]@{}
    foreach ($key in $parsed.Keys) {
        if ($key -eq '$schema') { continue }
        $name = @($schema.properties.Keys | Where-Object { $_ -eq $key }) | Select-Object -First 1
        if (-not $name) { $name = $key }
        $value = $parsed[$key]
        if ($schema.properties.Contains($name) -and $schema.properties[$name]['type'] -eq 'array' -and
            $null -ne $value -and $value -isnot [System.Collections.IList]) {
            $value = @($value)
        }
        $values[$name] = $value
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    $schemaPath = Join-Path -Path $script:DataDir -ChildPath $script:SchemaFileName
    $json = ConvertTo-Json -InputObject $values -Depth 20
    $schemaErrors = $null
    $null = Test-Json -Json $json -SchemaFile $schemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    foreach ($schemaError in @($schemaErrors)) {
        $problems.Add((Format-SchemaProblem -Message $schemaError.Exception.Message))
    }

    if ($problems.Count -gt 0) {
        $list = ($problems | Sort-Object -Unique | ForEach-Object { "  - $_" }) -join "`n"
        throw "This settings file has $($problems.Count) problem(s), so none of it was used:`n  $Path`n$list"
    }

    return ConvertTo-PlainValue -Value $values
}

function Get-LastGoodPath {
    <# Where the copy of a settings file is kept from the last time it loaded cleanly. #>
    param([Parameter(Mandatory)][string]$Path)

    $folder = Split-Path -Path $Path -Parent
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    return Join-Path -Path $folder -ChildPath "$stem.lastgood.json"
}

function Import-SettingsFile {
    <#
      Read-SettingsFile with a safety net. Each clean load keeps a copy of the
      file. When the file cannot be used and nobody is there to fix it
      (-Unattended), that copy is used instead and a warning returned for the
      log, so a typo never stops the scheduled maintenance. Run by a person,
      the problem is reported straight away so it can be fixed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Unattended
    )

    $lastGood = Get-LastGoodPath -Path $Path
    try {
        $values = Read-SettingsFile -Path $Path
        $text = [IO.File]::ReadAllText($Path)
        if (-not (Test-Path -LiteralPath $lastGood) -or [IO.File]::ReadAllText($lastGood) -ne $text) {
            Write-TextFileAtomic -Path $lastGood -Text $text
        }
        return [pscustomobject]@{ Values = $values; Warning = $null }
    }
    catch {
        if (-not $Unattended -or -not (Test-Path -LiteralPath $lastGood -PathType Leaf)) {
            throw
        }
        $problem = $_.Exception.Message
        $values = Read-SettingsFile -Path $lastGood
        $savedOn = (Get-Item -LiteralPath $lastGood).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $warning = "Using the copy of this settings file saved on $savedOn, the last time it loaded cleanly. " +
        "Fix the file and the next run will use it.`n$problem"
        return [pscustomobject]@{ Values = $values; Warning = $warning }
    }
}

function Test-FullHostPath {
    <# True for D:\folder or \\server\share; false for anything relative. #>
    param([string]$Path)

    return ($Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]')
}

function Resolve-SettingsRoot {
    <# Checks a root folder is usable and returns it in a standard form. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    $root = $Path.Trim().TrimEnd('\')

    # A folder on a local drive, not the top of a drive: Hyper-V disks belong
    # on local storage, and a bare drive root would scatter folders across it.
    # Double quotes are refused because the path is quoted into the
    # scheduled-task command lines.
    if ($root -notmatch '^[A-Za-z]:\\[^\\]' -or $root.Contains('"')) {
        throw "The LazyVM folder must be a folder on a local drive, such as D:\DevVM. Got '$Path' from $Source."
    }
    return $root
}

function Get-RegisteredRoot {
    <# The root folder recorded in the registry, or $null if none has been. #>
    $props = Get-ItemProperty -Path $script:RootRegistryKey -ErrorAction SilentlyContinue
    if ($props -and $props.PSObject.Properties['Root'] -and $props.Root) { return [string]$props.Root }
    return $null
}

function Set-RegisteredRoot {
    <# Records the root folder for every later run. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $script:RootRegistryKey)) {
        New-Item -Path $script:RootRegistryKey -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RootRegistryKey -Name 'Root' -Value $Path -Type String
}

function Resolve-LazyVMRoot {
    <# The root folder for this run: -Root if given, else the registered one. #>
    param([string]$Root)

    if ($Root) {
        return [pscustomobject]@{ Path = Resolve-SettingsRoot -Path $Root -Source 'the -Root parameter'; Source = 'the -Root parameter' }
    }
    $registered = Get-RegisteredRoot
    if ($registered) {
        $source = "the registry ($script:RootRegistryKey)"
        return [pscustomobject]@{ Path = Resolve-SettingsRoot -Path $registered -Source $source; Source = $source }
    }
    throw "LazyVM does not know which folder to keep its VMs in yet. Choose one with: Set-LazyVMRoot -Path D:\DevVM"
}

function Resolve-HostPathSettings {
    <# Joins every relative host path to the root. Updates $Settings in place. #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $script:HostPathSettings) {
        $value = [string]$Settings[$name]

        if (Test-FullHostPath $value) {
            continue
        }
        if (-not $value -or $value -match '^[A-Za-z]:' -or $value.StartsWith('\')) {
            $problems.Add("'$name' must be a path inside the LazyVM folder (like 'VMs') or a full path (like 'E:\VMs'), not '$value'.")
            continue
        }

        $relative = $value -replace '^\.\\', ''
        $Settings[$name] = "$Root\$relative"
    }

    if ($problems.Count -gt 0) {
        $list = ($problems | Sort-Object | ForEach-Object { "  - $_" }) -join "`n"
        throw "$($problems.Count) path setting(s) cannot be used:`n$list"
    }
}

function Add-DerivedSettings {
    <#
      Values worked out from the settings rather than set by the user: task
      and registry names, credential files, the answer-file disc and the
      guest SQL folders. Runs after the host paths are resolved.
    #>
    param([Parameter(Mandatory)][hashtable]$Settings)

    $vm = $Settings.VMName
    $Settings.SeedDiskPath = "$($Settings.VHDXRoot)\$vm-Seed.iso"
    $Settings.CredKeyFile = "$($Settings.CredStoreDir)\.lazyvm.key"
    $Settings.GuestCredFile = "$($Settings.CredStoreDir)\$vm\guest.cred"
    $Settings.CertCredFile = "$($Settings.CredStoreDir)\$vm\certs.cred"
    $Settings.ResumeRegKey = "$script:RootRegistryKey\$vm"
    $Settings.ResumeTaskName = "LazyVM-ResumeAfterReboot-$vm"
    $Settings.ScheduleTaskName = "LazyVM-Maintain-$vm"
    $Settings.ExcludeTaskPrefix = 'LazyVM-'

    # Recomputed by Set-GuestSqlPaths once the data disk's real letter is known.
    $letter = $Settings.GuestDataDriveLetter.ToUpperInvariant()
    $Settings.GuestSqlDataDir = "${letter}:\$($Settings.SqlDataFolder)"
    $Settings.GuestSqlLogDir = "${letter}:\$($Settings.SqlLogFolder)"
    $Settings.GuestSqlTempDir = "${letter}:\$($Settings.SqlTempFolder)"
    $Settings.GuestSqlBackupDir = "${letter}:\$($Settings.SqlBackupFolder)"
}

function Test-VMName {
    <#
      VM names become file names, task names and, by default, the guest's
      computer name, which Windows limits to 15 characters.
    #>
    param([string]$Name)

    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')
}

function Get-ConfigDir {
    <# The folder holding the user's settings and the VM profiles. #>
    param([Parameter(Mandatory)][string]$Root)

    return Join-Path -Path $Root -ChildPath 'Config'
}

function Get-VMProfileNames {
    <# The VMs this host knows about: one folder per VM under Config\VMs. #>
    param([Parameter(Mandatory)][string]$ConfigDir)

    $profilesDir = Join-Path -Path $ConfigDir -ChildPath 'VMs'
    $folders = @(Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath $script:ProfileFileName) -PathType Leaf })
    return @($folders | ForEach-Object { $_.Name } | Sort-Object)
}

function Get-VMProfilePath {
    <# A VM's profile file. #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Name
    )

    return Join-Path -Path (Join-Path -Path (Join-Path -Path $ConfigDir -ChildPath 'VMs') -ChildPath $Name) -ChildPath $script:ProfileFileName
}

function Resolve-VMSelection {
    <#
      Which VM this run is for: the one named, or the only one there is.
      Several VMs and no name is an error rather than a guess, because the
      wrong guess would maintain or rebuild the wrong machine.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$Requested
    )

    $names = @(Get-VMProfileNames -ConfigDir $ConfigDir)

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

function Expand-VMTokens {
    <# Replaces {VM} in every text setting with the VM's name. Updates $Settings in place. #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$VMName
    )

    foreach ($name in @($Settings.Keys)) {
        $value = $Settings[$name]
        if ($value -is [string] -and $value.Contains('{VM}')) {
            $Settings[$name] = $value.Replace('{VM}', $VMName)
        }
    }
}

function ConvertTo-SettingsJson {
    <# A settings table as the JSON written to a settings file, pointing at the schema. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$SchemaReference
    )

    $document = [ordered]@{ '$schema' = $SchemaReference }
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

    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }

    $source = Join-Path -Path $script:DataDir -ChildPath $script:SchemaFileName
    $copy = Join-Path -Path $ConfigDir -ChildPath $script:SchemaFileName
    $schemaText = [IO.File]::ReadAllText($source)
    if (-not (Test-Path -LiteralPath $copy) -or [IO.File]::ReadAllText($copy) -ne $schemaText) {
        Write-TextFileAtomic -Path $copy -Text $schemaText
    }

    $settingsFile = Join-Path -Path $ConfigDir -ChildPath $script:SettingsFileName
    if (-not (Test-Path -LiteralPath $settingsFile)) {
        Write-TextFileAtomic -Path $settingsFile -Text (ConvertTo-SettingsJson -Settings @{} -SchemaReference "./$script:SchemaFileName")
    }
}

function New-VMProfile {
    <#
      Creates Config\VMs\<Name>\VM.json. With -From, the new VM takes the
      source VM's settings, except the ones that must differ between VMs:
      file locations, the guest computer name and the maintenance time. Those
      come from the defaults, which name everything after the VM. The
      maintenance time is set an hour after the latest existing VM's, so two
      VMs are never maintained at once.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$From
    )

    if (-not (Test-VMName $Name)) {
        throw "'$Name' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit."
    }

    $existing = @(Get-VMProfileNames -ConfigDir $ConfigDir)
    if ($existing | Where-Object { $_ -eq $Name }) {
        throw "A VM named '$Name' already exists."
    }

    Initialize-ConfigFolder -ConfigDir $ConfigDir

    $defaults = Get-DefaultSettings
    $perVM = @($script:HostPathSettings) + @('GuestComputerName', 'MaintenanceTime')

    $settings = @{}
    if ($From) {
        $source = $existing | Where-Object { $_ -eq $From } | Select-Object -First 1
        if (-not $source) { throw "There is no VM named '$From' to copy." }
        $sourceSettings = Read-SettingsFile -Path (Get-VMProfilePath -ConfigDir $ConfigDir -Name $source)
        foreach ($key in $sourceSettings.Keys) {
            if ($perVM -notcontains $key) { $settings[$key] = $sourceSettings[$key] }
        }
    }

    # An hour after the latest maintenance time in use, wrapping at midnight.
    # A profile that cannot be read counts as using the default time.
    $latest = $null
    foreach ($vmName in $existing) {
        $time = $defaults['MaintenanceTime']
        try {
            $vmSettings = Read-SettingsFile -Path (Get-VMProfilePath -ConfigDir $ConfigDir -Name $vmName)
            if ($vmSettings.ContainsKey('MaintenanceTime')) { $time = $vmSettings['MaintenanceTime'] }
        }
        catch {
            Write-Verbose "Could not read the profile of '$vmName': $($_.Exception.Message)"
        }
        $parsed = [datetime]::ParseExact($time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        if (-not $latest -or $parsed.TimeOfDay -gt $latest.TimeOfDay) { $latest = $parsed }
    }
    if ($latest) {
        $settings['MaintenanceTime'] = $latest.AddHours(1).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }

    $path = Get-VMProfilePath -ConfigDir $ConfigDir -Name $Name
    Write-TextFileAtomic -Path $path -Text (ConvertTo-SettingsJson -Settings $settings -SchemaReference "../../$script:SchemaFileName")

    # The source VM's tooling list is what the new VM is built with. Its
    # history and checkpoints belong to the source VM and stay there.
    if ($From) {
        $sourceTooling = Join-Path -Path (Split-Path -Path (Get-VMProfilePath -ConfigDir $ConfigDir -Name $From) -Parent) -ChildPath 'Tooling.json'
        if (Test-Path -LiteralPath $sourceTooling -PathType Leaf) {
            Copy-Item -LiteralPath $sourceTooling -Destination (Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'Tooling.json')
        }
    }
    return $path
}

function Read-LazyVMSettings {
    <#
      Reads the settings for one VM, in layers: the defaults, then the
      host-wide settings file, then the VM's own profile. Then names
      everything after the VM, resolves every host path against the root and
      adds the derived values. Returns them in a table of their own, with
      where each value came from, and leaves the module's current settings
      untouched, so another VM's settings can be read without disturbing them.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$VMName,
        [switch]$Unattended
    )

    $configDir = Get-ConfigDir -Root $Root
    $settings = Get-DefaultSettings
    $sources = @{}
    foreach ($key in $settings.Keys) { $sources[$key] = 'Default' }
    $warnings = [System.Collections.Generic.List[string]]::new()

    $hostFile = Join-Path -Path $configDir -ChildPath $script:SettingsFileName
    $changedKeys = @()
    if (Test-Path -LiteralPath $hostFile -PathType Leaf) {
        $loaded = Import-SettingsFile -Path $hostFile -Unattended:$Unattended
        if ($loaded.Warning) { $warnings.Add($loaded.Warning) }
        foreach ($key in $loaded.Values.Keys) {
            $settings[$key] = $loaded.Values[$key]
            $sources[$key] = $script:SettingsFileName
        }
        $changedKeys = @($loaded.Values.Keys | Sort-Object)
    }

    $vm = Resolve-VMSelection -ConfigDir $configDir -Requested $VMName
    $profilePath = Get-VMProfilePath -ConfigDir $configDir -Name $vm
    $loaded = Import-SettingsFile -Path $profilePath -Unattended:$Unattended
    if ($loaded.Warning) { $warnings.Add($loaded.Warning) }
    foreach ($key in $loaded.Values.Keys) {
        $settings[$key] = $loaded.Values[$key]
        $sources[$key] = "VMs\$vm\$script:ProfileFileName"
    }
    $profileKeys = @($loaded.Values.Keys | Sort-Object)

    $settings.VMName = $vm
    $settings.Root = $Root
    $settings.ConfigDir = $configDir
    # Where this VM's profile, tooling list and tooling history live.
    $settings.ProfileDir = Split-Path -Path $profilePath -Parent
    Expand-VMTokens -Settings $settings -VMName $vm
    Resolve-HostPathSettings -Settings $settings -Root $Root
    Add-DerivedSettings -Settings $settings

    return [pscustomobject]@{
        Settings    = $settings
        Sources     = $sources
        HostFile    = $hostFile
        ChangedKeys = $changedKeys
        VMName      = $vm
        ProfilePath = $profilePath
        ProfileKeys = $profileKeys
        Root        = $Root
        Warnings    = @($warnings)
    }
}

function Import-LazyVMConfiguration {
    <#
      Reads the settings for the VM a command is working on (see
      Read-LazyVMSettings) and makes them the module's current settings,
      which every function reads as $CFG.
    #>
    param(
        [string]$Root,
        [string]$VMName,
        [switch]$Unattended
    )

    $resolvedRoot = Resolve-LazyVMRoot -Root $Root
    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $resolvedRoot.Path)

    $configuration = Read-LazyVMSettings -Root $resolvedRoot.Path -VMName $VMName -Unattended:$Unattended
    $configuration | Add-Member -NotePropertyName RootSource -NotePropertyValue $resolvedRoot.Source

    # Filled in place rather than replaced: $CFG is this same table.
    $script:Settings.Clear()
    foreach ($key in @($configuration.Settings.Keys)) { $script:Settings[$key] = $configuration.Settings[$key] }
    $configuration.Settings = $script:Settings

    return $configuration
}

function ConvertFrom-LegacySettings {
    <#
      Converts a LazyVM 1.x settings file (.psd1) to the settings it still
      applies to, for the JSON file that replaces it. Settings that no longer
      exist, or that are now worked out automatically, are left out and
      listed in Notes.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $legacy = Import-PowerShellDataFile -LiteralPath $Path
    $schema = Get-SettingsSchema
    $values = @{}
    $notes = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($legacy.Keys | Sort-Object)) {
        $name = @($schema.properties.Keys | Where-Object { $_ -eq $key -and $_ -ne '$schema' }) | Select-Object -First 1
        if ($name) {
            $values[$name] = $legacy[$key]
        }
        elseif ($key -eq 'Root') {
            $notes.Add("'Root' is now chosen once with Set-LazyVMRoot, not in a settings file.")
        }
        else {
            $notes.Add("'$key' is no longer a setting, so it was left out.")
        }
    }
    return [pscustomobject]@{ Values = $values; Notes = @($notes) }
}

function Import-LegacyConfiguration {
    <#
      Brings the settings of a LazyVM 1.x kit across: its Config folder sat
      beside the scripts, in <Root>\Scripts\Config. Each settings file is
      converted to JSON, and each VM's tooling list and history copied. A
      file that already exists in the new place is never overwritten, and the
      old files are left exactly as they are. Returns what was done.
    #>
    param(
        [Parameter(Mandatory)][string]$LegacyConfigDir,
        [Parameter(Mandatory)][string]$ConfigDir
    )

    $done = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $LegacyConfigDir -PathType Container)) { return @($done) }

    Initialize-ConfigFolder -ConfigDir $ConfigDir

    $legacyUserFile = Join-Path -Path $LegacyConfigDir -ChildPath 'LazyVM.Config.psd1'
    $hostFile = Join-Path -Path $ConfigDir -ChildPath $script:SettingsFileName
    if (Test-Path -LiteralPath $legacyUserFile -PathType Leaf) {
        $current = Read-SettingsFile -Path $hostFile
        if ($current.Count -eq 0) {
            $converted = ConvertFrom-LegacySettings -Path $legacyUserFile
            Write-TextFileAtomic -Path $hostFile -Text (ConvertTo-SettingsJson -Settings $converted.Values -SchemaReference "./$script:SchemaFileName")
            $done.Add("Converted $legacyUserFile to $hostFile")
            foreach ($note in $converted.Notes) { $done.Add("  $note") }
        }
        else {
            $done.Add("Kept $hostFile, which already has settings; $legacyUserFile was not converted")
        }
    }

    $legacyProfiles = Join-Path -Path $LegacyConfigDir -ChildPath 'VMs'
    foreach ($folder in @(Get-ChildItem -LiteralPath $legacyProfiles -Directory -ErrorAction SilentlyContinue)) {
        $legacyProfile = Join-Path -Path $folder.FullName -ChildPath 'VM.psd1'
        if (-not (Test-Path -LiteralPath $legacyProfile -PathType Leaf)) { continue }

        $profilePath = Get-VMProfilePath -ConfigDir $ConfigDir -Name $folder.Name
        if (Test-Path -LiteralPath $profilePath) {
            $done.Add("Kept the existing profile of '$($folder.Name)'; $legacyProfile was not converted")
            continue
        }

        $converted = ConvertFrom-LegacySettings -Path $legacyProfile
        Write-TextFileAtomic -Path $profilePath -Text (ConvertTo-SettingsJson -Settings $converted.Values -SchemaReference "../../$script:SchemaFileName")
        $done.Add("Converted the profile of '$($folder.Name)' to $profilePath")
        foreach ($note in $converted.Notes) { $done.Add("  $note") }

        # The tooling list and its history are already JSON: copied as they are.
        $profileDir = Split-Path -Path $profilePath -Parent
        foreach ($item in 'Tooling.json', 'History') {
            $legacyItem = Join-Path -Path $folder.FullName -ChildPath $item
            if (Test-Path -LiteralPath $legacyItem) {
                Copy-Item -LiteralPath $legacyItem -Destination $profileDir -Recurse
                $done.Add("  Copied its $item")
            }
        }
    }
    return @($done)
}
