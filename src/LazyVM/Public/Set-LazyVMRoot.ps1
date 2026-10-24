function Set-LazyVMRoot {
    <#
    .SYNOPSIS
    Chooses the folder LazyVM keeps everything in on this host.

    .DESCRIPTION
    Every VM's disks, the ISO and installers, logs, encrypted passwords,
    captured state and your settings live under one folder, the LazyVM
    folder. Set-LazyVMRoot records it once, in the registry, for every later
    command and for the scheduled tasks.

    The folder is created if needed, along with Shared\Config\LazyVM.Settings.json
    (your settings) and a copy of the settings schema beside it, so VS Code
    can offer autocomplete and check the file as you type.

    .PARAMETER Path
    A folder on a local drive, such as D:\DevVM. Not the top of a drive.

    .EXAMPLE
    Set-LazyVMRoot -Path D:\DevVM

    .OUTPUTS
    LazyVM.Root: the folder and its settings file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('LazyVM.Root')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    Assert-Administrator
    $root = Resolve-SettingsRoot -Path $Path -Source 'the -Path parameter'

    $previous = Get-RegisteredRoot
    if ($previous -and $previous -ne $root) {
        Write-Warning "LazyVM was using $previous. Nothing there is moved: VMs built under it keep their disks there, but LazyVM will now look for VMs in $root."
    }

    if (-not $PSCmdlet.ShouldProcess($root, 'Keep LazyVM''s VMs and settings in this folder')) {
        return
    }

    New-Folder -Path $root
    Set-RegisteredRoot -Path $root
    $configDir = Get-ConfigDir -Root $root
    Initialize-ConfigFolder -ConfigDir $configDir

    [pscustomobject]@{
        PSTypeName   = 'LazyVM.Root'
        Root         = $root
        SettingsFile = Join-Path -Path $configDir -ChildPath $script:SettingsFileName
    }
}
