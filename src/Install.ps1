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
removal is listed: LazyVM 5's, in %ProgramFiles%\PowerShell\Modules, and the
ones an earlier LazyVM 6 put in %LOCALAPPDATA%\LazyVM\Modules or
Documents\PowerShell\Modules. A copy that is, or holds, a junction or link is
kept, with a warning: links are never followed. Then Install.ps1 checks that
PowerShell loads the version it installed, and warns with the path of any
copy that still comes first. If LazyVM 5's VMs have not been moved to you
yet, it says to run Convert-LazyVMInstallation.

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

function Test-LinkInFolder {
    <#
      Whether $Path, or anything in it, is a reparse point: a junction or a
      symbolic link. Links found inside are not followed.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $reparsePoint = [IO.FileAttributes]::ReparsePoint
    if ((Get-Item -LiteralPath $Path -Force).Attributes.HasFlag($reparsePoint)) { return $true }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.Attributes.HasFlag($reparsePoint) }).Count -gt 0
}

function Remove-EarlierCopy {
    <#
      Deletes the earlier LazyVM copy $Path, if there is one, and says so.
      A copy that is, or holds, a junction or link is kept, with a warning,
      so nothing is deleted through a link.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-LinkInFolder -Path $Path) {
        Write-Warning "Kept the earlier copy in ${Path}: it is, or holds, a junction or link, which Install.ps1 does not follow. Look at it and delete it yourself, as administrator."
        return
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
    Write-Information "Removed the earlier copy in $Path" -InformationAction Continue
}

function Get-OtherModuleVersion {
    <# The version folders in the module folder $Path other than $Keep, the version being installed. #>
    [OutputType([IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Keep
    )

    Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -as [version] -and $_.Name -ne $Keep }
}

function Write-ShadowingCopyWarning {
    <#
      Warns, with its path, when the first LazyVM on PSModulePath, the one
      Import-Module LazyVM loads, is not the version installed in $Path.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $first = Get-Module -Name LazyVM -ListAvailable | Select-Object -First 1
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
# (Get-InstalledModuleFolder).
$installDir = Join-Path -Path $env:ProgramFiles -ChildPath $moduleName
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Set-InstallFolderAccess -Path $installDir -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
$modulesDir = Join-Path -Path $installDir -ChildPath 'Modules'
$target = Join-Path -Path $modulesDir -ChildPath "$moduleName\$($versionDir.Name)"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File
Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue
foreach ($other in Get-OtherModuleVersion -Path (Join-Path -Path $modulesDir -ChildPath $moduleName) -Keep $versionDir.Name) {
    Remove-EarlierCopy -Path $other.FullName
}

# Earlier LazyVM 6 builds installed into the user's own folders, which the
# user, or OneDrive, can change.
$userCopy = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath "$moduleName\Modules"
Update-UserModulePath -Change { param($List) Add-PathListEntry -List (Remove-PathListEntry -List $List -Entry $userCopy) -Entry $modulesDir }
$env:PSModulePath = Add-PathListEntry -List (Remove-PathListEntry -List $env:PSModulePath -Entry $userCopy) -Entry $modulesDir
$documentsCopy = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath "PowerShell\Modules\$moduleName"
# LazyVM 5 was installed for every user, in PowerShell's own module folder,
# which comes before this one on PSModulePath (#311).
$machineWide = Join-Path -Path $env:ProgramFiles -ChildPath "PowerShell\Modules\$moduleName"
foreach ($earlier in $userCopy, $documentsCopy, $machineWide) {
    Remove-EarlierCopy -Path $earlier
}
# LazyVM 5 recorded its folder here; Convert-LazyVMInstallation removes it once the install is moved.
if (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\$moduleName" -Name 'Root' -ErrorAction SilentlyContinue) {
    Write-Warning "LazyVM 5's VMs are not moved to you yet. Open a new PowerShell 7 window as administrator and run Convert-LazyVMInstallation: it moves your VMs, passwords and tasks to your account."
}
Write-ShadowingCopyWarning -Path $target
Write-Information 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox' -InformationAction Continue
