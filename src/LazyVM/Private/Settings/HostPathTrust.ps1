# HostPathTrust.ps1 - The paths outside the LazyVM folder an administrator has allowed (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A VM's settings, in the user's own folder, can name a full path outside
# the LazyVM folder, such as E:\Backups for BackupDir. LazyVM's scheduled
# tasks act on those paths as SYSTEM, so an unattended run uses only those
# the owner allowed while elevated: Build-LazyVM and
# Register-LazyVMMaintenance record them under HKLM, where only an
# administrator can write. Anything else outside the folder stops the run.

function Get-OutsideHostPath {
    <# Each host path setting in $Settings that names a place outside the LazyVM folder, with its setting's name. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    foreach ($name in @($script:HostPathSettings) + 'BackupDir') {
        $path = [string]$Settings[$name]
        if ($path -and -not (Test-PathWithin -Path $path -Folder $Settings.Root)) {
            [pscustomobject]@{ Name = $name; Path = $path }
        }
    }
}

function Get-TrustedHostPathKey {
    <# Where the paths outside the LazyVM folder its owner allowed are kept: under HKLM, which only an administrator can change. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$OwnerSid)

    return "$script:MachineRegistryKey\$OwnerSid\HostPaths"
}

function Get-TrustedHostPath {
    <# The paths outside the LazyVM folder the owner $OwnerSid allowed. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$OwnerSid)

    $values = Get-ItemProperty -Path (Get-TrustedHostPathKey -OwnerSid $OwnerSid) -ErrorAction SilentlyContinue
    if ($values -and $values.PSObject.Properties['Paths']) { return @($values.Paths) }
    return @()
}

function Add-TrustedHostPath {
    <# Allows $Path, for the owner $OwnerSid, beside what was allowed before. #>
    param(
        [Parameter(Mandatory)][string]$OwnerSid,
        [Parameter(Mandatory)][string[]]$Path
    )

    $key = Get-TrustedHostPathKey -OwnerSid $OwnerSid
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-TrustedHostPath -OwnerSid $OwnerSid) + $Path) {
        if (-not ($paths | Where-Object { Test-SamePath -Path $_ -Other $item })) { $paths.Add($item) }
    }
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -LiteralPath $key -Name 'Paths' -Value ([string[]]$paths) -Type MultiString
}

function Register-TrustedHostPath {
    <# Allows the paths outside the LazyVM folder that $Settings name, for the user running LazyVM, elevated. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $outside = @(Get-OutsideHostPath -Settings $Settings)
    if ($outside.Count -eq 0) { return }
    Add-TrustedHostPath -OwnerSid (Get-CurrentUserSid).Value -Path @($outside.Path)
    Write-LogEntry "Allowed for the scheduled tasks, outside the LazyVM folder: $(@($outside | ForEach-Object { "$($_.Name) ($($_.Path))" }) -join ', ')" 'INFO'
}

function Assert-HostPathTrusted {
    <#
      Stops an unattended run when a setting names a place outside the
      LazyVM folder that the owner $OwnerSid has not allowed.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    $allowed = @(Get-TrustedHostPath -OwnerSid $OwnerSid)
    $refused = @(Get-OutsideHostPath -Settings $Settings | Where-Object {
            $path = $_.Path
            -not ($allowed | Where-Object { Test-PathWithin -Path $path -Folder $_ })
        })
    if ($refused.Count -gt 0) {
        $list = @($refused | ForEach-Object { "$($_.Name) ($($_.Path))" }) -join ', '
        throw "The settings of '$($Settings.VMName)' name places outside the LazyVM folder that no administrator has allowed, so this unattended run stops: $list. If they are yours, allow them by running, in PowerShell 7 as administrator: Register-LazyVMMaintenance -Name $($Settings.VMName)"
    }
}
