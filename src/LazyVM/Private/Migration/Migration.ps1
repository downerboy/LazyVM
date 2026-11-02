# Migration.ps1 - Convert-LazyVMInstallation: a machine-wide install moved to the current user (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Before #284, LazyVM was installed for every user: its folder (C:\LazyVM by
# default) and registry key (HKLM) were shared, its tasks ran as SYSTEM and
# its credentials were encrypted with a key file every administrator could
# read. Each step here first looks at what is already done, so running the
# migration again after an interruption carries on where it stopped. What
# has moved stays moved; the old install's key, module copy and empty folder
# are removed only once every step has succeeded, and the HKLM key, which
# marks the install as not yet moved, goes last.

# ─────────────────────────────────────────────────────────────────────────────
#  CREDENTIALS: the old key file -> DPAPI for the current user
# ─────────────────────────────────────────────────────────────────────────────
function Get-LegacyCredentialKeyPath {
    <#
      Where LazyVM 5 kept the key for a VM's credentials: CredStoreDir from
      the VM's VM.json, else from the shared settings, else Shared\Credentials,
      in the old folder unless it is a full path. Read from the files as
      they are, since CredStoreDir is no longer a setting.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$VMName
    )

    $files = @(Join-Path -Path $Root -ChildPath "$script:SharedFolderName\$script:ConfigFolderName\$script:SettingsFileName")
    if ($VMName) { $files += Join-Path -Path $Root -ChildPath "$VMName\$script:ConfigFolderName\$script:ProfileFileName" }
    $folder = 'Shared\Credentials'
    foreach ($file in $files) {
        $path = $file -replace '\\', [IO.Path]::DirectorySeparatorChar
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $values = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($values -and $values['CredStoreDir']) { $folder = [string]$values['CredStoreDir'] }
    }
    $folder = $folder.Replace('{VM}', $VMName).TrimEnd('\')

    if (Test-FullHostPath $folder) { return "$folder\.lazyvm.key" }
    return Join-Path -Path (Join-Path -Path $Root -ChildPath ($folder -replace '\\', [IO.Path]::DirectorySeparatorChar)) -ChildPath '.lazyvm.key'
}

function Read-LegacyCredentialKey {
    <# The 32-byte key LazyVM 5 encrypted credentials with. Throws when it is missing or damaged. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The key the old credentials were encrypted with, $Path, is missing, so they cannot be moved over. Restore it from a backup and run Convert-LazyVMInstallation again."
    }
    $key = [IO.File]::ReadAllBytes($Path)
    if ($key.Length -ne 32) {
        throw "The key the old credentials were encrypted with, $Path, is damaged ($($key.Length) bytes instead of 32). Restore it from a backup and run Convert-LazyVMInstallation again."
    }
    return , $key
}

function Convert-LegacyCredentialFile {
    <#
      Re-encrypts one credential file from the old key to DPAPI for the
      current user. The new content is read back and compared before it
      replaces the file, so the file is never left unreadable. Returns
      whether it changed anything: a file already re-encrypted is left alone.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Path
    )

    $blob = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (Test-ProtectedCredentialBlob -Blob $blob) { return $false }

    $key = Read-LegacyCredentialKey -Path $KeyPath
    try { $password = ConvertTo-SecureString -String $blob.Password -Key $key }
    catch { throw "The old credential $Path cannot be decrypted with $KeyPath ($($_.Exception.Message)). It is left as it was." }

    $text = ConvertTo-StoredCredentialText -UserName $blob.UserName -Password $password
    $check = ConvertFrom-StoredCredentialText -Text $text -Path $Path
    if ($check.UserName -ne $blob.UserName -or (ConvertTo-PlainText -Secure $check.Password) -cne (ConvertTo-PlainText -Secure $password)) {
        throw "The re-encrypted credential $Path did not read back the same. It is left as it was."
    }
    Write-TextFileAtomic -Path $Path -Text $text
    return $true
}

function Convert-LegacyCredential {
    <#
      Re-encrypts every VM's credential files under $Root for the current
      user, then deletes the old key files, which nothing needs any more.
      Stops at the first file that cannot be re-encrypted, keeping the keys.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $keyPaths = [System.Collections.Generic.List[string]]::new()
    $keyPaths.Add((Get-LegacyCredentialKeyPath -Root $Root))
    $converted = 0
    foreach ($vmFolder in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        $credentialFolder = Join-Path -Path $vmFolder.FullName -ChildPath 'Credentials'
        $files = @(Get-ChildItem -LiteralPath $credentialFolder -Filter '*.cred' -File -Force -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { continue }
        $keyPath = Get-LegacyCredentialKeyPath -Root $Root -VMName $vmFolder.Name
        if (-not $keyPaths.Contains($keyPath)) { $keyPaths.Add($keyPath) }
        foreach ($file in $files) {
            if (Convert-LegacyCredentialFile -KeyPath $keyPath -Path $file.FullName) { $converted++ }
        }
    }
    Write-LogEntry "$converted credential file(s) re-encrypted for this computer" 'OK'

    foreach ($keyPath in $keyPaths) {
        if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
            Remove-Item -LiteralPath $keyPath -Force
            Write-LogEntry "Deleted the old credential key $keyPath" 'OK'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  TASKS: the action names the new folder and the module
# ─────────────────────────────────────────────────────────────────────────────
function Assert-NoRunningTask {
    <# Stops while a LazyVM task is running: it would work on files while they move. #>
    $running = @(Get-ScheduledTask -TaskName "$script:TaskPrefix*" -ErrorAction SilentlyContinue | Where-Object { "$($_.State)" -eq 'Running' })
    if ($running.Count -gt 0) {
        throw "LazyVM's task '$($running[0].TaskName)' is running. Wait until it has finished, then run Convert-LazyVMInstallation again."
    }
}

function Update-LegacyTask {
    <#
      Registers again each LazyVM task of the VMs in this install (a VM
      with a profile in $OldRoot or $NewRoot), keeping when it runs (its
      triggers and settings), with its action made as this version makes it:
      from the task's name, naming $NewRoot and loading this module. It
      still runs as SYSTEM. A task of the same name replaces it in one step.
      Other tasks are left alone.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    foreach ($task in @(Get-ScheduledTask -TaskName "$script:TaskPrefix*" -ErrorAction SilentlyContinue)) {
        $command = Get-HostTaskCommand -TaskName $task.TaskName -Root $NewRoot -OwnerSid (Get-CurrentUserSid).Value
        if (-not $command) {
            Write-LogEntry "Task '$($task.TaskName)' is not one LazyVM makes, so it is left as it was" 'WARN'
            continue
        }
        $vmName = $task.TaskName -replace "^($([regex]::Escape($script:MaintenanceTaskPrefix))|$([regex]::Escape($script:ResumeTaskPrefix)))", ''
        $inThisInstall = foreach ($root in $OldRoot, $NewRoot) {
            Test-Path -LiteralPath (Join-Path -Path $root -ChildPath "$vmName/$script:ConfigFolderName/$script:ProfileFileName") -PathType Leaf
        }
        if ($inThisInstall -notcontains $true) { continue }
        Register-LazyVMHostTask -TaskName $task.TaskName -Action (New-LazyVMTaskAction -Command $command) -Trigger $task.Triggers -Settings $task.Settings
        Write-LogEntry "Task '$($task.TaskName)' now runs LazyVM from $NewRoot" 'OK'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  DATA: the old folder -> the new one
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-NewRootPath {
    <# $Path's place under $NewRoot when it is inside $OldRoot; $null when it is not. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    if (-not $Path -or -not (Test-PathWithin -Path $Path -Folder $OldRoot)) { return $null }
    return $NewRoot.TrimEnd('\', '/') + $Path.TrimEnd('\', '/').Substring($OldRoot.TrimEnd('\', '/').Length)
}

function Get-FolderSize {
    <# The bytes in every file under $Path. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Path)

    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [long]$sum
}

function Assert-FreeSpace {
    <#
      Stops when the drive that holds $Path has less than $Bytes free for
      $What. When the free space cannot be read, says so and goes on: the
      copy itself then fails cleanly if the drive fills.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Bytes,
        [Parameter(Mandatory)][string]$What
    )

    $freeGB = Get-FreeSpaceGB -Path $Path
    if ($freeGB -lt 0) {
        Write-LogEntry "Could not read the free space on the drive of $Path; $What needs $(Format-Size $Bytes)" 'WARN'
        return
    }
    if ($freeGB * 1GB -lt $Bytes) {
        throw "Not enough free space for $($What): it needs $(Format-Size $Bytes) free on the drive of $Path, and $freeGB GB is free. Make room, then run Convert-LazyVMInstallation again."
    }
}

function Get-VMMoveSize {
    <# The bytes Hyper-V copies to move a VM: the disks being moved, and its configuration and checkpoint files. #>
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Vhds
    )

    [long]$bytes = 0
    foreach ($vhd in $Vhds) { $bytes += (Get-Item -LiteralPath $vhd.SourceFilePath -Force).Length }
    # Hyper-V keeps a VM's own files in these folders under its locations.
    foreach ($folder in "$($Machine.ConfigurationLocation)\Virtual Machines", "$($Machine.SnapshotFileLocation)\Snapshots") {
        $bytes += Get-FolderSize -Path $folder
    }
    return $bytes
}

function Move-LegacyVMStorage {
    <#
      Moves the files of every Hyper-V VM kept in $OldRoot - configuration,
      checkpoints, smart paging and disks - to the same places under
      $NewRoot, with Hyper-V's storage migration, so a running VM keeps
      running and Hyper-V gives each VM access to its files again. Hyper-V
      copies the files, so the drive needs room for the VM a second time.
      A VM with nothing left in $OldRoot is skipped.

      Each location is given its own place, not one destination folder for
      everything, which would put the disks beside the configuration and
      out of the <VM>\Disks folder the VM's settings name. Assert-NoVMFileLeft
      then checks nothing a VM uses, such as a checkpoint's parent disk, was
      left behind.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    foreach ($machine in @(Get-VM)) {
        $disks = @(Get-VMHardDiskDrive -VMName $machine.Name | Where-Object { $_.Path })
        # Move-VMStorage's parameter for each of the VM's own folders.
        $locations = [ordered]@{
            VirtualMachinePath  = $machine.ConfigurationLocation
            SnapshotFilePath    = $machine.SnapshotFileLocation
            SmartPagingFilePath = $machine.SmartPagingFilePath
        }
        $move = @{}
        foreach ($parameter in $locations.Keys) {
            $target = ConvertTo-NewRootPath -Path "$($locations[$parameter])" -OldRoot $OldRoot -NewRoot $NewRoot
            if ($target) { $move[$parameter] = $target }
        }
        $vhds = @(foreach ($disk in $disks) {
                $target = ConvertTo-NewRootPath -Path $disk.Path -OldRoot $OldRoot -NewRoot $NewRoot
                if ($target) { @{ SourceFilePath = $disk.Path; DestinationFilePath = $target } }
            })
        if ($vhds.Count -gt 0) { $move.Vhds = $vhds }
        if ($move.Count -eq 0) { continue }

        $needed = Get-VMMoveSize -Machine $machine -Vhds $vhds
        Assert-FreeSpace -Path $NewRoot -Bytes $needed -What "Hyper-V's copy of $($machine.Name)"
        Write-LogEntry "Moving $($machine.Name)'s files to $NewRoot with Hyper-V ($(Format-Size $needed)); the VM keeps running..." 'INFO'
        Move-VMStorage -VMName $machine.Name @move -ErrorAction Stop
        Write-LogEntry "Moved $($machine.Name)'s files" 'OK'
    }
}

function Assert-NoVMFileLeft {
    <#
      Stops when a Hyper-V VM still uses anything in $OldRoot after the
      storage migration - its configuration, checkpoint or smart paging
      folder, a disk attached now or to a checkpoint, or the parent of a
      checkpoint's differencing disk - so no file a VM needs is moved behind
      Hyper-V's back.
    #>
    param([Parameter(Mandatory)][string]$OldRoot)

    foreach ($machine in @(Get-VM)) {
        foreach ($location in @($machine.ConfigurationLocation, $machine.SnapshotFileLocation, $machine.SmartPagingFilePath | Where-Object { $_ })) {
            if (Test-PathWithin -Path $location -Folder $OldRoot) {
                throw "$($machine.Name) still keeps files in $location, in the old folder, after Hyper-V moved its files, so nothing more is moved. Move them in Hyper-V Manager (Move > Move the virtual machine's data to different locations), then run Convert-LazyVMInstallation again."
            }
        }
        $disks = @(Get-VMHardDiskDrive -VMName $machine.Name) + @(Get-VMSnapshot -VMName $machine.Name | ForEach-Object { $_.HardDrives })
        foreach ($disk in @($disks | Where-Object { $_.Path })) {
            $path = $disk.Path
            while ($path) {
                if (Test-PathWithin -Path $path -Folder $OldRoot) {
                    throw "$($machine.Name) still uses $path, in the old folder, after Hyper-V moved its files, so nothing more is moved. Move that disk in Hyper-V Manager (Move > Move only the virtual machine's virtual hard disks), then run Convert-LazyVMInstallation again."
                }
                $path = (Get-VHD -Path $path).ParentPath
            }
        }
    }
}

function Get-EjectedMediaPath {
    <# Where the migration notes the ISOs it ejected, in the new folder, until they are attached again. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NewRoot)

    return Join-Path -Path $NewRoot -ChildPath "$script:SharedFolderName/$script:EjectedMediaFileName"
}

function Read-EjectedMedia {
    <# The ISOs the migration ejected and has not attached again yet: VM, controller, location and old path. #>
    [OutputType([psobject])]
    param([Parameter(Mandatory)][string]$NewRoot)

    $path = Get-EjectedMediaPath -NewRoot $NewRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Dismount-LegacyDvdMedia {
    <#
      Ejects every ISO a VM has attached from $OldRoot, so its file can move.
      Each drive is noted in the new folder first, so it is attached again
      even if the migration stops in between.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    $drives = @(foreach ($machine in @(Get-VM)) {
            Get-VMDvdDrive -VMName $machine.Name | Where-Object { $_.Path -and (Test-PathWithin -Path $_.Path -Folder $OldRoot) }
        })
    if ($drives.Count -eq 0) { return }

    $noted = @(Read-EjectedMedia -NewRoot $NewRoot) + @($drives | ForEach-Object {
            [pscustomobject]@{ VMName = $_.VMName; ControllerNumber = $_.ControllerNumber; ControllerLocation = $_.ControllerLocation; Path = $_.Path }
        })
    Write-TextFileAtomic -Path (Get-EjectedMediaPath -NewRoot $NewRoot) -Text (ConvertTo-Json -InputObject $noted -Depth 3)
    foreach ($drive in $drives) {
        Set-VMDvdDrive -VMName $drive.VMName -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -Path $null -ErrorAction Stop
        Write-LogEntry "Ejected $($drive.Path) from $($drive.VMName) to move it" 'INFO'
    }
}

function Mount-MovedDvdMedia {
    <#
      Attaches each ISO Dismount-LegacyDvdMedia noted again, from its place
      under $NewRoot, then forgets them. A VM that no longer exists is
      skipped; any other failure stops, keeping the note for the next run.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    $media = @(Read-EjectedMedia -NewRoot $NewRoot)
    if ($media.Count -eq 0) { return }
    foreach ($drive in $media) {
        $path = ConvertTo-NewRootPath -Path $drive.Path -OldRoot $OldRoot -NewRoot $NewRoot
        if (-not (Get-VM -Name $drive.VMName -ErrorAction SilentlyContinue)) {
            Write-LogEntry "$($drive.VMName) is gone, so $path was not attached to it again" 'WARN'
            continue
        }
        Set-VMDvdDrive -VMName $drive.VMName -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -Path $path -ErrorAction Stop
        Write-LogEntry "Attached $path to $($drive.VMName) again" 'OK'
    }
    Remove-Item -LiteralPath (Get-EjectedMediaPath -NewRoot $NewRoot) -Force
}

function Move-LegacyFile {
    <#
      Moves every file left in $OldRoot to the same place under $NewRoot,
      one at a time, then removes the empty folders. A file is gone from
      the old place only once it is whole at the new one; what an
      interrupted move left at the new place is replaced.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    $files = @(Get-ChildItem -LiteralPath $OldRoot -Recurse -File -Force)
    # On the same drive a move only renames; to another it copies.
    if (-not ([IO.Path]::GetPathRoot($OldRoot)).Equals([IO.Path]::GetPathRoot($NewRoot), [StringComparison]::OrdinalIgnoreCase)) {
        Assert-FreeSpace -Path $NewRoot -Bytes ([long]($files | Measure-Object -Property Length -Sum).Sum) -What "the files in $OldRoot"
    }
    foreach ($file in $files) {
        $target = ConvertTo-NewRootPath -Path $file.FullName -OldRoot $OldRoot -NewRoot $NewRoot
        New-Folder -Path (Split-Path -Path $target -Parent)
        Move-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $folders = @(Get-ChildItem -LiteralPath $OldRoot -Recurse -Directory -Force | Sort-Object -Property { $_.FullName.Length } -Descending)
    foreach ($folder in $folders) {
        if (-not (Get-ChildItem -LiteralPath $folder.FullName -Force)) { Remove-Item -LiteralPath $folder.FullName -Force }
    }
    Write-LogEntry "$($files.Count) file(s) moved from $OldRoot to $NewRoot" 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
#  REGISTRY, AND THE END OF THE OLD INSTALL
# ─────────────────────────────────────────────────────────────────────────────
function Get-LegacyResumePhase {
    <# The phase each build interrupted by a restart was to carry on from, as the old install recorded it: VM name -> phase. #>
    [OutputType([hashtable])]
    param()

    $phases = @{}
    foreach ($key in @(Get-ChildItem -Path $script:LegacyRootRegistryKey -ErrorAction SilentlyContinue)) {
        $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($values -and $values.PSObject.Properties['ResumePhase']) { $phases[$key.PSChildName] = [int]$values.ResumePhase }
    }
    return $phases
}

function Copy-LegacyRegistry {
    <#
      Records the new folder in the current user's registry, and every
      interrupted build's resume phase in its VM's folder, where the resume
      task, running as SYSTEM, reads it.
    #>
    param([Parameter(Mandatory)][string]$NewRoot)

    $phases = Get-LegacyResumePhase
    foreach ($name in $phases.Keys) {
        $file = Join-Path -Path $NewRoot -ChildPath "$name/$script:ConfigFolderName/$script:ResumeFileName"
        Set-ResumePhase -Path $file -Phase $phases[$name]
    }
    Set-RegisteredRoot -Path $NewRoot
    Write-LogEntry "Recorded $NewRoot in $script:RootRegistryKey" 'OK'
}

function Test-MachineWideModuleRemovable {
    <#
      Whether LazyVM 5's copy of the module, in $Path, can go: only when this
      LazyVM runs from the copy Install.ps1 put in %ProgramFiles%\LazyVM,
      which is kept, so LazyVM and its tasks still load afterwards.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $moduleBase = Get-LazyVMModuleBase
    return (-not (Test-PathWithin -Path $moduleBase -Folder $Path)) -and (Test-PathWithin -Path $moduleBase -Folder (Get-InstalledModuleFolder))
}

function Remove-LegacyRegistry {
    <#
      Removes what LazyVM 5 kept under HKLM: its Root value and its VMs'
      resume keys. The paths users allowed outside their LazyVM folders,
      under their security identifiers, stay.
    #>
    if (-not (Test-Path -LiteralPath $script:LegacyRootRegistryKey)) { return }
    Remove-ItemProperty -LiteralPath $script:LegacyRootRegistryKey -Name 'Root' -ErrorAction SilentlyContinue
    foreach ($key in @(Get-ChildItem -LiteralPath $script:LegacyRootRegistryKey -ErrorAction SilentlyContinue)) {
        if ($key.PSChildName -match '^S-1-') { continue }
        Remove-Item -LiteralPath $key.PSPath -Recurse -Force
    }
    Write-LogEntry "Removed LazyVM 5's entries from $script:LegacyRootRegistryKey" 'OK'
}

function Remove-LegacyInstallation {
    <#
      Removes what is left of the old install, once everything has moved:
      the old folder when it is empty (unless the data stayed in it),
      LazyVM 5's module copy when this LazyVM runs from its own install in
      Program Files and, last, LazyVM 5's entries under HKLM.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [switch]$InPlace
    )

    if (-not $InPlace -and (Test-Path -LiteralPath $OldRoot)) {
        $left = @(Get-ChildItem -LiteralPath $OldRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_ -is [IO.FileInfo] })
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $OldRoot -Recurse -Force
            Write-LogEntry "Removed the old folder $OldRoot" 'OK'
        }
        else {
            Write-LogEntry "$OldRoot still holds $($left.Count) file(s) that were not moved, so it is kept. Look through it, then delete it yourself." 'WARN'
        }
    }

    $machineWide = Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\Modules\LazyVM'
    if (Test-Path -LiteralPath $machineWide) {
        if (Test-MachineWideModuleRemovable -Path $machineWide) {
            Remove-Item -LiteralPath $machineWide -Recurse -Force
            Write-LogEntry "Removed the copy of LazyVM installed for every user, $machineWide" 'OK'
        }
        else {
            Write-LogEntry "Kept LazyVM 5's copy of the module, ${machineWide}: LazyVM is not running from $(Get-InstalledModuleFolder), where Install.ps1 puts it. Install LazyVM with Install.ps1, then delete that copy as administrator." 'WARN'
        }
    }

    Remove-LegacyRegistry
}

# ─────────────────────────────────────────────────────────────────────────────
#  THE WHOLE MIGRATION
# ─────────────────────────────────────────────────────────────────────────────
function Assert-MigrationTarget {
    <#
      Everything checked before Convert-LazyVMInstallation asks to go ahead:
      the new folder is not inside the old one or the other way round, it
      holds nothing else LazyVM would lock away, and no LazyVM task is
      running.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    if (-not (Test-SamePath -Path $OldRoot -Other $NewRoot) -and ((Test-PathWithin -Path $NewRoot -Folder $OldRoot) -or (Test-PathWithin -Path $OldRoot -Folder $NewRoot))) {
        throw "The new LazyVM folder, $NewRoot, cannot be inside the old one, $OldRoot, or the other way round. Choose another, such as $(Get-DefaultRoot)."
    }
    Assert-RootFolderUsable -Path $NewRoot
    Assert-NoRunningTask
}

function Invoke-InstallationMigration {
    <#
      Moves the install in $OldRoot to the current user, with its data in
      $NewRoot; with $NewRoot the same folder, the data stays where it is.
      Assert-MigrationTarget has checked the folders. The steps run in an
      order that keeps every VM and credential safe: the tasks first (so a
      nightly run cannot start mid-move), then the credentials, the VMs'
      files, the rest of the files, the registry, and the old install's
      leftovers last. Once the old folder is gone, a run again goes
      straight to the registry and the leftovers.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    $inPlace = Test-SamePath -Path $OldRoot -Other $NewRoot
    Initialize-RootFolder -Path $NewRoot
    Start-Log -Path "$($NewRoot.TrimEnd('\'))\$script:SharedFolderName\Logs\Migration.log" -MaxSizeMB 10
    try {
        Write-LogEntry "Moving LazyVM from every user to $(Get-CurrentUserName): $OldRoot -> $NewRoot" 'PHASE'
        Update-LegacyTask -OldRoot $OldRoot -NewRoot $NewRoot
        Convert-LegacyCredential -Root $OldRoot
        if (-not $inPlace) {
            if (Test-Path -LiteralPath $OldRoot) {
                Move-LegacyVMStorage -OldRoot $OldRoot -NewRoot $NewRoot
                Assert-NoVMFileLeft -OldRoot $OldRoot
                Dismount-LegacyDvdMedia -OldRoot $OldRoot -NewRoot $NewRoot
                Move-LegacyFile -OldRoot $OldRoot -NewRoot $NewRoot
            }
            Mount-MovedDvdMedia -OldRoot $OldRoot -NewRoot $NewRoot
        }
        Copy-LegacyRegistry -NewRoot $NewRoot
        # Again, now that everything is in it, so every file inherits it.
        Initialize-RootFolder -Path $NewRoot
        Remove-LegacyInstallation -OldRoot $OldRoot -InPlace:$inPlace
        Write-LogEntry "LazyVM is now yours, in $NewRoot, open to you and SYSTEM only" 'OK'
    }
    catch {
        Write-LogError 'Moving LazyVM stopped. What has moved stays moved; the old install''s registry key and module copy are kept. Fix the problem and run Convert-LazyVMInstallation again: it carries on where it stopped.' $_
        throw
    }
    finally {
        Stop-Log
    }
}
