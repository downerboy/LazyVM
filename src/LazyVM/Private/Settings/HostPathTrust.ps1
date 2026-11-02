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

function Get-ForbiddenHostPathReason {
    <#
      Why $Path cannot be allowed for the scheduled tasks, which act on it as
      SYSTEM; $null when it can. A drive's root, the system folders and other
      users' profiles are never allowed.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $full = ConvertTo-FullPath -Path $Path
    if ($full -eq (ConvertTo-FullPath -Path ([IO.Path]::GetPathRoot($full)))) { return 'it is a whole drive' }
    $systemFolders = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
    foreach ($folder in $systemFolders) {
        if (Test-PathWithin -Path $full -Folder $folder) { return "it is in $folder" }
    }
    $profiles = Split-Path -Path $env:USERPROFILE -Parent
    if ((Test-PathWithin -Path $full -Folder $profiles) -and -not (Test-PathWithin -Path $full -Folder $env:USERPROFILE)) {
        return "it is in $profiles but not in your own profile"
    }
    return $null
}

function Register-TrustedHostPath {
    <#
      Allows the paths outside the LazyVM folder that $Settings name, for the
      user running LazyVM, elevated. Each new one is confirmed first: the
      scheduled tasks will write and delete there as SYSTEM.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $ownerSid = (Get-CurrentUserSid).Value
    $allowed = @(Get-TrustedHostPath -OwnerSid $ownerSid)
    $new = @(Get-OutsideHostPath -Settings $Settings | Where-Object {
            $path = $_.Path
            -not ($allowed | Where-Object { Test-SamePath -Path $path -Other $_ })
        })
    foreach ($item in $new) {
        $reason = Get-ForbiddenHostPathReason -Path $item.Path
        if ($reason) {
            throw "$($item.Name) of '$($Settings.VMName)' is $($item.Path), which cannot be allowed for LazyVM's scheduled tasks because $reason. Choose a folder of your own, such as one on a data drive or in your profile, in its settings."
        }
    }
    $confirmed = @($new | Where-Object {
            $PSCmdlet.ShouldProcess($_.Path, "Allow LazyVM's scheduled tasks, which run as SYSTEM, to write and delete in this folder for $($_.Name) of '$($Settings.VMName)'")
        })
    if ($confirmed.Count -eq 0) { return }
    Add-TrustedHostPath -OwnerSid $ownerSid -Path @($confirmed.Path)
    Write-LogEntry "Allowed for the scheduled tasks, outside the LazyVM folder: $(@($confirmed | ForEach-Object { "$($_.Name) ($($_.Path))" }) -join ', ')" 'INFO'
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
