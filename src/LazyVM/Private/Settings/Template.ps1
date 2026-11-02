# Template.ps1 - Config templates: named starting points for a new VM.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A config template is a JSON file with these fields:
#   Name       what it is called, which -ConfigTemplate takes; not the file name
#   Automatic  true in the one maintenance keeps up to date for each VM,
#              <VM>-latest (#292); left out of the user's own
#   Settings   the settings it changes, like LazyVM.Settings.json
# The built-in ones are in the module's Data\Templates folder, the user's own
# in <Root>\Shared\Templates, where Export-LazyVMTemplate saves them.
# LazyVM.Template.schema.json describes the file.
# New-LazyVM -ConfigTemplate (and Build-LazyVM -ConfigTemplate, for a VM with
# no profile yet) applies a template's Settings over the shared template.
# Name belongs to the template, so it never becomes a setting in VM.json, and
# a template cannot hold the settings each VM has its own of. One of the
# user's own replaces a built-in one of the same name.

function Get-BuiltInTemplateDir {
    <# The module's folder of built-in config templates. #>
    [OutputType([string])]
    param()

    return Join-Path -Path $script:DataDir -ChildPath $script:TemplatesFolderName
}

function Get-UserTemplateDir {
    <# The folder of the user's own config templates: <Root>\Shared\Templates. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root)

    return Join-Path -Path (Join-Path -Path $Root -ChildPath $script:SharedFolderName) -ChildPath $script:TemplatesFolderName
}

function Assert-TemplateName {
    <# Throws unless $Name can name a config template; -Path says which file it came from. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path
    )

    if ($Name -notmatch $script:TemplateNamePattern) {
        $where = if ($Path) { ":`n  $Path" } else { '.' }
        throw "'$Name' cannot be used as a config template name: use 1-64 letters, digits or hyphens, starting with a letter or digit$where"
    }
}

function Read-VMTemplateFile {
    <#
      One config template file: its Name, its path, whether maintenance
      keeps it up to date (Automatic) and the settings it changes, checked
      against the schema. Field names match whatever their case. Throws,
      saying what is wrong, when it cannot be used.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $name = $null
    $automatic = $false
    $settings = $null
    $misplaced = [System.Collections.Generic.List[string]]::new()
    $document = Read-SettingsJson -Path $Path
    foreach ($key in $document.Keys) {
        switch ($key) {
            '$schema' { break }
            'Name' { $name = $document[$key]; break }
            'Automatic' { $automatic = $document[$key] -eq $true; break }
            'Settings' { $settings = $document[$key]; break }
            default { $misplaced.Add("'$key'") }
        }
    }
    if ($misplaced.Count -gt 0) {
        throw "This config template has $($misplaced -join ', ') outside its Settings; settings go inside `"Settings`": { }:`n  $Path"
    }
    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
        throw "This config template needs a Name, such as `"Name`": `"WebDev`":`n  $Path"
    }
    Assert-TemplateName -Name $name -Path $Path
    if ($settings -isnot [System.Collections.IDictionary]) {
        throw "This config template needs a Settings table holding the settings it changes, such as `"Settings`": { `"vCPU`": 8 }:`n  $Path"
    }

    $checked = ConvertTo-CheckedSetting -Values $settings -Path $Path
    $perVM = Get-PerVMSettingName
    $belongToVM = @($checked.Keys | Where-Object { $perVM -contains $_ } | Sort-Object)
    if ($belongToVM.Count -gt 0) {
        throw "$(($belongToVM | ForEach-Object { "'$_'" }) -join ', ') cannot be in a config template: each VM has its own (file locations, the computer name, the maintenance time, its disks and what was recorded inside it). Remove it from Settings:`n  $Path"
    }

    return [pscustomobject]@{
        Name      = $name
        Path      = $Path
        Automatic = $automatic
        Settings  = $checked
        Problem   = $null
    }
}

function Get-VMTemplate {
    <#
      Every config template file: the built-in ones, then, with -Root, the
      user's. Each has its Name, Path, Automatic, Settings, BuiltIn and
      Problem; a file that cannot be read has only its Path, BuiltIn and the
      Problem.
    #>
    [OutputType([pscustomobject[]])]
    param([string]$Root)

    $folders = @([pscustomobject]@{ Path = Get-BuiltInTemplateDir; BuiltIn = $true })
    if ($Root) { $folders += [pscustomobject]@{ Path = Get-UserTemplateDir -Root $Root; BuiltIn = $false } }

    $templates = foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder.Path -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder.Path -Filter '*.json' -File | Sort-Object -Property Name)) {
            try {
                $template = Read-VMTemplateFile -Path $file.FullName
            }
            catch {
                $template = [pscustomobject]@{ Name = $null; Path = $file.FullName; Automatic = $false; Settings = $null; Problem = $_.Exception.Message }
            }
            $template | Add-Member -NotePropertyName 'BuiltIn' -NotePropertyValue $folder.BuiltIn -PassThru
        }
    }
    return @($templates)
}

function Select-VMTemplateName {
    <# The names of the usable templates among $Template, sorted, each once. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Template)

    return @($Template | Where-Object { -not $_.Problem } | ForEach-Object { $_.Name } | Sort-Object -Unique)
}

function Get-VMTemplateName {
    <# The names of the config templates there are, sorted, each once. #>
    [OutputType([string[]])]
    param([string]$Root)

    return Select-VMTemplateName -Template @(Get-VMTemplate -Root $Root)
}

function Read-VMTemplate {
    <#
      The settings the config template of that name changes. One of the
      user's own replaces a built-in one of the same name, as
      LazyVM.Settings.json replaces the defaults. Throws, naming the
      templates there are and any file that could not be read, when there is
      none of that name, and naming the files when several of the user's
      share it.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Root
    )

    $templates = @(Get-VMTemplate -Root $Root)
    $named = @($templates | Where-Object { -not $_.Problem -and $_.Name -eq $Name })
    $found = @($named | Where-Object { -not $_.BuiltIn })
    if ($found.Count -eq 0) { $found = $named }
    if ($found.Count -eq 1) {
        return $found[0].Settings
    }
    if ($found.Count -gt 1) {
        throw "Several config templates are named '$Name', so LazyVM cannot tell which to use. Change the Name in all but one:`n$(($found | ForEach-Object { "  $($_.Path)" }) -join "`n")"
    }

    $message = "There is no config template named '$Name'. Config templates: $((Select-VMTemplateName -Template $templates) -join ', ')."
    $unreadable = @($templates | Where-Object { $_.Problem })
    if ($unreadable.Count -gt 0) {
        $message += "`nThese template files could not be read:`n$(($unreadable | ForEach-Object { $_.Problem }) -join "`n")"
    }
    throw $message
}

function Get-UserTemplatePath {
    <# Where Export-LazyVMTemplate saves the config template named $TemplateName. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$TemplateName
    )

    return Join-Path -Path (Get-UserTemplateDir -Root $Root) -ChildPath "$TemplateName.json"
}

function Assert-TemplateNameAvailable {
    <#
      Throws unless a new config template can be saved as $TemplateName: a
      valid name that no template has, built-in or the user's, and no file
      of that name to write over.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$TemplateName
    )

    Assert-TemplateName -Name $TemplateName
    if (@(Get-VMTemplateName -Root $Root) -contains $TemplateName) {
        throw "There is already a config template named '$TemplateName'. Choose another name with -TemplateName."
    }
    $path = Get-UserTemplatePath -Root $Root -TemplateName $TemplateName
    if (Test-Path -LiteralPath $path) {
        throw "$path already exists. Move it, or choose another name with -TemplateName."
    }
}

function Export-VMTemplate {
    <#
      Saves a VM's settings and tooling list, without the ones each VM has
      its own of, as a config template named $TemplateName in
      <Root>\Shared\Templates; -Automatic marks it as the one maintenance
      keeps up to date. The caller checks the name first
      (Assert-TemplateNameAvailable, or Update-AutomaticTemplate for its
      own). Returns the template file's path.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TemplateName,
        [switch]$Automatic
    )

    $path = Get-UserTemplatePath -Root $Root -TemplateName $TemplateName
    # The template points at the schema copies in Shared\Config, for the editor.
    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $Root)
    # The tooling list goes in the template, so an older VM's Tooling.json
    # must be in its VM.json first.
    $null = Move-ToolingIntoProfile -Root $Root -Name $Name
    $settings = Get-ShareableSetting -Root $Root -Name $Name
    $document = [ordered]@{
        '$schema' = "../$script:ConfigFolderName/$script:TemplateSchemaFileName"
        Name      = $TemplateName
    }
    if ($Automatic) { $document.Automatic = $true }
    $document.Settings = [ordered]@{}
    foreach ($key in @($settings.Keys | Sort-Object)) { $document.Settings[$key] = $settings[$key] }

    New-Folder -Path (Split-Path -Path $path -Parent)
    Write-TextFileAtomic -Path $path -Text ((ConvertTo-Json -InputObject $document -Depth 20) + [Environment]::NewLine)
    return $path
}

function Update-AutomaticTemplate {
    <#
      Keeps the config template <VM>-latest in <Root>\Shared\Templates the
      same as the VM's latest configuration, so new VMs can start from it
      (#292). Writes it only when the VM's settings that a template can hold
      differ from it or, before there is one, from the configuration the VM
      was first built from (VM.Template.json). A template of the user's with
      that name, or in that file, is never written over: the log says why.
      Returns the template's path when it was written.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $root = $VM.Settings.Root
    $templateName = "$($VM.Name)-$script:AutomaticTemplateSuffix"
    $fileName = Split-Path -Path (Get-UserTemplatePath -Root $root -TemplateName $templateName) -Leaf
    $named = @(Get-VMTemplate -Root $root | Where-Object { -not $_.BuiltIn -and ($_.Name -eq $templateName -or (Split-Path -Path $_.Path -Leaf) -eq $fileName) })
    $own = @($named | Where-Object { -not $_.Automatic })
    if ($own.Count -gt 0) {
        Write-LogEntry "The config template '$templateName' was not updated from this VM's latest configuration: this file is not one LazyVM keeps up to date (it has no `"Automatic`": true), and LazyVM never writes over your own. Rename or move it to let LazyVM keep '$templateName':`n  $($own[0].Path)" 'WARN'
        return
    }

    $latest = Get-ShareableSetting -Root $root -Name $VM.Name
    $previous = if ($named.Count -gt 0) {
        $named[0].Settings
    }
    else {
        Select-ShareableSetting -Settings (Read-SettingsFile -Path (Get-VMProfileTemplatePath -Root $root -Name $VM.Name))
    }
    if ((ConvertTo-ComparableJson $latest) -eq (ConvertTo-ComparableJson $previous)) { return }

    $path = Export-VMTemplate -Root $root -Name $VM.Name -TemplateName $templateName -Automatic
    Write-LogEntry "Saved this VM's latest configuration as the config template '$templateName'. Build a new VM from it with -ConfigTemplate $templateName`:`n  $path" 'INFO'
    return $path
}
