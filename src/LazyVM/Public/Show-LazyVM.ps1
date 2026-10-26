function Show-LazyVM {
    <#
    .SYNOPSIS
    Shows LazyVM's version, its folder and VMs, where it is installed, and its commands.

    .DESCRIPTION
    What typing LazyVM on its own shows: the installed version, the folder
    LazyVM keeps its VMs in, each VM in that folder, the folder the module
    is installed in, and then every LazyVM command with its synopsis, as
    Get-Help lists them. Get-Help <command> -Full describes any one command.

    .EXAMPLE
    LazyVM

    .EXAMPLE
    Show-LazyVM

    .OUTPUTS
    System.String, and the help summaries Get-Help returns
    #>
    [CmdletBinding()]
    [Alias('LazyVM')]
    [OutputType([string], [pscustomobject])]
    param()

    $module = $MyInvocation.MyCommand.Module
    $version = "$($module.Version)"
    $prerelease = $module.PrivateData.PSData.Prerelease
    if ($prerelease) { $version = "$version-$prerelease" }
    "LazyVM $version"

    $root = $null
    try {
        $root = (Resolve-LazyVMRoot).Path
        "Folder  : $root"
    }
    catch {
        "Folder  : $($_.Exception.Message)"
    }

    $vmNames = @()
    if ($root) { $vmNames = @(Get-VMProfileName -Root $root) }
    if ($vmNames.Count -eq 0) {
        'VMs     : none yet. Create one with: Build-LazyVM -Name DevBox'
    }
    else {
        for ($i = 0; $i -lt $vmNames.Count; $i++) {
            $label = if ($i -eq 0) { 'VMs     : ' } else { '          ' }
            "$label$($vmNames[$i])"
        }
    }

    "Module  : $($module.ModuleBase)"

    # What Get-Help LazyVM lists when no command is called LazyVM itself;
    # now that one is, the same search is made by name. From in here it also
    # sees the module's internal functions, so only exported ones are kept.
    Get-Help -Name '*LazyVM*' -Category Function | Where-Object { $module.ExportedFunctions.ContainsKey($_.Name) }
}
