# Root.ps1 - The LazyVM folder: the one folder that holds everything on the host.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Chosen once and stored in the registry; a -Root parameter, where a command
# offers one, overrides it for that run. Host paths in the settings are
# relative to it unless written as full paths (E:\VMs), which is how one
# large item can live on another drive.

function Test-FullHostPath {
    <# True for D:\folder or \\server\share; false for anything relative. #>
    param([string]$Path)

    return ($Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]')
}

function Resolve-SettingsRoot {
    <# Checks a root folder is usable and returns it in a standard form. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    $root = $Path.Trim().TrimEnd('\')

    # A folder on a local drive, not the top of a drive: Hyper-V disks belong
    # on local storage, and a bare drive root would scatter folders across it.
    # Double quotes are refused because the path is quoted into the
    # scheduled-task command lines.
    if ($root -notmatch '^[A-Za-z]:\\[^\\]' -or $root.Contains('"')) {
        throw "The LazyVM folder must be a folder on a local drive, such as D:\DevVM. Got '$Path' from $Source."
    }
    return $root
}

function Get-RegisteredRoot {
    <# The root folder recorded in the registry, or $null if none has been. #>
    $props = Get-ItemProperty -Path $script:RootRegistryKey -ErrorAction SilentlyContinue
    if ($props -and $props.PSObject.Properties['Root'] -and $props.Root) { return [string]$props.Root }
    return $null
}

function Set-RegisteredRoot {
    <# Records the root folder for every later run. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $script:RootRegistryKey)) {
        New-Item -Path $script:RootRegistryKey -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RootRegistryKey -Name 'Root' -Value $Path -Type String
}

function Resolve-LazyVMRoot {
    <# The root folder for this run: -Root if given, else the registered one. #>
    param([string]$Root)

    if ($Root) {
        $source = 'the -Root parameter'
        return [pscustomobject]@{ Path = Resolve-SettingsRoot -Path $Root -Source $source; Source = $source }
    }
    $registered = Get-RegisteredRoot
    if ($registered) {
        $source = "the registry ($script:RootRegistryKey)"
        return [pscustomobject]@{ Path = Resolve-SettingsRoot -Path $registered -Source $source; Source = $source }
    }
    throw "LazyVM does not know which folder to keep its VMs in yet. Choose one with: Set-LazyVMRoot -Path D:\DevVM"
}

function Select-RootVolume {
    <#
      The volume LazyVM's folder goes on when nobody has chosen one: the
      local NTFS volume with the most free space, leaving out volumes on a
      virtual disk (a VHD-backed drive is not there until something mounts
      it, so after a restart the VMs would have no disks). Returns $null when
      there is none.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes)

    return $Volumes |
        Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' -and -not $_.IsVirtual } |
        Sort-Object -Property SizeRemaining -Descending |
        Select-Object -First 1
}

function Get-DefaultRoot {
    <# <drive>:\LazyVM on the volume Select-RootVolume picks. #>
    $volumes = foreach ($volume in Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }) {
        $disk = Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DriveLetter   = $volume.DriveLetter
            FileSystem    = $volume.FileSystem
            SizeRemaining = $volume.SizeRemaining
            IsVirtual     = ($disk -and "$($disk.BusType)" -eq 'File Backed Virtual')
        }
    }

    $chosen = Select-RootVolume -Volumes @($volumes)
    if (-not $chosen) {
        throw 'No local NTFS drive was found for LazyVM''s VMs. Choose a folder with: Set-LazyVMRoot -Path D:\DevVM'
    }
    return "$($chosen.DriveLetter):\LazyVM"
}
