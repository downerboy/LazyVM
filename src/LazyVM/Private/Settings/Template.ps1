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
# Name belongs to the template, so it never becomes a setting in VM.json.

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
      changes, checked against the schema. Throws, saying what is wrong, when
      it cannot be used.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $document = Read-SettingsJson -Path $Path
    $misplaced = @($document.Keys | Where-Object { @('$schema', 'Name', 'Settings') -notcontains $_ })
    if ($misplaced.Count -gt 0) {
        throw "This config template has $(($misplaced | ForEach-Object { "'$_'" }) -join ', ') outside its Settings; settings go inside `"Settings`": { }:`n  $Path"
    }
    $name = $document['Name']
    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
        throw "This config template needs a Name, such as `"Name`": `"WebDev`":`n  $Path"
    }
    if ($name -notmatch $script:TemplateNamePattern) {
        throw "'$name' cannot be used as a config template name: use 1-64 letters, digits or hyphens, starting with a letter or digit:`n  $Path"
    }
    if ($document['Settings'] -isnot [System.Collections.IDictionary]) {
        throw "This config template needs a Settings table holding the settings it changes, such as `"Settings`": { `"vCPU`": 8 }:`n  $Path"
    }

    return [pscustomobject]@{
        Name     = $name
        Path     = $Path
        Settings = ConvertTo-CheckedSetting -Values $document['Settings'] -Path $Path
    }
}

function Get-VMTemplate {
    <#
      Every config template file: the built-in ones, then, with -Root, the
      user's. Each comes back as Read-VMTemplateFile reads it, or, when it
      cannot be read, with its Path and the Problem.
    #>
    [OutputType([pscustomobject[]])]
    param([string]$Root)

    $folders = @(Get-BuiltInTemplateDir)
    if ($Root) { $folders += Get-UserTemplateDir -Root $Root }

    $files = @($folders | Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
            ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.json' -File | Sort-Object -Property Name })
    $templates = foreach ($file in $files) {
        try {
            Read-VMTemplateFile -Path $file.FullName
        }
        catch {
            [pscustomobject]@{ Name = $null; Path = $file.FullName; Settings = $null; Problem = $_.Exception.Message }
        }
    }
    return @($templates)
}

function Get-VMTemplateName {
    <# The names of the config templates there are, sorted, each once. #>
    [OutputType([string[]])]
    param([string]$Root)

    return @(Get-VMTemplate -Root $Root | Where-Object { $_.Name } | ForEach-Object { $_.Name } | Sort-Object -Unique)
}

function Read-VMTemplate {
    <#
      The settings the config template of that name changes. Throws, naming
      the templates there are and any file that could not be read, when
      there is none of that name, and naming the files when several share it.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Root
    )

    $templates = @(Get-VMTemplate -Root $Root)
    $found = @($templates | Where-Object { $_.Name -eq $Name })
    if ($found.Count -eq 1) {
        return $found[0].Settings
    }
    if ($found.Count -gt 1) {
        throw "Several config templates are named '$Name', so LazyVM cannot tell which to use. Change the Name in all but one:`n$(($found | ForEach-Object { "  $($_.Path)" }) -join "`n")"
    }

    $message = "There is no config template named '$Name'. Config templates: $((Get-VMTemplateName -Root $Root) -join ', ')."
    $unreadable = @($templates | Where-Object { -not $_.Name })
    if ($unreadable.Count -gt 0) {
        $message += "`nThese template files could not be read:`n$(($unreadable | ForEach-Object { $_.Problem }) -join "`n")"
    }
    throw $message
}
