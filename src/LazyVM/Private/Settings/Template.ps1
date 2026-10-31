# Template.ps1 - The named templates that ship with the module.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Each file in the module's Data\Templates folder is a template for a kind
# of VM, named after the file: Data\Templates\Minimal.json is 'Minimal'.
# Like LazyVM.Settings.json, it lists only the settings it changes.
# New-LazyVM -Template applies one over the shared template.

function Get-VMTemplateDir {
    <# The module's folder of named templates. #>
    [OutputType([string])]
    param()

    return Join-Path -Path $script:DataDir -ChildPath $script:TemplatesFolderName
}

function Get-VMTemplateName {
    <# The names of the templates that ship with the module, sorted. #>
    [OutputType([string[]])]
    param()

    return @(Get-ChildItem -LiteralPath (Get-VMTemplateDir) -Filter '*.json' -File | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Read-VMTemplate {
    <#
      The settings a named template changes, checked against the schema like
      any settings file. Throws, naming the templates there are, when there
      is no template of that name.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name)

    $names = @(Get-VMTemplateName)
    $match = $names | Where-Object { $_ -eq $Name } | Select-Object -First 1
    if (-not $match) {
        throw "There is no template named '$Name'. Templates: $($names -join ', ')."
    }
    return Read-SettingsFile -Path (Join-Path -Path (Get-VMTemplateDir) -ChildPath "$match.json")
}
