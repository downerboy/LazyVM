function Show-LazyVMHelp {
    <#
    .SYNOPSIS
    Opens LazyVM's guide, use cases or diagrams, for the installed version, in your browser.

    .DESCRIPTION
    Opens the page on GitHub for the release you have installed, such as
    the v6.39.0 copy of the guide, so it matches the commands you can run.
    GitHub shows the Markdown formatted, with the diagrams. A build with a
    prerelease label has no release of its own, so it opens the page on the
    main branch.

    It only opens an address in your default browser. Nothing is downloaded,
    and nothing on the page is run. Get-Help <command> -Full describes any
    one command without leaving PowerShell.

    .PARAMETER Topic
    Guide, the guide to installing and using LazyVM (the default). UseCases,
    what LazyVM is for, case by case. Diagrams, the flow of each command
    drawn as a picture and as a numbered list.

    .EXAMPLE
    Show-LazyVMHelp

    Opens the guide.

    .EXAMPLE
    Show-LazyVMHelp -Topic Diagrams

    Opens the diagrams.

    .OUTPUTS
    None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Guide', 'UseCases', 'Diagrams')]
        [string]$Topic = 'Guide'
    )

    $module = $MyInvocation.MyCommand.Module
    $url = Get-DocumentationUrl -Topic $Topic -Version $module.Version -Prerelease $module.PrivateData.PSData.Prerelease
    try {
        Start-Process -FilePath $url
    }
    catch {
        Write-Error "Could not open your browser: $($_.Exception.Message) The page is at $url"
    }
}
