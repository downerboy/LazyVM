function Get-LazyVMConfigTemplate {
    <#
    .SYNOPSIS
    Lists the config templates a new VM can be created from.

    .DESCRIPTION
    Returns one entry per config template that New-LazyVM -ConfigTemplate
    and Build-LazyVM -ConfigTemplate can use, sorted by name: the built-in
    ones (Developer and PlainWindows) and your own in
    <Root>\Shared\Templates, such as those Export-LazyVMTemplate saves.

    Each has its Name, BuiltIn (true for one that comes with LazyVM),
    Automatic (true for <VM>-latest, which LazyVM keeps up to date for
    each VM) and Path.

    One of your own replaces a built-in one of the same name, so only yours
    is listed. A template file that cannot be read, and a name several of
    your templates share, are left out with a warning saying what to fix,
    since a build would refuse them.

    It only reads, so it needs no administrator rights. Before there is a
    LazyVM folder it lists the built-in ones.

    .EXAMPLE
    Get-LazyVMConfigTemplate

    .EXAMPLE
    Get-LazyVMConfigTemplate | Where-Object -Not BuiltIn

    Only your own config templates.

    .OUTPUTS
    LazyVM.ConfigTemplate
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.ConfigTemplate')]
    param()

    $templates = @(Get-VMTemplate -Root (Get-RegisteredRoot))
    foreach ($unreadable in @($templates | Where-Object { $_.Problem })) {
        Write-Warning $unreadable.Problem
    }
    foreach ($name in Select-VMTemplateName -Template $templates) {
        try {
            $template = Select-NamedVMTemplate -Name $name -Template $templates
        }
        catch {
            Write-Warning $_.Exception.Message
            continue
        }
        [pscustomobject]@{
            PSTypeName = 'LazyVM.ConfigTemplate'
            Name       = $template.Name
            BuiltIn    = $template.BuiltIn
            Automatic  = $template.Automatic
            Path       = $template.Path
        }
    }
}
