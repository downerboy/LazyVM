#Requires -Version 7.6
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs LazyVM and its app from a release download.

.DESCRIPTION
Copies the LazyVM module beside this script to %ProgramFiles%\LazyVM\Modules
and adds that folder to your PSModulePath (once), so PowerShell 7 finds
LazyVM. The LazyVM app, in App beside it, goes in %ProgramFiles%\LazyVM\App:
start it with %ProgramFiles%\LazyVM\App\LazyVM.UI.Wpf.exe. The new app is
copied in beside the old one, then swapped in, so an app that is running is
kept whole: close it, and run Install.ps1 again. Without App, as in out
from Invoke-AnalyzerAndTest.ps1 before Publish-App.ps1, only the module is
installed. The folder %ProgramFiles%\LazyVM is locked: administrators and
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

With the app installed, a LazyVM shortcut to it goes in the Start menu of
every user, %ProgramData%\Microsoft\Windows\Start Menu\Programs, which only
administrators can add to or change, so no other program can repoint a
shortcut that asks for elevation. The shortcut itself is locked as the
install folder is. Installing again replaces it.

-Uninstall removes LazyVM from this computer, after listing what goes and
what stays and asking: the Start menu shortcut, the app, the module and its
folder on your PSModulePath, and LazyVM's scheduled tasks on the host, so
nothing runs the VMs' nightly maintenance or security scan any more. The
Hyper-V VMs and their disks, your LazyVM folder (settings, logs, templates,
backups) and the stored passwords and recovery keys are kept: to remove a
VM fully, run Remove-LazyVM first. Nothing that is, holds, or is reached
through a junction, link or cloud placeholder is removed, and what cannot
be removed is named, without stopping the rest.

Run it in PowerShell 7 (pwsh) as administrator, signed in as the Windows
user who will use LazyVM (approve the UAC prompt with your own account), or
double-click Install LazyVM.cmd or Uninstall LazyVM.cmd beside it.

.PARAMETER Path
The folder that holds the LazyVM module folder, and the app's App folder.
By default, this script's own folder, as in a release download.

.PARAMETER Uninstall
Removes LazyVM from this computer, keeping the VMs and their data. It asks
first; -Confirm:$false does not, and -WhatIf only lists what would go.

.EXAMPLE
.\Install.ps1

Installs from a release download.

.EXAMPLE
./src/Install.ps1 -Path out

Installs the module Invoke-AnalyzerAndTest.ps1 assembled from the repository,
and the app Publish-App.ps1 published there, if it did.

.EXAMPLE
.\Install.ps1 -Uninstall

Lists what goes and what stays, asks, then removes LazyVM, keeping the VMs.
#>
[CmdletBinding(DefaultParameterSetName = 'Install', SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [string]$Path = $PSScriptRoot,

    [Parameter(Mandatory, ParameterSetName = 'Uninstall')]
    [switch]$Uninstall
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

function Test-ReparsePointOnPath {
    <#
      Whether a folder from the drive's root down to $Path, or $Path itself,
      is a reparse point; what is inside $Path is not looked at. A part of
      the path that does not exist yet is not one.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $current = [IO.Path]::GetPathRoot($full)
    foreach ($name in @($full.Substring($current.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path -Path $current -ChildPath $name
        if (-not (Test-Path -LiteralPath $current)) { return $false }
        if (Test-ReparsePoint -Path $current) { return $true }
    }
    return $false
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

    if (Test-ReparsePointOnPath -Path $Path) { return $true }
    return @(Get-ChildItem -LiteralPath ([IO.Path]::GetFullPath($Path)) -Recurse -Force | Where-Object { Test-ReparsePoint -Path $_.FullName }).Count -gt 0
}

function Test-ModuleCopy {
    <#
      Whether $Path looks like a LazyVM module folder: named LazyVM, and
      holding only version folders, each with LazyVM.psd1. Nothing else is
      deleted or moved as an earlier copy. Kept in step with Test-ModuleCopy
      in src\LazyVM\Private\Common\PathSafety.ps1.
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

function Reset-InheritedAccess {
    <#
      Gives $Path, and everything in it, only the access inherited from the
      folder above. A moved folder keeps the access it had where it was:
      LazyVM 5's copy, moved out of Program Files, would still let every
      user read it (#311).
    #>
    param([Parameter(Mandatory)][string]$Path)

    foreach ($item in @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        $acl = Get-Acl -LiteralPath $item.FullName
        $acl.SetAccessRuleProtection($false, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            $null = $acl.RemoveAccessRuleSpecific($rule)
        }
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
}

function Move-EarlierCopy {
    <#
      Moves LazyVM 5's module folder $Path to $Destination, which is not on
      PSModulePath, so it no longer loads instead and Convert-LazyVMInstallation
      still has it, open only as the folder it is moved to allows. When it
      must not, or the move fails, warns with the path instead, so the
      install still finishes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        if (Test-Path -LiteralPath $Destination) {
            Write-Warning "Kept LazyVM 5's copy in $Path, which still loads instead of the version installed: an earlier one is in $Destination already. Open a new PowerShell 7 window as administrator and run Convert-LazyVMInstallation: it removes both."
            return
        }
        $problem = Get-EarlierCopyProblem -Path $Path
        if ($problem) {
            Write-Warning "Kept the earlier copy in ${Path}: $problem. Look at it and delete it yourself, as administrator."
            return
        }
        $parent = Split-Path -Path $Destination -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        if (Test-ContainsReparsePoint -Path $parent) { throw "$parent, or a folder above it, is a junction, link or cloud placeholder." }
        Move-Item -LiteralPath $Path -Destination $Destination
        Reset-InheritedAccess -Path $Destination
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

function Set-LockedAccess {
    <#
      Locks the folder or file $Path: full control for Administrators and
      SYSTEM, read and run for the user $User, inherited by everything in a
      folder, nothing inherited from above, and owned by Administrators.
      Nobody but an administrator can change it, or what is in it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$User
    )

    $folder = Test-Path -LiteralPath $Path -PathType Container
    $administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $access = [ordered]@{
        'S-1-5-32-544' = [System.Security.AccessControl.FileSystemRights]::FullControl
        'S-1-5-18'     = [System.Security.AccessControl.FileSystemRights]::FullControl
        $User.Value    = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    }
    $security = if ($folder) { [System.Security.AccessControl.DirectorySecurity]::new() } else { [System.Security.AccessControl.FileSecurity]::new() }
    $inheritance = if ($folder) { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [System.Security.AccessControl.InheritanceFlags]::None }
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    foreach ($sid in $access.Keys) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new($sid), $access[$sid], $inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-FolderAllowRule {
    <# The allow rules on the folder $Path, as security identifier, rights and whether each applies to what is inside only. #>
    param([Parameter(Mandatory)][string]$Path)

    foreach ($rule in (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ("$($rule.AccessControlType)" -ne 'Allow') { continue }
        [pscustomobject]@{
            Sid         = $rule.IdentityReference.Value
            Rights      = [long]$rule.FileSystemRights
            InheritOnly = [bool]($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
        }
    }
}

function Get-ShortcutFolderProblem {
    <#
      Why the Start menu folder $Path, owned by $Owner, is not one only
      administrators can change (security rule 6 in docs\Dashboard.md), or
      nothing when it is.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner
    )

    # Administrators, SYSTEM and TrustedInstaller, as in TrustedCode.ps1.
    $trusted = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    # Rights that add to the folder or change it, short of delete: create
    # files and folders (write and append data), change permissions, take
    # ownership, and generic write or all. Windows lets the signed-in user
    # delete from it, which removes a shortcut but puts none in its place.
    $changeRights = [long]0x500C0006

    if ($trusted -notcontains $Owner) {
        return "it is owned by $Owner, who can change its permissions"
    }
    $writers = @(Get-FolderAllowRule -Path $Path | Where-Object {
            -not $_.InheritOnly -and ($_.Rights -band $changeRights) -and $trusted -notcontains $_.Sid
        } | ForEach-Object { $_.Sid } | Select-Object -Unique)
    if ($writers.Count -gt 0) {
        return "it can be changed by $($writers -join ', ')"
    }
}

function Install-StartMenuShortcut {
    <#
      Adds the LazyVM shortcut $Path, to the app $Target, replacing one
      that is there, and locks it to administrators, readable by $User.
      Only in a folder administrators alone can change, reached through no
      junction, link or cloud placeholder; otherwise, or when it fails,
      warns, so the install still finishes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$User
    )

    $folder = Split-Path -Path $Path -Parent
    $without = "Start the app with $Target."
    try {
        if (Test-ReparsePointOnPath -Path $Path) {
            Write-Warning "No Start menu shortcut was added: $Path, or a folder above it, is a junction, link or cloud placeholder, which Install.ps1 does not follow. $without"
            return
        }
        $problem = Get-ShortcutFolderProblem -Path $folder -Owner (Get-Acl -LiteralPath $folder).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($problem) {
            Write-Warning "No Start menu shortcut was added to ${folder}: $problem, so another program could repoint a shortcut that asks for elevation. $without"
            return
        }
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        $shortcut.WorkingDirectory = Split-Path -Path $Target -Parent
        $shortcut.Description = 'Build and look after your LazyVM development VMs'
        $shortcut.Save()
        Set-LockedAccess -Path $Path -User $User
        Write-Information "Added the LazyVM shortcut to the Start menu: $Path" -InformationAction Continue
    }
    catch {
        Write-Warning "Could not add the Start menu shortcut ${Path}: $($_.Exception.Message) $without"
    }
}

function Get-LazyVMHostTask {
    <# LazyVM's scheduled tasks on the host: in the root folder, named as LazyVM names them. #>
    # As the module names them (Constants.ps1): each VM's daily maintenance,
    # and the build that carries on after a host restart. Install.ps1 runs
    # without the module.
    $hostTaskPrefixes = @('LazyVM-Maintain-', 'LazyVM-ResumeAfterReboot-')
    @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue) | Where-Object {
        $task = $_
        $task.TaskPath -eq '\' -and @($hostTaskPrefixes | Where-Object { $task.TaskName.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    }
}

function Get-UninstallPlan {
    <#
      What -Uninstall removes and what it keeps: Remove, the paths that are
      there to remove, and Text, the list to show before anything goes.
      $DataFolder is the LazyVM folder, named only.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Task,
        [Parameter(Mandatory)][string]$DataFolder
    )

    $app = Join-Path -Path $InstallDir -ChildPath 'App'
    $modules = Join-Path -Path $InstallDir -ChildPath 'Modules'
    $legacy = Join-Path -Path $InstallDir -ChildPath 'Legacy'
    $labels = [ordered]@{
        $ShortcutPath = 'the Start menu shortcut'
        $app          = 'the LazyVM app'
        $modules      = 'the LazyVM module'
    }
    $remove = @($labels.Keys | Where-Object { Test-Path -LiteralPath $_ })
    $removes = @($remove | ForEach-Object { "  - $($labels[$_]), $_" }) +
    "  - $modules, from your PSModulePath" +
    @($Task | ForEach-Object { "  - the scheduled task $($_.TaskName)" })
    if (@($Task).Count -gt 0) {
        $removes += '    With the tasks gone, nothing runs the VMs'' nightly maintenance or security scan.'
    }
    $keeps = @(
        '  - the Hyper-V VMs and their disks'
        "  - your LazyVM folder, $DataFolder`: settings, logs, templates and backups"
        '  - the stored passwords and the disks'' recovery keys'
    ) + @(if (Test-Path -LiteralPath $legacy) { "  - LazyVM 5's copy, in $legacy" })
    $text = @('Removes:') + $removes + '' + 'Keeps:' + $keeps + '' +
    'To remove a VM fully, with its disks and data, run Remove-LazyVM -Name <VM> first: once LazyVM is uninstalled, it is not there to run.'
    return [pscustomobject]@{ Remove = $remove; Task = @($Task); Text = $text -join [Environment]::NewLine }
}

function Remove-InstalledItem {
    <#
      Removes the installed file or folder $Path, and says so. A folder is
      renamed first, so one in use, as by the app running, is kept whole,
      not half removed. Nothing that is, holds, or is reached through a
      junction, link or cloud placeholder is removed; that, and a failure,
      are warnings naming the path, so the rest is still removed.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $aside = "$Path.old"
    try {
        foreach ($item in @($Path, $aside) | Where-Object { Test-Path -LiteralPath $_ }) {
            if (Test-ContainsReparsePoint -Path $item) {
                Write-Warning "Kept ${item}: it, a folder above it, or something in it is a junction, link or cloud placeholder, which Install.ps1 does not follow. Look at it, and delete it yourself, as administrator."
                return
            }
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Remove-Item -LiteralPath $Path -Force
        }
        else {
            # Left over from an uninstall that stopped part way.
            if (Test-Path -LiteralPath $aside) { Remove-Item -LiteralPath $aside -Recurse -Force }
            try {
                Rename-Item -LiteralPath $Path -NewName (Split-Path -Path $aside -Leaf) -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not remove ${Path}: it is in use ($($_.Exception.Message)). Close LazyVM, then run Install.ps1 -Uninstall again."
                return
            }
            Remove-Item -LiteralPath $aside -Recurse -Force
        }
        Write-Information "Removed $Path" -InformationAction Continue
    }
    catch {
        Write-Warning "Could not remove ${Path}: $($_.Exception.Message) Delete it yourself, as administrator."
    }
}

function Unregister-LazyVMHostTask {
    <# Unregisters each of the scheduled tasks $Task, listing each, and naming any it could not, then says what no longer runs. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Task)

    if (@($Task).Count -eq 0) { return }
    foreach ($item in $Task) {
        try {
            Unregister-ScheduledTask -TaskName $item.TaskName -TaskPath $item.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Information "Unregistered the scheduled task $($item.TaskName)" -InformationAction Continue
        }
        catch {
            Write-Warning "Could not unregister the scheduled task $($item.TaskName): $($_.Exception.Message) Delete it yourself in Task Scheduler, as administrator."
        }
    }
    Write-Information 'Nothing runs the VMs'' nightly maintenance or security scan now.' -InformationAction Continue
}

function Remove-EmptyInstallFolder {
    <# Removes the install folder $Path once nothing is left in it, and says so; a folder that holds anything, such as LazyVM 5's copy in Legacy, is kept. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path) -or (Test-ReparsePoint -Path $Path)) { return }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) { return }
    try {
        Remove-Item -LiteralPath $Path -Force
        Write-Information "Removed $Path" -InformationAction Continue
    }
    catch {
        Write-Warning "Could not remove ${Path}: $($_.Exception.Message) Delete it yourself, as administrator."
    }
}

function Install-App {
    <#
      Installs the LazyVM app from $Source, the download's App folder, in
      App in the locked install folder $InstallDir (#489). The new app is
      copied beside it first, then swapped in, so an app that is running,
      which Windows will not let go, is kept whole and not half replaced.
      Without $Source, as in out from Invoke-AnalyzerAndTest.ps1, only the
      module is installed. Nothing that is, holds, or is reached through a
      junction, link or cloud placeholder is copied from or replaced.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$InstallDir
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Information "There is no App folder in $(Split-Path -Path $Source -Parent), so only the module was installed, not the LazyVM app." -InformationAction Continue
        return
    }
    $target = Join-Path -Path $InstallDir -ChildPath 'App'
    $staging = Join-Path -Path $InstallDir -ChildPath 'App.new'
    $old = Join-Path -Path $InstallDir -ChildPath 'App.old'
    foreach ($path in @($Source, $target, $staging, $old) | Where-Object { Test-Path -LiteralPath $_ }) {
        if (Test-ContainsReparsePoint -Path $path) {
            Write-Warning "The LazyVM app was not installed: $path, a folder above it, or something in it is a junction, link or cloud placeholder, which Install.ps1 does not follow. Look at it, and delete it yourself, as administrator."
            return
        }
    }
    # Left over from an install that stopped part way.
    foreach ($leftover in @($staging, $old) | Where-Object { Test-Path -LiteralPath $_ }) {
        Remove-Item -LiteralPath $leftover -Recurse -Force
    }

    # Made inside the locked folder, so it takes that folder's access.
    Copy-Item -LiteralPath $Source -Destination $staging -Recurse
    Get-ChildItem -LiteralPath $staging -Recurse -File | Unblock-File
    if (Test-Path -LiteralPath $target) {
        try {
            Rename-Item -LiteralPath $target -NewName (Split-Path -Path $old -Leaf) -ErrorAction Stop
        }
        catch {
            Remove-Item -LiteralPath $staging -Recurse -Force
            Write-Warning "The LazyVM app was not updated: $target is in use ($($_.Exception.Message)). Close LazyVM, then run Install.ps1 again."
            return
        }
    }
    Move-Item -LiteralPath $staging -Destination $target
    if (Test-Path -LiteralPath $old) {
        try {
            Remove-Item -LiteralPath $old -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove the earlier app in ${old}: $($_.Exception.Message) Delete it yourself, as administrator."
        }
    }
    Write-Information "Installed the LazyVM app in $target" -InformationAction Continue
}

# In Program Files, locked so only administrators can change it: the
# scheduled tasks run it as SYSTEM (#284). The module names the same folder
# (Get-InstalledModuleFolder). Asked of Windows, not read from
# $env:ProgramFiles, which the user's own environment can change.
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$installDir = Join-Path -Path $programFiles -ChildPath $moduleName
$modulesDir = Join-Path -Path $installDir -ChildPath 'Modules'
$appExe = Join-Path -Path $installDir -ChildPath 'App\LazyVM.UI.Wpf.exe'
# The Start menu of every user, which only administrators can add to or
# change (security rule 6, #490), asked of Windows too.
$shortcutPath = Join-Path -Path ([Environment]::GetFolderPath('CommonPrograms')) -ChildPath "$moduleName.lnk"
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User

if ($Uninstall) {
    # The LazyVM folder, named in the list only: it is kept.
    $settingsKey = "HKCU:\SOFTWARE\$moduleName"
    $dataFolder = if (Test-Path -LiteralPath $settingsKey) { (Get-Item -LiteralPath $settingsKey).GetValue('Root') }
    if (-not $dataFolder) { $dataFolder = Join-Path -Path ([Environment]::GetFolderPath('UserProfile')) -ChildPath $moduleName }
    $plan = Get-UninstallPlan -InstallDir $installDir -ShortcutPath $shortcutPath -Task @(Get-LazyVMHostTask) -DataFolder $dataFolder
    if (-not $PSCmdlet.ShouldProcess($plan.Text, "$($plan.Text)$([Environment]::NewLine)$([Environment]::NewLine)Uninstall LazyVM from this computer?", 'Uninstall LazyVM')) {
        Write-Information 'Nothing was removed.' -InformationAction Continue
        return
    }
    Unregister-LazyVMHostTask -Task $plan.Task
    foreach ($item in $plan.Remove) {
        Remove-InstalledItem -Path $item
    }
    Update-UserModulePath -Change { param($List) Remove-PathListEntry -List $List -Entry $modulesDir }
    $env:PSModulePath = Remove-PathListEntry -List $env:PSModulePath -Entry $modulesDir
    Remove-EmptyInstallFolder -Path $installDir
    Write-Information "LazyVM is uninstalled. The Hyper-V VMs, their disks and $dataFolder are kept. To use them again, install LazyVM again." -InformationAction Continue
    return
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

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Set-LockedAccess -Path $installDir -User $user
$target = Join-Path -Path $modulesDir -ChildPath "$moduleName\$($versionDir.Name)"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File
Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue
# The app, beside the module in the same locked folder (#489).
Install-App -Source (Join-Path -Path $Path -ChildPath 'App') -InstallDir $installDir
# Its shortcut, when it is installed: an app in use is kept, so may be the earlier one.
if (Test-Path -LiteralPath $appExe -PathType Leaf) {
    Install-StartMenuShortcut -Path $shortcutPath -Target $appExe -User $user
}

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
