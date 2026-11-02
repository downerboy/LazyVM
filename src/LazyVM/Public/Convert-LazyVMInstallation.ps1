function Convert-LazyVMInstallation {
    <#
    .SYNOPSIS
    Moves a LazyVM installed for every user to your Windows account alone.

    .DESCRIPTION
    LazyVM before version 6 was installed for every user of the computer:
    its folder (C:\LazyVM by default) and registry key were shared, its
    scheduled tasks ran as SYSTEM, and every administrator could decrypt its
    stored passwords. LazyVM 6 is installed per user, and refuses to run
    until such an install has been moved with this command, once.

    It moves, in this order:
    - the scheduled tasks, to run as you (it asks for your Windows password
      once; use your account's password, not your PIN);
    - the stored passwords and BitLocker recovery keys, re-encrypted so only
      your Windows account can read them, each read back before the old one
      is replaced; then the old key file is deleted;
    - each VM's files, with Hyper-V's storage migration, so a running VM
      keeps running. Hyper-V copies them, so the drive needs room for the
      largest VM a second time;
    - every other file, to the same place in the new folder, which only you
      and SYSTEM can open;
    - the folder and any interrupted build, to your part of the registry.
    Only then are the old folder (once empty), the machine-wide copy of the
    module in Program Files and the old registry key removed.

    If it stops part-way, fix what it reports and run it again: it carries
    on where it stopped, and nothing of the old install is removed before
    everything has moved. Its log is Shared\Logs\Migration.log in the new
    folder.

    Run it in PowerShell 7 as administrator, signed in as the Windows user
    who is to own LazyVM, while no LazyVM task is running.

    .PARAMETER Path
    The new LazyVM folder. LazyVM in your profile folder
    (%USERPROFILE%\LazyVM) if left out. Give the old folder itself to keep
    the files where they are and only lock the folder to you and SYSTEM.

    .EXAMPLE
    Convert-LazyVMInstallation -WhatIf

    Shows where the install would be moved, changing nothing.

    .EXAMPLE
    Convert-LazyVMInstallation

    Moves C:\LazyVM to %USERPROFILE%\LazyVM.

    .EXAMPLE
    Convert-LazyVMInstallation -Path C:\LazyVM

    Keeps the VMs in C:\LazyVM, open to you and SYSTEM only.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [string]$Path
    )

    Assert-Administrator
    $oldRoot = Get-LegacyRoot
    if (-not $oldRoot) {
        Write-Information 'LazyVM is already installed per user: there is nothing to move.' -InformationAction Continue
        return
    }
    $newRoot = if ($Path) { Resolve-SettingsRoot -Path $Path -Source 'the -Path parameter' } else { Get-DefaultRoot }

    $what = if ($oldRoot.TrimEnd('\').Equals($newRoot, [StringComparison]::OrdinalIgnoreCase)) { "keep the files in $newRoot, locked to you and SYSTEM" } else { "move its VMs and files to $newRoot" }
    if (-not $PSCmdlet.ShouldProcess($oldRoot, "Move LazyVM, installed for every user, to $(Get-TaskUserName): its tasks, its passwords, and $what")) {
        return
    }
    Invoke-InstallationMigration -OldRoot $oldRoot -NewRoot $newRoot
}
