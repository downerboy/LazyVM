function Set-LazyVMRoot {
    <#
    .SYNOPSIS
    Chooses the folder LazyVM keeps everything in on this host.

    .DESCRIPTION
    Every VM's disks, the ISO and installers, logs, encrypted passwords,
    captured state and your settings live under one folder, the LazyVM
    folder. Set-LazyVMRoot records it once, in your part of the registry,
    for every later command and for the scheduled tasks.

    The folder is open to you and SYSTEM only: no other account, local
    administrators included, can open it, and everything in it inherits
    that. Hyper-V adds each VM's own access to its files. Running
    Set-LazyVMRoot again on the same folder locks it again. A folder that
    already holds other files is refused, so nothing else is locked away;
    choose an empty or new folder. It asks before locking the folder;
    -Confirm:$false skips the question.

    The folder is created if needed, along with Shared\Config\LazyVM.Settings.json
    (your settings) and a copy of the settings schema beside it, so VS Code
    can offer autocomplete and check the file as you type.

    .PARAMETER Path
    A folder on a local drive, such as D:\DevVM. Not the top of a drive.
    Without Set-LazyVMRoot, LazyVM uses LazyVM in your profile folder
    (%USERPROFILE%\LazyVM).

    .EXAMPLE
    Set-LazyVMRoot -Path D:\DevVM

    .OUTPUTS
    LazyVM.Root: the folder and its settings file.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('LazyVM.Root')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    Assert-Administrator
    Assert-NoLegacyInstallation
    $root = Resolve-SettingsRoot -Path $Path -Source 'the -Path parameter'
    Assert-RootFolderUsable -Path $root

    $previous = Get-RegisteredRoot
    if ($previous -and $previous -ne $root) {
        Write-Warning "LazyVM was using $previous. Nothing there is moved: VMs built under it keep their disks there, but LazyVM will now look for VMs in $root."
    }

    if (-not $PSCmdlet.ShouldProcess($root, 'Keep LazyVM''s VMs and settings in this folder, and lock it to you and SYSTEM')) {
        return
    }

    Initialize-RootFolder -Path $root
    Set-RegisteredRoot -Path $root
    $configDir = Get-ConfigDir -Root $root
    Initialize-ConfigFolder -ConfigDir $configDir

    [pscustomobject]@{
        PSTypeName   = 'LazyVM.Root'
        Root         = $root
        SettingsFile = Join-Path -Path $configDir -ChildPath $script:SettingsFileName
    }
}
