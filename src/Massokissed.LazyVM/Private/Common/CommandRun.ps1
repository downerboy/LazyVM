# CommandRun.ps1 - What every public command does first and last.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

function Assert-Administrator {
    <# Hyper-V, the registry under HKLM and scheduled tasks all need an elevated session. #>
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'LazyVM needs an elevated PowerShell: right-click PowerShell 7 and choose Run as administrator.'
    }
}

function Test-Unattended {
    <#
      True when nobody is there to answer a question or fix a problem: a
      scheduled task, running as SYSTEM. Such a run uses the last good copy
      of a broken settings file rather than stopping.
    #>
    return -not [Environment]::UserInteractive
}

function Initialize-CommandRun {
    <#
      The start of every command that works on a VM: reads its settings,
      opens its log, writes the run's header and any settings warnings, and
      adopts the guest account name from the credential store. Returns the
      configuration (see Read-LazyVMSettings).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Name
    )

    $configuration = Import-LazyVMConfiguration -VMName $Name -Unattended:(Test-Unattended)

    Initialize-Log
    Write-Log '========================================================' 'INFO'
    Write-Log "  LazyVM - $Title"                                        'INFO'
    Write-Log "  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"    'INFO'
    Write-Log "  Host    : $env:COMPUTERNAME"                           'INFO'
    Write-Log "  User    : $env:USERDOMAIN\$env:USERNAME"               'INFO'
    Write-Log "  Module  : $($MyInvocation.MyCommand.Module.Version) on PowerShell $($PSVersionTable.PSVersion)" 'INFO'
    Write-Log "  VM      : $($configuration.VMName) ($($configuration.ProfilePath))" 'INFO'
    Write-Log "  Root    : $($configuration.Root) (from $($configuration.RootSource))" 'INFO'
    $changed = @($configuration.ChangedKeys) + @($configuration.ProfileKeys | ForEach-Object { "$_ (VM)" })
    Write-Log "  Changed : $(if ($changed.Count -gt 0) { $changed -join ', ' } else { 'nothing - all defaults' })" 'INFO'
    Write-Log '========================================================' 'INFO'
    foreach ($warning in $configuration.Warnings) { Write-Log $warning 'WARN' }

    Sync-GuestUserFromStore
    return $configuration
}

function Complete-CommandRun {
    <#
      The end of every command that works on a VM, however it ended. Nothing
      of this VM's run is left behind for the next command in the session,
      which may be for another VM.
    #>
    Disconnect-Guest
    $script:Settings.Clear()
    $script:LogReady = $false
}

function Get-ModuleImportCommand {
    <#
      How a scheduled task loads this module. By name when it is installed
      where PowerShell looks for modules, so an updated version is picked up
      automatically; otherwise by the path it was loaded from.
    #>
    $moduleBase = $MyInvocation.MyCommand.Module.ModuleBase
    $searchPaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })
    foreach ($searchPath in $searchPaths) {
        $folder = $searchPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($moduleBase.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase)) {
            return "Import-Module -Name 'Massokissed.LazyVM'"
        }
    }
    $manifest = Join-Path -Path $moduleBase -ChildPath 'Massokissed.LazyVM.psd1'
    return "Import-Module -Name '$($manifest.Replace("'", "''"))'"
}

function New-LazyVMTaskAction {
    <#
      A scheduled-task action that runs one LazyVM command in PowerShell 7,
      hidden and without a profile. A failure ends the process with exit
      code 1, which Task Scheduler shows as the last run result.
    #>
    param([Parameter(Mandatory)][string]$Command)

    $pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh.exe'
    $script = "$(Get-ModuleImportCommand); $Command"
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command "{0}"' -f $script.Replace('"', '\"')
    return New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
}
