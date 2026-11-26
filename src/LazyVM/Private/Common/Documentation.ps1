function Get-DocumentationUrl {
    <#
      The address of one of LazyVM's documentation pages on GitHub (#501). A
      release is tagged v<version>, and that tag's page shows the Markdown
      and the diagrams as they were for that version. A build with a
      prerelease label has no tag of its own, so it gets the page on main.
      Only the pages below can be asked for, so no other address reaches
      the browser. Troubleshooting is the guide's troubleshooting section.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Guide', 'UseCases', 'Diagrams', 'Troubleshooting')]
        [string]$Topic,

        [Parameter(Mandatory)]
        [version]$Version,

        [string]$Prerelease
    )

    $pages = @{
        Guide           = 'docs/Guide.md'
        UseCases        = 'docs/UseCases.md'
        Diagrams        = 'docs/Diagrams.md'
        Troubleshooting = 'docs/Guide.md#12-troubleshooting'
    }
    $reference = if ($Prerelease) { 'main' } else { "v$Version" }
    return "$script:DocumentationBaseUrl/blob/$reference/$($pages[$Topic])"
}
