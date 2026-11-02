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

function Get-LegacyRoot {
    <# The root folder a machine-wide install (before #284) recorded, or $null when there is none. #>
    $props = Get-ItemProperty -Path $script:LegacyRootRegistryKey -ErrorAction SilentlyContinue
    if ($props -and $props.PSObject.Properties['Root'] -and $props.Root) { return [string]$props.Root }
    return $null
}

function Assert-NoLegacyInstallation {
    <#
      Stops while a machine-wide install is still there: its VMs, encrypted
      passwords and tasks must be moved to this user first, or they would
      be hidden behind a new, empty LazyVM folder.
    #>
    $legacy = Get-LegacyRoot
    if ($legacy) {
        throw "LazyVM was installed for every user of this computer, with its VMs in $legacy. Move it to your Windows account first, in PowerShell 7 run as administrator: Convert-LazyVMInstallation"
    }
}

function Resolve-LazyVMRoot {
    <# The root folder for this run: -Root if given, else the registered one. #>
    param([string]$Root)

    Assert-NoLegacyInstallation
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

function Get-DefaultRoot {
    <# LazyVM in the user's profile folder (#284): the folder LazyVM uses when nobody has chosen one. #>
    return Join-Path -Path ([Environment]::GetFolderPath('UserProfile')) -ChildPath 'LazyVM'
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
