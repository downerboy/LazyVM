function New-LazyVM {
    <#
    .SYNOPSIS
    Creates a new VM's profile, ready to build.

    .DESCRIPTION
    Creates <Name>\Config\VM.json in the LazyVM folder, holding every
    setting for the VM, taken from the shared template (the defaults and
    your LazyVM.Settings.json). From then on VM.json is the VM's own
    configuration. Nothing is built yet: build the VM with Build-LazyVM.

    With -From, the new VM starts from an existing VM's VM.json and tooling
    list, so it is built the same way with the same tools. Settings that
    must differ between VMs (file locations, the computer name, the
    maintenance time) come from the shared template instead.

    Each new VM's daily maintenance is set an hour after the latest existing
    one, so two VMs are never maintained at the same time.

    .PARAMETER Name
    The VM's name: 1-15 letters, digits or hyphens, starting with a letter
    or digit. It also becomes the VM's computer name.

    .PARAMETER From
    An existing VM whose settings and tooling list the new VM starts from.

    .EXAMPLE
    New-LazyVM -Name DevBox

    .EXAMPLE
    New-LazyVM -Name DevBox2 -From DevBox

    .OUTPUTS
    LazyVM.VM
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('LazyVM.VM')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$', ErrorMessage = "'{0}' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit.")]
        [string]$Name,

        [string]$From
    )

    $root = (Resolve-LazyVMRoot).Path

    if (-not $PSCmdlet.ShouldProcess($Name, 'Create a LazyVM profile')) {
        return
    }

    $null = New-VMProfile -Root $root -Name $Name -From $From
    Get-LazyVM -Name $Name
    Write-Information "Next: Set-LazyVMCredential -Name $Name (optional), then Build-LazyVM -Name $Name" -InformationAction Continue
}
