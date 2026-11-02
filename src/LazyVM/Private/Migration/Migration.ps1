# Migration.ps1 - Convert-LazyVMInstallation: a machine-wide install moved to the current user (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Before #284, LazyVM was installed for every user: its folder (C:\LazyVM by
# default) and registry key (HKLM) were shared, its tasks ran as SYSTEM and
# its credentials were encrypted with a key file every administrator could
# read. Each step here first looks at what is already done, so running the
# migration again after an interruption carries on where it stopped. Nothing
# of the old install is removed until every step has succeeded, and the HKLM
# key, which marks the install as not yet moved, goes last.

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
    Write-LogEntry "$converted credential file(s) re-encrypted for $(Get-TaskUserName) only" 'OK'

    foreach ($keyPath in $keyPaths) {
        if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
            Remove-Item -LiteralPath $keyPath -Force
            Write-LogEntry "Deleted the old credential key $keyPath" 'OK'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  TASKS: SYSTEM -> the current user
# ─────────────────────────────────────────────────────────────────────────────
function Assert-NoRunningTask {
    <# Stops while a LazyVM task is running: it would work on files while they move. #>
    $running = @(Get-ScheduledTask -TaskName "$script:TaskPrefix*" -ErrorAction SilentlyContinue | Where-Object { "$($_.State)" -eq 'Running' })
    if ($running.Count -gt 0) {
        throw "LazyVM's task '$($running[0].TaskName)' is running. Wait until it has finished, then run Convert-LazyVMInstallation again."
    }
}

function Move-LegacyTask {
    <#
      Re-registers each LazyVM task that runs as SYSTEM to run as the
      current user, with the same actions, triggers and settings. A task of
      the same name replaces it in one step. Tasks of other users are left
      alone.
    #>
    $system = 'SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18'
    foreach ($task in @(Get-ScheduledTask -TaskName "$script:TaskPrefix*" -ErrorAction SilentlyContinue)) {
        if ($system -notcontains "$($task.Principal.UserId)") { continue }
        Register-LazyVMHostTask -TaskName $task.TaskName -Action $task.Actions -Trigger $task.Triggers -Settings $task.Settings
        Write-LogEntry "Task '$($task.TaskName)' now runs as $(Get-TaskUserName) instead of SYSTEM" 'OK'
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
    return $NewRoot.TrimEnd('\') + $Path.TrimEnd('\').Substring($OldRoot.TrimEnd('\').Length)
}

function Get-FolderSize {
    <# The bytes in every file under $Path. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Path)

    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [long]$sum
}

function Get-FreeSpace {
    <# The bytes free on the drive that holds $Path. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Path)

    return [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).AvailableFreeSpace
}

function Move-LegacyVMStorage {
    <#
      Moves the files of every Hyper-V VM kept in $OldRoot - configuration,
      checkpoints, smart paging and disks - to the same places under
      $NewRoot, with Hyper-V's storage migration, so a running VM keeps
      running and Hyper-V gives each VM access to its files again. Hyper-V
      copies the files, so the drive needs room for the VM a second time.
      A VM with nothing left in $OldRoot is skipped.
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

        $needed = Get-FolderSize -Path $machine.ConfigurationLocation
        $free = Get-FreeSpace -Path $NewRoot
        if ($free -lt $needed) {
            throw "Not enough free space to move $($machine.Name): Hyper-V copies its files, which needs $(Format-Size $needed) free on the drive of $NewRoot, and $(Format-Size $free) is free. Make room, then run Convert-LazyVMInstallation again."
        }
        Write-LogEntry "Moving $($machine.Name)'s files to $NewRoot with Hyper-V ($(Format-Size $needed)); the VM keeps running..." 'INFO'
        Move-VMStorage -VMName $machine.Name @move -ErrorAction Stop
        Write-LogEntry "Moved $($machine.Name)'s files" 'OK'
    }
}

function Assert-NoVMFileLeft {
    <#
      Stops when a Hyper-V VM still uses a disk in $OldRoot after the storage
      migration - a disk attached now or to a checkpoint, or the parent of a
      checkpoint's differencing disk - so no file a VM needs is moved behind
      Hyper-V's back.
    #>
    param([Parameter(Mandatory)][string]$OldRoot)

    foreach ($machine in @(Get-VM)) {
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

function Dismount-LegacyDvdMedia {
    <# Ejects every ISO a VM has attached from $OldRoot, so its file can move. Returns the drives, to attach again. #>
    param([Parameter(Mandatory)][string]$OldRoot)

    $media = @(foreach ($machine in @(Get-VM)) {
            Get-VMDvdDrive -VMName $machine.Name | Where-Object { $_.Path -and (Test-PathWithin -Path $_.Path -Folder $OldRoot) }
        })
    foreach ($drive in $media) {
        Set-VMDvdDrive -VMName $drive.VMName -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -Path $null -ErrorAction Stop
        Write-LogEntry "Ejected $($drive.Path) from $($drive.VMName) to move it" 'INFO'
    }
    return $media
}

function Mount-MovedDvdMedia {
    <# Attaches each ISO Dismount-LegacyDvdMedia ejected again, from its place under $NewRoot. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Media,
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    foreach ($drive in $Media) {
        $path = ConvertTo-NewRootPath -Path $drive.Path -OldRoot $OldRoot -NewRoot $NewRoot
        Set-VMDvdDrive -VMName $drive.VMName -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -Path $path -ErrorAction Stop
        Write-LogEntry "Attached $path to $($drive.VMName) again" 'OK'
    }
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
    foreach ($file in $files) {
        $target = $NewRoot.TrimEnd('\', '/') + $file.FullName.Substring($OldRoot.TrimEnd('\', '/').Length)
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
    <# Records the new folder, and every interrupted build's resume phase, in the current user's registry. #>
    param([Parameter(Mandatory)][string]$NewRoot)

    $phases = Get-LegacyResumePhase
    foreach ($name in $phases.Keys) {
        Set-ResumePhase -Key "$script:RootRegistryKey\$name" -Phase $phases[$name]
    }
    Set-RegisteredRoot -Path $NewRoot
    Write-LogEntry "Recorded $NewRoot in $script:RootRegistryKey" 'OK'
}

function Remove-LegacyInstallation {
    <#
      Removes what is left of the old install, once everything has moved:
      the old folder when it is empty, the module copy in Program Files and,
      last, the HKLM key.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    if (-not $OldRoot.TrimEnd('\').Equals($NewRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $OldRoot)) {
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
        Remove-Item -LiteralPath $machineWide -Recurse -Force
        Write-LogEntry "Removed the copy of LazyVM installed for every user, $machineWide" 'OK'
    }

    if (Test-Path -LiteralPath $script:LegacyRootRegistryKey) {
        Remove-Item -LiteralPath $script:LegacyRootRegistryKey -Recurse -Force
        Write-LogEntry "Removed $script:LegacyRootRegistryKey" 'OK'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  THE WHOLE MIGRATION
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-InstallationMigration {
    <#
      Moves the install in $OldRoot to the current user, with its data in
      $NewRoot; with $NewRoot the same folder, the data stays where it is.
      The steps run in an order that keeps every VM and credential safe:
      the tasks first (so a nightly run cannot start mid-move), then the
      credentials, the VMs' files, the rest of the files, the registry,
      and the old install's leftovers last.
    #>
    param(
        [Parameter(Mandatory)][string]$OldRoot,
        [Parameter(Mandatory)][string]$NewRoot
    )

    $inPlace = $OldRoot.TrimEnd('\').Equals($NewRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    if (-not $inPlace -and ((Test-PathWithin -Path $NewRoot -Folder $OldRoot) -or (Test-PathWithin -Path $OldRoot -Folder $NewRoot))) {
        throw "The new LazyVM folder, $NewRoot, cannot be inside the old one, $OldRoot, or the other way round. Choose another, such as $(Get-DefaultRoot)."
    }

    Assert-NoRunningTask
    Initialize-RootFolder -Path $NewRoot
    Start-Log -Path "$($NewRoot.TrimEnd('\'))\$script:SharedFolderName\Logs\Migration.log" -MaxSizeMB 10
    try {
        Write-LogEntry "Moving LazyVM from every user to $(Get-TaskUserName): $OldRoot -> $NewRoot" 'PHASE'
        Move-LegacyTask
        Convert-LegacyCredential -Root $OldRoot
        if (-not $inPlace) {
            Move-LegacyVMStorage -OldRoot $OldRoot -NewRoot $NewRoot
            Assert-NoVMFileLeft -OldRoot $OldRoot
            $media = @(Dismount-LegacyDvdMedia -OldRoot $OldRoot)
            Move-LegacyFile -OldRoot $OldRoot -NewRoot $NewRoot
            Mount-MovedDvdMedia -Media $media -OldRoot $OldRoot -NewRoot $NewRoot
        }
        Copy-LegacyRegistry -NewRoot $NewRoot
        # Again, now that everything is in it, so every file inherits it.
        Initialize-RootFolder -Path $NewRoot
        Remove-LegacyInstallation -OldRoot $OldRoot -NewRoot $NewRoot
        Write-LogEntry "LazyVM is now yours alone, in $NewRoot" 'OK'
    }
    catch {
        Write-LogError 'Moving LazyVM stopped; nothing of the old install was removed. Fix the problem and run Convert-LazyVMInstallation again: it carries on where it stopped.' $_
        throw
    }
    finally {
        Stop-Log
    }
}
