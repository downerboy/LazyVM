function Export-LazyVMRecoveryKey {
    <#
    .SYNOPSIS
    Writes the VMs' BitLocker recovery passwords to a file you keep offline.

    .DESCRIPTION
    LazyVM keeps each VM's BitLocker recovery passwords in its own encrypted
    store. If that store is lost (your Windows profile is deleted, the disk
    fails, or the encryption keys are lost), the VMs' encrypted disks cannot
    be unlocked without a copy kept elsewhere. This command writes that copy:
    the recovery passwords of every VM, or of the VMs named, to the file you
    choose, such as one on a USB drive. A recovery key, in this command's
    name and its reminders, is a disk's 48-digit recovery password.

    The file is plain text, one field per line: the VM, the disk, its disk
    GUID, the key ID BitLocker's recovery screen shows, the date the
    password was recorded, and the recovery password. Anyone with the file
    can unlock the disks, so keep it offline and somewhere safe.

    An existing file is never written over without -Force, and -Force
    replaces it: nothing in it is kept. A file inside the LazyVM folder or in
    OneDrive is written, with a warning: a copy there is lost with the
    folder, or copied to the cloud.

    LazyVM records which keys each VM's file held, never the passwords. Until
    a new key is exported, such as a new disk's, the end of a build, the
    daily maintenance log, the next command you run on the VM, and
    Test-LazyVM remind you, with the command that exports every VM.

    .PARAMETER Name
    The VMs, by name; wildcards are allowed. Every VM if left out (default
    *). A name without wildcards that no VM has is an error.

    .PARAMETER Path
    The file to write, such as E:\LazyVM-recovery-keys.txt on a USB drive.
    Its folder must exist.

    .PARAMETER Force
    Write over the file if it exists. The file is replaced, not merged with
    what it held: with -Name, the keys of any other VM in it are removed.

    .EXAMPLE
    Export-LazyVMRecoveryKey -Path E:\LazyVM-recovery-keys.txt

    Writes every VM's recovery passwords to a file on drive E:.

    .EXAMPLE
    Export-LazyVMRecoveryKey -Path E:\LazyVM-recovery-keys.txt -Force

    Writes every VM's recovery passwords again, replacing the file written
    last time: what to run when LazyVM reminds you.

    .EXAMPLE
    Export-LazyVMRecoveryKey -Name DevBox -Path E:\DevBox-recovery-keys.txt

    Writes only DevBox's recovery passwords, to a file of its own.

    .OUTPUTS
    System.IO.FileInfo
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string[]]$Name = '*',

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Force
    )

    Assert-Administrator
    $root = (Resolve-LazyVMRoot).Path
    $all = @(Get-VMProfileName -Root $root)
    $names = @(Select-VMProfileName -Names $all -Pattern $Name)
    if ($names.Count -eq 0) { throw 'There are no VMs yet, so there is no recovery password to export.' }
    $vms = @(foreach ($vmName in $names) { [VMContext]::new((Read-VMSetting -Root $root -VMName $vmName -ReadOnly).Settings) })
    $keys = @(foreach ($vm in $vms) { Get-StoredRecoveryKey -VM $vm })
    if ($keys.Count -eq 0) { throw (Get-NoRecoveryKeyMessage -VMName $names) }

    # Before asking, so -WhatIf and -Confirm report a file that cannot be written.
    $file = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $folder = Split-Path -Path $file -Parent
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "The folder $folder is not there. Plug in the drive, or choose a folder that exists."
    }
    if (Test-Path -LiteralPath $file -PathType Container) { throw "$file is a folder. Give the path of a file to write." }
    if (Test-Path -LiteralPath $file) {
        if (-not $Force) { throw "$file already exists. Choose another file, or write over it with -Force." }
        if ($names.Count -lt $all.Count) {
            Write-Warning "$file is replaced, not added to: the recovery passwords of any other VM in it are removed. To keep every VM's in one file, leave out -Name."
        }
    }
    if (Test-PathWithin -Path $file -Folder $root) {
        Write-Warning "$file is inside the LazyVM folder ($root): if that folder is lost, this copy is lost with it. Keep the file offline, such as on a USB drive."
    }
    if (Test-CloudSyncedPath -Path $file) {
        Write-Warning "$file is in OneDrive (or another folder kept in step with the cloud), which copies it off this computer. Keep the file offline, such as on a USB drive."
    }

    $owners = @($keys | ForEach-Object { $_.Name } | Select-Object -Unique)
    if (-not $PSCmdlet.ShouldProcess($file, "Write the BitLocker recovery passwords of $($keys.Count) disk(s) of $($owners -join ', ')")) {
        return
    }

    Use-RunRoot -Root $root -ScriptBlock {
        Write-TextFileAtomic -Path $file -Text (Format-RecoveryKeyExport -Keys $keys)
        foreach ($vm in $vms) {
            $exported = @($keys | Where-Object { $_.Name -eq $vm.Name })
            if ($exported.Count -gt 0) { Save-RecoveryKeyExportRecord -VM $vm -Keys $exported }
        }
    }
    Get-Item -LiteralPath $file
}
