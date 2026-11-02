#Requires -Version 7.6
<#
.SYNOPSIS
Installs LazyVM from a release download.

.DESCRIPTION
Copies the LazyVM module beside this script to your own module folder,
%LOCALAPPDATA%\LazyVM\Modules, and adds that folder to your PSModulePath
(once), so PowerShell 7 finds LazyVM. The folder is on this computer only:
not Documents, which OneDrive can sync and make online-only. LazyVM's
scheduled tasks, which run as SYSTEM, load the module from that folder by
its path. Only you can use LazyVM: it is installed per user. An earlier
copy of the same version is replaced; other versions are left alone.

A copy an earlier LazyVM 6 put in Documents\PowerShell\Modules is
removed. A copy installed for every user, in Program Files, is reported:
Convert-LazyVMInstallation moves that install to you and removes it.

Files downloaded from the internet are marked as such, and PowerShell will
not load a marked module, so the copies are unblocked as they are installed.

Run it in PowerShell 7 (pwsh), signed in as the Windows user who will use
LazyVM. It does not need to run as administrator; LazyVM itself does.

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
    $wanted = $Entry.TrimEnd('\')
    foreach ($existing in $entries) {
        if ([Environment]::ExpandEnvironmentVariables($existing).TrimEnd('\') -ieq $wanted) { return $List }
    }
    return (@($entries) + $Entry) -join ';'
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

# Only version folders, as a release download and the assembled module have
# them: in the repository, src\LazyVM holds the module's source instead (#90).
$versionDir = Get-ChildItem -LiteralPath (Join-Path -Path $Path -ChildPath $moduleName) -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -as [version] } |
    Sort-Object -Property { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $versionDir) {
    throw "There is no $moduleName module folder in $Path. Extract the whole download and run Install.ps1 from it, or, from the repository's root folder, run: ./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out"
}

# On this computer only, never synced by OneDrive (#284). The module names
# the same folder (Get-UserModuleFolder).
$modulesDir = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'LazyVM\Modules'
$target = Join-Path -Path $modulesDir -ChildPath "$moduleName\$($versionDir.Name)"
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path -Path $versionDir.FullName -ChildPath '*') -Destination $target -Recurse -Force
Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File
Write-Information "Installed $moduleName $($versionDir.Name) in $target" -InformationAction Continue

# The folder on the user's PSModulePath, kept in HKCU\Environment as it is,
# unexpanded entries included. PowerShell 7 adds the user's entries to the
# machine's when it starts.
$environment = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
try {
    $current = [string]$environment.GetValue('PSModulePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $updated = Add-PathListEntry -List $current -Entry $modulesDir
    if ($updated -ne $current) {
        $kind = if ($current) { $environment.GetValueKind('PSModulePath') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $environment.SetValue('PSModulePath', $updated, $kind)
        Send-EnvironmentChange
        Write-Information "Added $modulesDir to your PSModulePath" -InformationAction Continue
    }
}
finally { $environment.Dispose() }
$env:PSModulePath = Add-PathListEntry -List $env:PSModulePath -Entry $modulesDir

# LazyVM 6 builds before this one installed into Documents, which OneDrive can sync.
$documentsCopy = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath "PowerShell\Modules\$moduleName"
if (Test-Path -LiteralPath $documentsCopy) {
    Remove-Item -LiteralPath $documentsCopy -Recurse -Force
    Write-Information "Removed the earlier copy in $documentsCopy" -InformationAction Continue
}
# Before #284, LazyVM was installed for every user, in Program Files.
$machineWide = Join-Path -Path $env:ProgramFiles -ChildPath "PowerShell\Modules\$moduleName"
if (Test-Path -LiteralPath $machineWide) {
    Write-Warning "An earlier LazyVM is installed for every user in $machineWide. Open a new PowerShell 7 window as administrator and run Convert-LazyVMInstallation: it moves your VMs, passwords and tasks to your account and then removes that copy."
}
Write-Information 'Open a new PowerShell 7 window as administrator, then run: Build-LazyVM -Name DevBox' -InformationAction Continue
