function Convert-LazyVMInstallation {
    <#
    .SYNOPSIS
    Moves a LazyVM installed for every user to your Windows account alone.

    .DESCRIPTION
    LazyVM before version 6 was installed for every user of the computer:
    its folder (C:\LazyVM by default) and registry key were shared, and its
    stored passwords were encrypted with a key file every administrator
    could read. LazyVM 6 is installed per user, with its folder open to that
    user and SYSTEM only, and refuses to run until such an install has been
    moved with this command, once.

    It moves, in this order:
    - the scheduled tasks, which still run as SYSTEM, now naming the new
      folder and loading this module;
    - the stored passwords and BitLocker recovery keys, re-encrypted with
      DPAPI for this computer, each read back before the old one is
      replaced; then the old key file is deleted;
    - each VM's files, with Hyper-V's storage migration, so a running VM
      keeps running. Hyper-V copies them, so the drive needs room for the
      largest VM a second time;
    - every other file, to the same place in the new folder, which only you
      and SYSTEM can open;
    - the folder to your part of the registry, and any interrupted build to
      its VM's folder.
    Only then are the old folder (once empty), the machine-wide copy of the
    module in Program Files (when you have your own copy) and the old
    registry key removed.

    If it stops part-way, fix what it reports and run it again: it carries
    on where it stopped. What has moved stays moved; the old registry key,
    the module copy and the empty old folder are removed only once
    everything has moved. Its log is Shared\Logs\Migration.log in the new
    folder.

    Run it in PowerShell 7 as administrator, signed in as the Windows user
    who is to own LazyVM, while no LazyVM task is running. The new folder
    must be empty, new, or already a LazyVM folder.

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
    $oldRoot = Get-RegisteredRoot -Key $script:LegacyRootRegistryKey
    if (-not $oldRoot) {
        Write-Information 'LazyVM is already installed per user: there is nothing to move.' -InformationAction Continue
        return
    }
    $requested = if ($Path) { $Path } else { Get-DefaultRoot }
    $newRoot = Resolve-SettingsRoot -Path $requested -Source $(if ($Path) { 'the -Path parameter' } else { 'the default' })
    # Before asking, so -WhatIf and -Confirm report a folder that cannot be used.
    Assert-MigrationTarget -OldRoot $oldRoot -NewRoot $newRoot

    $what = if (Test-SamePath -Path $oldRoot -Other $newRoot) { "keep the files in $newRoot and lock it to you and SYSTEM" } else { "move its VMs and files to $newRoot, locked to you and SYSTEM" }
    $action = "Move LazyVM, installed for every user, to $(Get-CurrentUserName): its tasks and passwords; $what; then remove the old registry key and the copy of the module in Program Files"
    if (-not $PSCmdlet.ShouldProcess($oldRoot, $action)) {
        return
    }
    Invoke-InstallationMigration -OldRoot $oldRoot -NewRoot $newRoot
}
