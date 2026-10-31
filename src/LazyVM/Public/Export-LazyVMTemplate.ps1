function Export-LazyVMTemplate {
    <#
    .SYNOPSIS
    Saves a VM's configuration as a config template for new VMs.

    .DESCRIPTION
    Writes the VM's VM.json, tooling list included, as a config template in
    <Root>\Shared\Templates. New VMs can then start from it with
    Build-LazyVM -ConfigTemplate or New-LazyVM -ConfigTemplate. Settings that
    must differ between VMs (file locations, the computer name, the
    maintenance time and the recorded identity of its disks) are left out,
    as New-LazyVM -From leaves them out.

    A typical workflow: build a VM from the PlainWindows template, install
    and set up the apps you want, export it, and build new VMs from it.
    Unlike New-LazyVM -From, which copies a VM once, the template stays, to
    be used for as many VMs as you like.

    A name another config template already has, built-in or your own, is
    refused.

    .PARAMETER Name
    The VM whose configuration becomes the template. May be left out while
    there is only one.

    .PARAMETER TemplateName
    The template's name, which -ConfigTemplate takes: 1-64 letters, digits
    or hyphens, starting with a letter or digit. The VM's name if left out.

    .EXAMPLE
    Export-LazyVMTemplate -Name Clean -TemplateName Office

    Saves Clean's configuration as the config template Office, then:
    Build-LazyVM -Name Office2 -ConfigTemplate Office

    .OUTPUTS
    System.IO.FileInfo
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [string]$TemplateName
    )

    $root = (Resolve-LazyVMRoot).Path
    $vmName = Resolve-VMSelection -Root $root -Requested $Name
    if (-not $TemplateName) { $TemplateName = $vmName }
    # Before asking, so -WhatIf and -Confirm report a name that cannot be used.
    Assert-TemplateNameAvailable -Root $root -TemplateName $TemplateName

    if (-not $PSCmdlet.ShouldProcess($vmName, "Save its configuration as the config template '$TemplateName'")) {
        return
    }

    $path = Export-VMTemplate -Root $root -Name $vmName -TemplateName $TemplateName
    Get-Item -LiteralPath $path
}
