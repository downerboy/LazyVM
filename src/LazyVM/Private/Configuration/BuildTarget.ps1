# BuildTarget.ps1 - What Build-LazyVM sets up by itself on first use.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

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

function Initialize-BuildTarget {
    <#
      Everything Build-LazyVM needs before it can start, set up on first use
      so a single command is enough: the LazyVM folder, recorded once, and
      the VM's profile. Says what it set up.
    #>
    param([string]$Name)

    $root = Get-RegisteredRoot
    if (-not $root) {
        $root = Get-DefaultRoot
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-RegisteredRoot -Path $root
        Write-Information "LazyVM keeps its VMs in $root. To use another folder, run Set-LazyVMRoot first." -InformationAction Continue
    }

    $configDir = Get-ConfigDir -Root $root
    Initialize-ConfigFolder -ConfigDir $configDir

    $existing = @(Get-VMProfileName -ConfigDir $configDir)
    if ($Name) {
        if (-not ($existing | Where-Object { $_ -eq $Name })) {
            $null = New-VMProfile -ConfigDir $configDir -Name $Name
            Write-Information "Created the profile for '$Name'." -InformationAction Continue
        }
    }
    elseif ($existing.Count -eq 0) {
        throw 'Give the new VM a name, for example: Build-LazyVM -Name DevBox'
    }
}
