# Template.ps1 - Config templates: named starting points for a new VM.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A config template is a JSON file with two fields:
#   Name       what it is called, which -ConfigTemplate takes; not the file name
#   Settings   the settings it changes, like LazyVM.Settings.json
# The built-in ones are in the module's Data\Templates folder, the user's own
# in <Root>\Shared\Templates. LazyVM.Template.schema.json describes the file.
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

function Read-VMTemplateFile {
    <#
      One config template file: its Name, its path and the settings it
      changes, checked against the schema. Field names match whatever their
      case. Throws, saying what is wrong, when it cannot be used.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $name = $null
    $settings = $null
    $misplaced = [System.Collections.Generic.List[string]]::new()
    $document = Read-SettingsJson -Path $Path
    foreach ($key in $document.Keys) {
        switch ($key) {
            '$schema' { break }
            'Name' { $name = $document[$key]; break }
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
    if ($name -notmatch $script:TemplateNamePattern) {
        throw "'$name' cannot be used as a config template name: use 1-64 letters, digits or hyphens, starting with a letter or digit:`n  $Path"
    }
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
        Name     = $name
        Path     = $Path
        Settings = $checked
        Problem  = $null
    }
}

function Get-VMTemplate {
    <#
      Every config template file: the built-in ones, then, with -Root, the
      user's. Each has its Name, Path, Settings, BuiltIn and Problem; a file
      that cannot be read has only its Path, BuiltIn and the Problem.
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
                $template = [pscustomobject]@{ Name = $null; Path = $file.FullName; Settings = $null; Problem = $_.Exception.Message }
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
