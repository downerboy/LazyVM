#Requires -Version 7.6
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs LazyVM from a release download.

.DESCRIPTION
Copies the LazyVM module beside this script to %ProgramFiles%\LazyVM\Modules
and adds that folder to your PSModulePath (once), so PowerShell 7 finds
LazyVM. The folder %ProgramFiles%\LazyVM is locked: administrators and
SYSTEM can change it, you can read and run it, and nobody else can open
it. LazyVM's scheduled tasks run this module as SYSTEM, so nobody but an
administrator may be able to change it. An earlier copy of the same version
is replaced, and other versions there are removed.

Earlier copies that PowerShell would load instead are removed, and each
removal is listed: the ones an earlier LazyVM 6 put in
%LOCALAPPDATA%\LazyVM\Modules or Documents\PowerShell\Modules, and LazyVM 5's,
in %ProgramFiles%\PowerShell\Modules. While LazyVM 5's VMs are not moved to
you yet, its copy is moved to %ProgramFiles%\LazyVM\Legacy instead, where
PowerShell does not load it, and Install.ps1 says to run
Convert-LazyVMInstallation, which deletes it once it has moved them. Until
then, LazyVM 5's scheduled tasks fail.

Only a folder that holds nothing but LazyVM version folders is removed or
moved, and none that is, holds, or is reached through a junction, link or
cloud placeholder: such a copy is kept, with a warning, and links are
never followed. A copy that cannot go is named, and the install still
finishes. Then Install.ps1 checks that PowerShell loads the version it
installed, and warns with the path of any copy that still comes first.

Files downloaded from the internet are marked as such, and PowerShell will
not load a marked module, so the copies are unblocked as they are installed.

Run it in PowerShell 7 (pwsh) as administrator, signed in as the Windows
user who will use LazyVM (approve the UAC prompt with your own account).

.PARAMETER Path
The folder that holds the LazyVM module folder. By default, this script's
own folder, as in a release download.

.EXAMPLE
.\Install.ps1

Installs from a release download.

.EXAMPLE
./src/Install.ps1 -Path out

Installs the module Invoke-AnalyzerAndTest.ps1 assembled from the repository.
#>
[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$moduleName = 'LazyVM'

function Add-PathListEntry {
    <#
      $List (folders separated by ;) with $Entry added at the end, or as it
      is when it has $Entry already, in any case, with or without a trailing
      backslash, or written with environment variables.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$List,
        [Parameter(Mandatory)][string]$Entry
    )

    $entries = @($List -split ';' | Where-Object { $_ })
    foreach ($existing in $entries) {
        if (Test-SameFolder -Path $existing -Other $Entry) { return $List }
    }
    return (@($entries) + $Entry) -join ';'
}

function Remove-PathListEntry {
    <# $List (folders separated by ;) without $Entry, however it is written there. #>
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$List,
        [Parameter(Mandatory)][string]$Entry
    )

    return @($List -split ';' | Where-Object { $_ -and -not (Test-SameFolder -Path $_ -Other $Entry) }) -join ';'
}

function Test-SameFolder {
    <# Whether $Path, environment variables expanded, names the folder $Other, in any case, with or without a trailing backslash. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Other
    )

    return [Environment]::ExpandEnvironmentVariables($Path).TrimEnd('\') -ieq $Other.TrimEnd('\')
}

function Update-UserModulePath {
    <#
      Changes the user's PSModulePath, kept in HKCU\Environment as it is,
      unexpanded entries included, with $Change (the value in, the value
      out), and tells running programs when it changed. PowerShell 7 adds the
      user's entries to the machine's when it starts.
    #>
    param([Parameter(Mandatory)][scriptblock]$Change)

    $environment = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$environment.GetValue('PSModulePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $updated = & $Change $current
        if ($updated -eq $current) { return }
        $kind = if ($current) { $environment.GetValueKind('PSModulePath') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $environment.SetValue('PSModulePath', $updated, $kind)
        Send-EnvironmentChange
    }
    finally { $environment.Dispose() }
}

function Send-EnvironmentChange {
    <# Tells running programs, Explorer among them, that the user's environment changed, so new windows see it. #>
    Add-Type -Namespace LazyVMInstall -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 seconds.
    $null = [LazyVMInstall.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

function Test-ReparsePoint {
    <#
      Whether the file or folder at $Path is a reparse point: a junction, a
      symbolic link, or a cloud placeholder. Kept in step with
      Test-ReparsePoint in src\LazyVM\Private\Common\PathSafety.ps1:
      Install.ps1 runs before the module is loaded.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    return ([long](Get-Item -LiteralPath $Path -Force).Attributes -band [long][IO.FileAttributes]::ReparsePoint) -ne 0
}

function Test-ContainsReparsePoint {
    <#
      Whether a folder from the drive's root down to $Path, $Path itself, or
      anything in it is a reparse point. The folders above are checked
      first, and links inside are not followed. Kept in step with
      Test-ContainsReparsePoint in src\LazyVM\Private\Common\PathSafety.ps1.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $current = [IO.Path]::GetPathRoot($full)
    foreach ($name in @($full.Substring($current.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path -Path $current -ChildPath $name
        if (Test-ReparsePoint -Path $current) { return $true }
    }
    return @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { Test-ReparsePoint -Path $_.FullName }).Count -gt 0
}

function Test-ModuleCopy {
    <#
      Whether $Path looks like a LazyVM module folder: named LazyVM, and
      holding only version folders, each with LazyVM.psd1. Nothing else is
      deleted or moved as an earlier copy.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if ((Split-Path -Path $Path -Leaf) -ne 'LazyVM') { return $false }
    $unexpected = Get-ChildItem -LiteralPath $Path -Force | Where-Object {
        -not ($_.PSIsContainer -and $_.Name -as [version] -and (Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'LazyVM.psd1') -PathType Leaf))
    }
    return @($unexpected).Count -eq 0
}

function Get-EarlierCopyProblem {
    <# Why the earlier copy $Path must not be deleted or moved, or nothing when it may. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-ContainsReparsePoint -Path $Path) {
        return 'it, a folder above it, or something in it is a junction, link or cloud placeholder, which Install.ps1 does not follow'
    }
    if (-not (Test-ModuleCopy -Path $Path)) {
        return 'it is not a LazyVM module folder, holding only version folders with LazyVM.psd1'
    }
}

function Remove-EarlierCopy {
    <#
      Deletes the earlier LazyVM module folder $Path, if there is one, or,
      with -Except, every version in it but that one, and lists each. When
      it must not, or the delete fails, warns with the path instead, so the
      install still finishes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Except
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $problem = Get-EarlierCopyProblem -Path $Path
        if ($problem) {
            Write-Warning "Kept the earlier copy in ${Path}: $problem. Look at it and delete it yourself, as administrator."
            return
        }
        $removals = if ($Except) { @(Get-ChildItem -LiteralPath $Path -Directory -Force | Where-Object { $_.Name -ne $Except } | ForEach-Object { $_.FullName }) } else { @($Path) }
        foreach ($removal in $removals) {
            Remove-Item -LiteralPath $removal -Recurse -Force
            Write-Information "Removed the earlier copy in $removal" -InformationAction Continue
        }
    }
    catch {
        Write-Warning "Could not remove the earlier copy in ${Path}: $($_.Exception.Message) Delete it yourself, as administrator."
    }
}

function Move-EarlierCopy {
    <#
      Moves LazyVM 5's module folder $Path to $Destination, which is not on
      PSModulePath, so it no longer loads instead and Convert-LazyVMInstallation
      still has it. When it must not, or the move fails, warns with the path
      instead, so the install still finishes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $problem = Get-EarlierCopyProblem -Path $Path
        if (-not $problem -and (Test-Path -LiteralPath $Destination)) { $problem = "$Destination is there already" }
        if ($problem) {
            Write-Warning "Kept the earlier copy in ${Path}: $problem. Look at it and delete it yourself, as administrator."
            return
        }
        $parent = Split-Path -Path $Destination -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        if (Test-ContainsReparsePoint -Path $parent) { throw "$parent, or a folder above it, is a junction, link or cloud placeholder." }
        Move-Item -LiteralPath $Path -Destination $Destination
        Write-Information "Moved the earlier copy in $Path to $Destination, where PowerShell does not load it" -InformationAction Continue
    }
    catch {
        Write-Warning "Could not move the earlier copy in ${Path}: $($_.Exception.Message) It may still load instead of the version installed."
    }
}

function Get-FirstModuleCopy {
    <#
      The LazyVM copy Import-Module LazyVM loads: the highest version in the
      first folder on PSModulePath that has LazyVM.
    #>
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param()

    $copies = @(Get-Module -Name LazyVM -ListAvailable)
    if ($copies.Count -eq 0) { return }
    $folder = Split-Path -Path $copies[0].ModuleBase -Parent
    $copies | Where-Object { Test-SameFolder -Path (Split-Path -Path $_.ModuleBase -Parent) -Other $folder } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
}

function Write-ShadowingCopyWarning {
    <#
      Warns, with its path, when the LazyVM copy Import-Module LazyVM loads
      is not the version installed in $Path.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $first = Get-FirstModuleCopy
    if ($first -and -not (Test-SameFolder -Path $first.ModuleBase -Other $Path)) {
        Write-Warning "PowerShell loads LazyVM from $($first.ModuleBase), not from $Path, which Install.ps1 installed: it comes first on PSModulePath. Delete it as administrator, or take its folder off PSModulePath."
    }
}

function Set-InstallFolderAccess {
    <#
      Locks $Path: full control for Administrators and SYSTEM, read and run
      for the user $User, inherited by everything in it, nothing inherited
      from above, and owned by Administrators. Nobody but an administrator
      can change what is in it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$User
    )

    $administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $access = [ordered]@{
        'S-1-5-32-544' = [System.Security.AccessControl.FileSystemRights]::FullControl
        'S-1-5-18'     = [System.Security.AccessControl.FileSystemRights]::FullControl
        $User.Value    = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    }
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    foreach ($sid in $access.Keys) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new($sid), $access[$sid],
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

# Only version folders, as a release download and the assembled module have
# them: in the repository, src\LazyVM holds the module's source instead (#90).
$versionDir = Get-ChildItem -LiteralPath (Join-Path -Path $Path -ChildPath $moduleName) -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -as [version] } |
    Sort-Object -Property { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $versionDir) {
    throw "There is no $moduleName module folder in $Path. Extract the whole download and run Install.ps1 from it, or, from the repository's root folder, run: ./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out"
}

# In Program Files, locked so only administrators can change it: the
# scheduled tasks run it as SYSTEM (#284). The module names the same folder
# (Get-InstalledModuleFolder). Asked of Windows, not read from
# $env:ProgramFiles, which the user's own environment can change.
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$installDir = Join-Path -Path $programFiles -ChildPath $moduleName
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Set-InstallFolderAccess -Path $installDir -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
$modulesDir = Join-Path -Path $installDir -ChildPath 'Modules'
$target = Join-Path -Path $modulesDir -ChildPath "$moduleName\$($versionDir.Name)"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File
Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue

# Earlier LazyVM 6 builds installed into the user's own folders, which the
# user, or OneDrive, can change.
$userCopy = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath "$moduleName\Modules"
Update-UserModulePath -Change { param($List) Add-PathListEntry -List (Remove-PathListEntry -List $List -Entry $userCopy) -Entry $modulesDir }
$env:PSModulePath = Add-PathListEntry -List (Remove-PathListEntry -List $env:PSModulePath -Entry $userCopy) -Entry $modulesDir
$documentsCopy = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath "PowerShell\Modules\$moduleName"

# Earlier copies PowerShell would load instead (#311), once PSModulePath is
# updated, so a copy that cannot go leaves the install no less complete.
# Each is checked first, links in the folders above it included. The user
# can still change their own folders between that check and the delete:
# then only a folder that looks like a LazyVM copy is deleted.
Remove-EarlierCopy -Path (Join-Path -Path $modulesDir -ChildPath $moduleName) -Except $versionDir.Name
Remove-EarlierCopy -Path (Join-Path -Path $userCopy -ChildPath $moduleName)
Remove-EarlierCopy -Path $documentsCopy
# LazyVM 5 was installed for every user, in PowerShell's own module folder,
# which comes before this one on PSModulePath. While its install is not
# moved to the user yet (its Root value is still in HKLM), its copy is moved
# aside, where Convert-LazyVMInstallation deletes it once it has moved the
# install (Remove-LegacyInstallation); otherwise it is deleted.
$machineWide = Join-Path -Path $programFiles -ChildPath "PowerShell\Modules\$moduleName"
$legacyKey = "HKLM:\SOFTWARE\$moduleName"
if ((Test-Path -LiteralPath $legacyKey) -and $null -ne (Get-Item -LiteralPath $legacyKey).GetValue('Root')) {
    Move-EarlierCopy -Path $machineWide -Destination (Join-Path -Path $installDir -ChildPath "Legacy\$moduleName")
    Write-Warning "LazyVM 5's VMs are not moved to you yet, and its scheduled tasks fail until they are. Open a new PowerShell 7 window as administrator and run Convert-LazyVMInstallation: it moves your VMs, passwords and tasks to your account."
}
else {
    Remove-EarlierCopy -Path $machineWide
}
Write-ShadowingCopyWarning -Path $target
Write-Information 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox' -InformationAction Continue
