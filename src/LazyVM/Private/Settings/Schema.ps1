# Schema.ps1 - Reads settings files and checks them against the schema.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Every setting, with its default and a description, is in the schema
# Data\LazyVM.Settings.schema.json, which ships with the module. The user's
# own values live in the LazyVM folder, never in the module, so installing
# an update cannot touch them (see VMSetting.ps1 for the layers).
#
# Forgiving: setting names match whatever their case, a single value where a
# list belongs counts as a one-item list, and every problem in a file is
# reported together. Each time a file loads cleanly a copy is kept beside it;
# an unattended run that finds the file broken uses that copy and logs a
# warning instead of stopping.

function Get-SettingsSchema {
    <# The settings schema, read once per session. #>
    if (-not $script:SettingsSchema) {
        $path = Join-Path -Path $script:DataDir -ChildPath $script:SchemaFileName
        $script:SettingsSchema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }
    return $script:SettingsSchema
}

function Find-SettingName {
    <# The schema's spelling of a setting name given in any case, or $null when there is no such setting. #>
    param([Parameter(Mandatory)][string]$Name)

    return @((Get-SettingsSchema).properties.Keys | Where-Object { $_ -eq $Name -and $_ -ne '$schema' }) | Select-Object -First 1
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

function Get-DefaultSetting {
    <#
      Every setting at its default, from the schema. A fresh copy each time.
      A default too large for the schema (the tooling list) is in a file in
      the module's Data folder, which the setting names as its defaultFile.
    #>
    $schema = Get-SettingsSchema
    $settings = @{}
    foreach ($name in $schema.properties.Keys) {
        if ($name -eq '$schema') { continue }
        $property = $schema.properties[$name]
        $default = $property['default']
        if ($property.Contains('defaultFile')) {
            $default = Get-Content -LiteralPath (Join-Path -Path $script:DataDir -ChildPath $property['defaultFile']) -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        }
        $settings[$name] = ConvertTo-PlainValue -Value $default
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

function Format-ProblemList {
    <# "<count> <what>:" followed by one "  - problem" line each, sorted and without duplicates. #>
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter(Mandatory)][string[]]$Problems
    )

    $unique = @($Problems | Sort-Object -Unique)
    $list = ($unique | ForEach-Object { "  - $_" }) -join "`n"
    return ($Heading -f $unique.Count) + "`n" + $list
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
        '^Value is "(?<is>\w+)" but should be "(?<want>\w+(, \w+)*)"$' {
            # A setting that may be left empty allows two types: "integer, null".
            $want = ($Matches.want -split ', ' | ForEach-Object { $kinds[$_] }) -join ' or '
            "'$where' should be $want, but is $($kinds[$Matches.is])."
            break
        }
        default { if ($where) { "'$where': $message" } else { $message } }
    }
    return $text
}

function Resolve-SchemaPart {
    <# The part of the settings schema that $Part's "$ref" points to, or $Part itself when it has none. #>
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Part)

    if ($Part.Contains('$ref') -and $Part['$ref'] -match '^#/definitions/(?<name>.+)$') {
        return (Get-SettingsSchema).definitions[$Matches.name]
    }
    return $Part
}

function Get-SchemaPartJson {
    <# $Part as a schema of its own, with the definitions its "$ref"s point to. Made once per part. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Part)

    # Keyed by the part itself: a table is its own key.
    if (-not $script:SchemaPartJson.ContainsKey($Part)) {
        $schema = Get-SettingsSchema
        $own = [ordered]@{ '$schema' = $schema['$schema']; definitions = $schema['definitions'] }
        foreach ($key in $Part.Keys) { $own[$key] = $Part[$key] }
        $script:SchemaPartJson[$Part] = ConvertTo-Json -InputObject $own -Depth 20
    }
    return $script:SchemaPartJson[$Part]
}

function Get-NestedSchemaProblem {
    <#
      Test-Json does not always say why a value deep inside a setting is
      wrong: the same PowerShell has reported a bad mapped drive with
      reasons on one run and without on another (#350). So every table and
      every list item inside a setting is also checked against its own part
      of the schema, where its problems are top-level and always explained.
      $Where is $Value's place in the file, such as
      /GuestEnvironment/MappedDrives/0; the problems name it.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Part,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Where,
        # A list item is checked whatever it is; any other value only when it is a table.
        [switch]$ListItem
    )

    $resolved = Resolve-SchemaPart -Part $Part
    if ($ListItem -or $Value -is [System.Collections.IDictionary]) {
        $partErrors = $null
        $null = Test-Json -Json (ConvertTo-Json -InputObject $Value -Depth 20) -Schema (Get-SchemaPartJson -Part $resolved) -ErrorVariable partErrors -ErrorAction SilentlyContinue
        foreach ($partError in @($partErrors)) {
            # at '/Letter' -> at '/GuestEnvironment/MappedDrives/0/Letter'
            Format-SchemaProblem -Message ($partError.Exception.Message -replace " at '([^']*)'$", " at '$Where`$1'")
        }
    }

    if ($Value -is [System.Collections.IDictionary] -and $resolved['properties'] -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($resolved['properties'].Contains($key)) {
                Get-NestedSchemaProblem -Part $resolved['properties'][$key] -Value $Value[$key] -Where "$Where/$key"
            }
        }
    }
    elseif ($Value -is [System.Collections.IList] -and $resolved['items'] -is [System.Collections.IDictionary]) {
        for ($i = 0; $i -lt $Value.Count; $i++) {
            Get-NestedSchemaProblem -Part $resolved['items'] -Value $Value[$i] -Where "$Where/$i" -ListItem
        }
    }
}

function Get-SchemaProblem {
    <# Every schema problem in a table of settings, in plain words. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    $schema = Get-SettingsSchema
    $problems = [System.Collections.Generic.List[string]]::new()
    $schemaPath = Join-Path -Path $script:DataDir -ChildPath $script:SchemaFileName
    $schemaErrors = $null
    $valid = Test-Json -Json (ConvertTo-Json -InputObject $Values -Depth 20) -SchemaFile $schemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    foreach ($schemaError in @($schemaErrors)) {
        $problems.Add((Format-SchemaProblem -Message $schemaError.Exception.Message))
    }

    foreach ($name in $Values.Keys) {
        if (-not $schema.properties.Contains($name)) { continue }
        foreach ($problem in @(Get-NestedSchemaProblem -Part $schema.properties[$name] -Value $Values[$name] -Where "/$name")) {
            $problems.Add($problem)
        }
    }

    # Never accept a file the schema rejects, even when no reason was given.
    if (-not $valid -and $problems.Count -eq 0) {
        $problems.Add('It does not match the settings schema. Open it in VS Code to see where.')
    }
    return @($problems)
}

function Read-SettingsJson {
    <#
      The table of values in one JSON settings file, as written: an empty
      table for an empty file. Throws when it is not JSON or not a table.
    #>
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }

    try {
        # Dates stay text, as written: a value is never rewritten in another form.
        $parsed = $text | ConvertFrom-Json -AsHashtable -DateKind String
    }
    catch {
        $reason = $_.Exception.Message -replace '^Conversion from JSON failed with error: ', ''
        throw "This settings file is not valid JSON:`n  $Path`n  $reason`n  Settings look like this: { `"vCPU`": 8, `"UseDevDrive`": false }"
    }
    if ($parsed -isnot [System.Collections.IDictionary]) {
        throw "This settings file must be a table of settings in { }:`n  $Path"
    }
    return $parsed
}

function ConvertTo-CheckedSetting {
    <#
      A table of settings read from $Path, checked against the schema, with
      names in the schema's spelling and a single value where a list belongs
      made a one-item list. A setting LazyVM no longer uses is left out
      (#273). Throws, listing every problem at once, if it cannot be used;
      nothing with problems is ever applied.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Path
    )

    $schema = Get-SettingsSchema
    $checked = [ordered]@{}
    foreach ($key in $Values.Keys) {
        if ($key -eq '$schema' -or $key -in $script:RetiredSettingNames) { continue }
        $name = Find-SettingName -Name $key
        if (-not $name) { $name = $key }
        $value = $Values[$key]
        if ($schema.properties.Contains($name) -and $schema.properties[$name]['type'] -eq 'array' -and
            $null -ne $value -and $value -isnot [System.Collections.IList]) {
            $value = @($value)
        }
        $checked[$name] = $value
    }

    $problems = @(Get-SchemaProblem -Values $checked)
    if ($problems.Count -gt 0) {
        throw (Format-ProblemList -Heading "This settings file has {0} problem(s), so none of it was used:`n  $Path" -Problems $problems)
    }

    return ConvertTo-PlainValue -Value $checked
}

function Read-SettingsFile {
    <#
      Reads one settings file, checks it against the schema and returns the
      values it sets. Throws, listing every problem at once, if it cannot be
      used; nothing from a file with problems is ever applied.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    return ConvertTo-CheckedSetting -Values (Read-SettingsJson -Path $Path) -Path $Path
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
      the problem is reported straight away so it can be fixed. With
      -ReadOnly, for a command that must change nothing, no copy is kept.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Unattended,
        [switch]$ReadOnly
    )

    $lastGood = Get-LastGoodPath -Path $Path
    try {
        $values = Read-SettingsFile -Path $Path
        $text = [IO.File]::ReadAllText($Path)
        if (-not $ReadOnly -and (-not (Test-Path -LiteralPath $lastGood) -or [IO.File]::ReadAllText($lastGood) -ne $text)) {
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
