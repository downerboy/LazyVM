# InstallMedia.ps1 - Build phases 3-4: the host folders, the Windows ISO and the SQL Server ISO.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The Windows ISO is found, never downloaded: Microsoft's evaluation link
# leads to a registration form, not the file. A file is taken as an ISO only
# when it has the ISO 9660 signature, not by its name or size alone. The SQL
# Server ISO, by contrast, is a direct download.

function Initialize-HostFolder {
    <# Phase 3: every folder on the host this VM uses. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $folders = @(
        $settings.Root
        $settings.ISOSearchRoot
        (Split-Path $settings.SQLIsoPath -Parent)
        $settings.VHDXRoot
        (Split-Path $settings.SQLDiskPath -Parent)
        $settings.CredStoreDir
        (Split-Path $settings.GuestCredFile -Parent)
        (Split-Path $settings.VSSettingsBackup -Parent)
        (Split-Path $settings.LogFile -Parent)
        $settings.CheckpointDir
    ) | Select-Object -Unique

    $created = @($folders | Where-Object { -not (Test-Path -LiteralPath $_) })
    foreach ($folder in $created) {
        New-Folder -Path $folder
        Write-LogEntry "Created : $folder" 'OK'
    }
    Write-LogEntry "$($folders.Count) folders verified, $($created.Count) created" 'OK'
}

function Test-WindowsIsoName {
    <#
      Whether a file name looks like the Windows 11 evaluation ISO, so a
      search of the Downloads folder never adopts some other ISO. Microsoft
      names it like ...CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso.
    #>
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -match '(?i)\.iso$' -and $Name -match '(?i)ENTERPRISEEVAL|Win(dows)?[ _.-]?11')
}

function Get-DownloadsFolder {
    <# The signed-in user's Downloads folder, wherever it has been moved to. #>
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $value = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($value) { return [Environment]::ExpandEnvironmentVariables($value) }
    return Join-Path -Path $env:USERPROFILE -ChildPath 'Downloads'
}

function Find-InstallationIso {
    <#
      Looks for the Windows ISO without changing anything: at ISOPath, else
      the newest valid image in the ISO folder, else the evaluation ISO in
      the user's Downloads folder. Returns the file and where it was found,
      or $null.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $minimum = $settings.ISOMinSizeGB * 1GB
    $isValid = { param($file) $file.Length -ge $minimum -and (Test-IsoFile -Path $file.FullName) }

    $configured = Get-Item -LiteralPath $settings.ISOPath -ErrorAction SilentlyContinue
    if ($configured -and (& $isValid $configured)) {
        return [pscustomobject]@{ File = $configured; Where = 'Configured' }
    }

    $inIsoFolder = @(Get-ChildItem -LiteralPath $settings.ISOSearchRoot -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { & $isValid $_ } | Sort-Object LastWriteTime -Descending)
    if ($inIsoFolder.Count -gt 0) {
        return [pscustomobject]@{ File = $inIsoFolder[0]; Where = 'IsoFolder' }
    }

    $downloaded = @(Get-ChildItem -LiteralPath (Get-DownloadsFolder) -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { (Test-WindowsIsoName -Name $_.Name) -and (& $isValid $_) } | Sort-Object LastWriteTime -Descending)
    if ($downloaded.Count -gt 0) {
        return [pscustomobject]@{ File = $downloaded[0]; Where = 'Downloads' }
    }
    return $null
}

function Initialize-InstallationIso {
    <#
      Makes sure the build has the Windows ISO and records where it is in
      $VM.Runtime.ISOPath. One found in Downloads is moved to ISOPath, where
      the scheduled runs, which run as SYSTEM and cannot see anyone's
      Downloads, find it later. With none anywhere, opens the download page
      for whoever is there, and stops.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    $found = Find-InstallationIso -VM $VM
    if ($found -and $found.Where -eq 'Downloads') {
        New-Folder -Path (Split-Path -Path $settings.ISOPath -Parent)
        Write-LogEntry "Moving the Windows ISO from $($found.File.DirectoryName) to $($settings.ISOPath), where the scheduled rebuilds can find it..." 'INFO'
        Move-Item -LiteralPath $found.File.FullName -Destination $settings.ISOPath
        $found = [pscustomobject]@{ File = Get-Item -LiteralPath $settings.ISOPath; Where = 'Configured' }
    }
    if ($found) {
        $VM.Runtime.ISOPath = $found.File.FullName
        Write-LogEntry "Windows ISO - OK ($(Format-Size $found.File.Length)) at $($found.File.FullName)" 'OK'
        return
    }

    $downloads = Get-DownloadsFolder
    Write-LogEntry 'No Windows 11 Enterprise evaluation ISO was found.' 'ERROR'
    Write-LogEntry '  It cannot be downloaded automatically: the download is behind a registration form.' 'INFO'
    Write-LogEntry "  Download it from $($settings.ISODownloadPage)" 'INFO'
    Write-LogEntry '  into your Downloads folder, then run the same Build-LazyVM command again.' 'INFO'

    # Someone is at the keyboard, so take them straight to the form. A
    # scheduled run has nobody to read the page and skips this.
    if (-not (Test-Unattended)) {
        try {
            Start-Process -FilePath $settings.ISODownloadPage
            Write-LogEntry '  The download page has been opened in your browser.' 'INFO'
        }
        catch {
            Write-LogEntry "  Could not open the download page: $($_.Exception.Message)" 'WARN'
        }
    }
    throw "No Windows ISO yet. Download it into $downloads, then run Build-LazyVM again."
}

function Initialize-SqlServerIso {
    <#
      Phase 4: the SQL Server installation media, downloaded to the host once
      and mounted in the guest at install time. Full media rather than the
      web installer: Microsoft retires web installer builds, and a retired one
      shows a modal dialog even with /QUIET, which in an unattended guest
      waits, unseen, until the install times out.

      The download goes to a .tmp file and is checked before it replaces the
      existing copy, so a failed download never destroys a good one.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $settings = $VM.Settings
    if (Test-IsoFile -Path $settings.SQLIsoPath) {
        Write-LogEntry "SQL Server ISO - OK ($(Format-Size (Get-Item -LiteralPath $settings.SQLIsoPath).Length)) at $($settings.SQLIsoPath)" 'OK'
        return
    }

    if (Test-Path -LiteralPath $settings.SQLIsoPath) {
        Write-LogEntry 'SQL Server ISO - present but not a valid image; downloading it again' 'WARN'
    }
    else {
        Write-LogEntry 'SQL Server ISO - not found; downloading (a few GB, this can take a while)' 'INFO'
    }

    $temp = "$($settings.SQLIsoPath).tmp"
    try {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        # The progress bar slows a multi-gigabyte download to a crawl.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $settings.SQLIsoUrl -OutFile $temp -UseBasicParsing
        if (-not (Test-IsoFile -Path $temp)) {
            throw "the downloaded file is not an ISO image (got $(Format-Size (Get-Item -LiteralPath $temp).Length) - the address probably returned a web page)"
        }
        Move-Item -LiteralPath $temp -Destination $settings.SQLIsoPath -Force
        Write-LogEntry "SQL Server ISO - downloaded ($(Format-Size (Get-Item -LiteralPath $settings.SQLIsoPath).Length))" 'OK'
    }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-LogError 'SQL Server ISO - download failed' $_
        throw "Cannot continue without the SQL Server ISO. Download it from $($settings.SQLIsoUrl) and save it to $($settings.SQLIsoPath)."
    }
}
