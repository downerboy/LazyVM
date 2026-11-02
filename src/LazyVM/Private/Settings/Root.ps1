# Root.ps1 - The LazyVM folder: the one folder that holds everything on the host.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Chosen once and stored in the registry; a -Root parameter, where a command
# offers one, overrides it for that run. Host paths in the settings are
# relative to it unless written as full paths (E:\VMs), which is how one
# large item can live on another drive.
#
# The folder is open to the user who installed LazyVM and SYSTEM only (#284).

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
    # Quotes are refused because the path is quoted into the
    # scheduled-task command lines.
    if ($root -notmatch '^[A-Za-z]:\\[^\\]' -or $root.Contains('"') -or $root.Contains("'")) {
        throw "The LazyVM folder must be a folder on a local drive, such as D:\DevVM. Got '$Path' from $Source."
    }
    return $root
}

function Get-RegisteredRoot {
    <#
      The root folder recorded under $Key, or $null if none has been: the
      current user's by default, or $script:LegacyRootRegistryKey for a
      machine-wide install from before #284.
    #>
    param([string]$Key = $script:RootRegistryKey)

    $props = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
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

function Assert-NoLegacyInstallation {
    <#
      Stops while a machine-wide install is still there: its VMs, encrypted
      passwords and tasks must be moved to this user first, or they would
      be hidden behind a new, empty LazyVM folder.
    #>
    $legacy = Get-RegisteredRoot -Key $script:LegacyRootRegistryKey
    if ($legacy) {
        throw "LazyVM was installed for every user of this computer, with its VMs in $legacy. Move it to your Windows account first, in PowerShell 7 run as administrator: Convert-LazyVMInstallation"
    }
}

function Resolve-LazyVMRoot {
    <#
      The root folder for this run: -Root if given, which must be locked to
      its owner ($OwnerSid, or else the account running LazyVM) and SYSTEM;
      else the registered one.
    #>
    param(
        [string]$Root,
        [string]$OwnerSid
    )

    Assert-NoLegacyInstallation
    if ($Root) {
        $source = 'the -Root parameter'
        $path = Resolve-SettingsRoot -Path $Root -Source $source
        $owner = if ($OwnerSid) { $OwnerSid } else { (Get-CurrentUserSid).Value }
        Assert-RootLocked -Root $path -OwnerSid $owner
        return [pscustomobject]@{ Path = $path; Source = $source }
    }
    $registered = Get-RegisteredRoot
    if ($registered) {
        $source = "the registry ($script:RootRegistryKey)"
        return [pscustomobject]@{ Path = Resolve-SettingsRoot -Path $registered -Source $source; Source = $source }
    }
    throw "LazyVM does not know which folder to keep its VMs in yet. Choose one with: Set-LazyVMRoot -Path D:\DevVM"
}

function Get-RootAccess {
    <# Who the LazyVM folder at $Root lets in, as security identifiers, and whether it inherits access from the folder above. #>
    param([Parameter(Mandatory)][string]$Root)

    $acl = Get-Acl -LiteralPath $Root
    return [pscustomobject]@{
        Protected = $acl.AreAccessRulesProtected
        Sids      = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                Where-Object { "$($_.AccessControlType)" -eq 'Allow' } |
                ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique)
    }
}

function Assert-RootLocked {
    <#
      Stops unless $Root is a LazyVM folder locked as Initialize-RootFolder
      leaves it for $OwnerSid: it is not a reparse point, its settings file
      is there, it inherits nothing, and it is open to SYSTEM and $OwnerSid
      only. Checked when a command is handed the folder with -Root, as the
      scheduled tasks are; their command names the owner too, and only an
      administrator can change it.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    if ((Test-Path -LiteralPath $Root) -and (Test-ReparsePoint -Path $Root)) {
        throw "$Root is a reparse point (a junction or link), so LazyVM will not use it as its folder."
    }

    $settings = Join-Path -Path $Root -ChildPath "$script:SharedFolderName/$script:ConfigFolderName/$script:SettingsFileName"
    if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
        throw "$Root is not a LazyVM folder: it has no $script:SharedFolderName\$script:ConfigFolderName\$script:SettingsFileName."
    }
    $access = Get-RootAccess -Root $Root
    $others = @($access.Sids | Where-Object { $_ -ne 'S-1-5-18' })
    if (-not $access.Protected -or $others.Count -ne 1 -or $others[0] -ne $OwnerSid) {
        throw "$Root is not locked to its owner and SYSTEM, so LazyVM will not use it. As the user it belongs to, lock it with: Set-LazyVMRoot -Path $Root"
    }
}

function Test-CloudSyncedPath {
    <#
      Whether $Path is in a folder OneDrive (or another cloud service)
      keeps in step: under the OneDrive folders Windows names, or in a
      folder marked as a cloud file. Files there can be online-only, so a
      task running while signed out or offline cannot open them, and they
      are copied to the cloud and other computers.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    foreach ($folder in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ })) {
        if (Test-PathWithin -Path $Path -Folder $folder) { return $true }
    }
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (Test-CloudFileAttribute -Attributes ([long](Get-Item -LiteralPath $current -Force).Attributes)) { return $true }
        }
        $parent = Split-Path -Path $current -Parent
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Test-CloudFileAttribute {
    <# Whether file attributes mark a cloud file: pinned, unpinned (online-only), or recalled on open or on access. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][long]$Attributes)

    # FILE_ATTRIBUTE_PINNED 0x80000, UNPINNED 0x100000, RECALL_ON_OPEN 0x40000, RECALL_ON_DATA_ACCESS 0x400000.
    return ($Attributes -band 0x5C0000) -ne 0
}

function Get-DefaultRoot {
    <# LazyVM in the user's profile folder (#284): the folder LazyVM uses when nobody has chosen one. #>
    return Join-Path -Path ([Environment]::GetFolderPath('UserProfile')) -ChildPath 'LazyVM'
}

function Get-CurrentUserName {
    <# The Windows account running LazyVM, as DOMAIN\user or COMPUTER\user. #>
    [OutputType([string])]
    param()

    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-CurrentUserSid {
    <# The security identifier of the Windows account running LazyVM. #>
    [OutputType([System.Security.Principal.SecurityIdentifier])]
    param()

    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User
}

function New-RootFolderSecurity {
    <#
      The access the LazyVM folder gets (#284): full control for $User and
      SYSTEM, inherited by everything in it, and nothing inherited from the
      folder above, so no other account, local administrators included, is
      let in. $User owns it. Hyper-V adds each VM's own access to its files.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a value; changes nothing.')]
    [OutputType([System.Security.AccessControl.DirectorySecurity])]
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$User)

    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($User)
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($account in $User, $system) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($account,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow))
    }
    return $security
}

function Assert-RootFolderUsable {
    <#
      Stops for a folder in OneDrive, and before LazyVM locks a folder that
      holds anything else: locked,
      it would be open to the current user and SYSTEM only, shutting every
      other account out of what is in it. A folder that is not there yet, an
      empty one, a LazyVM folder (with Shared\Config\LazyVM.Settings.json) and
      the folder LazyVM already uses, for this user or a machine-wide
      install, are fine.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-CloudSyncedPath -Path $Path) {
        throw "$Path is in OneDrive (or another folder kept in step with the cloud). LazyVM's disks and secrets must stay on this computer, and its tasks must open them while you are signed out. Choose a folder outside it, such as $(Get-DefaultRoot)."
    }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) { return }
    $settings = Join-Path -Path $Path -ChildPath "$script:SharedFolderName/$script:ConfigFolderName/$script:SettingsFileName"
    if (Test-Path -LiteralPath $settings -PathType Leaf) { return }
    foreach ($key in $script:RootRegistryKey, $script:LegacyRootRegistryKey) {
        $registered = Get-RegisteredRoot -Key $key
        if ($registered -and (Test-SamePath -Path $registered -Other $Path)) { return }
    }
    throw "$Path already holds other files. LazyVM would lock it to you and SYSTEM only, shutting everyone else out of them. Choose an empty or new folder, such as $(Get-DefaultRoot)."
}

function Initialize-RootFolder {
    <#
      Creates the LazyVM folder with the access New-RootFolderSecurity gives,
      in one step, so it is never open to anyone else even for a moment; or
      gives an existing folder that access, which everything in it then
      inherits.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $security = New-RootFolderSecurity -User (Get-CurrentUserSid)
    if (Test-Path -LiteralPath $Path) {
        Set-Acl -LiteralPath $Path -AclObject $security
        return
    }
    $null = [System.IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), $security)
}
