# CommandRun.ps1 - What every public command does first and last.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

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
      starts its log, writes the run's header and any settings warnings, and
      adopts the guest account name from the credential store. With
      -RecordHardware, first records in VM.json any hardware change made in
      Hyper-V. Returns the VM's context.
    #>
    [OutputType([VMContext])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Name,
        [switch]$RecordHardware
    )

    $root = Resolve-LazyVMRoot
    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $root.Path)
    $configuration = Read-VMSetting -Root $root.Path -VMName $Name -Unattended:(Test-Unattended)
    $vm = [VMContext]::new($configuration.Settings)

    Start-Log -Path $vm.Settings.LogFile -MaxSizeMB $vm.Settings.LogMaxSizeMB
    $rule = '========================================================'
    Write-LogEntry $rule 'INFO'
    Write-LogEntry "  LazyVM - $Title" 'INFO'
    Write-LogEntry "  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" 'INFO'
    Write-LogEntry "  Host    : $env:COMPUTERNAME" 'INFO'
    Write-LogEntry "  User    : $env:USERDOMAIN\$env:USERNAME" 'INFO'
    Write-LogEntry "  Module  : $($MyInvocation.MyCommand.Module.Version) on PowerShell $($PSVersionTable.PSVersion)" 'INFO'
    Write-LogEntry "  VM      : $($vm.Name) ($($configuration.ProfilePath))" 'INFO'
    Write-LogEntry "  Root    : $($root.Path) (from $($root.Source))" 'INFO'
    $missing = @($configuration.MissingKeys)
    Write-LogEntry "  Profile : $(if ($missing.Count -gt 0) { "$($missing.Count) setting(s) not yet in VM.json, taken from the shared template" } else { 'complete' })" 'INFO'
    Write-LogEntry $rule 'INFO'
    foreach ($warning in $configuration.Warnings) { Write-LogEntry $warning 'WARN' }

    # A VM from before #130 has its tooling list in files of its own: they
    # go into VM.json before anything reads it.
    $changed = Move-ToolingIntoProfile -Root $root.Path -Name $vm.Name
    # A rebuild must make the VM as it is now, not as it was first set up.
    if ($RecordHardware -and (Save-VMHardware -VM $vm)) { $changed = $true }
    if ($changed) {
        $configuration = Read-VMSetting -Root $root.Path -VMName $vm.Name -Unattended:(Test-Unattended)
        $vm = [VMContext]::new($configuration.Settings)
    }

    Sync-GuestUserFromStore -VM $vm
    return $vm
}

function Complete-CommandRun {
    <# The end of every command that works on a VM, however it ended: closes the guest session and the log. #>
    param([AllowNull()][VMContext]$VM)

    if ($VM) { Remove-GuestSession -VM $VM }
    Stop-Log
}

function Invoke-CommandRun {
    <#
      Runs a public command's work: checks for an elevated session, starts
      the run for the VM and passes its context to $ScriptBlock, logs a
      failure before reporting it as the command's error, and always cleans
      up. The script block's output is the command's output.

      Deliberately a simple function: an advanced one would have its own
      $PSCmdlet, hiding the command's from the script block, which needs it
      for ShouldProcess.
    #>
    param(
        [string]$Title,
        [string]$Name,
        [string]$FailureMessage,
        [System.Management.Automation.PSCmdlet]$Cmdlet,
        [scriptblock]$ScriptBlock,
        [switch]$RecordHardware
    )

    Assert-Administrator
    $context = $null
    try {
        $context = Initialize-CommandRun -Title $Title -Name $Name -RecordHardware:$RecordHardware
        & $ScriptBlock $context
    }
    catch {
        if (Test-LogStarted) { Write-LogError $FailureMessage $_ }
        $Cmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun -VM $context
    }
}

function Set-ForceConfirmation {
    <#
      Makes -Force skip the confirmation in the calling command, unless
      -Confirm was given as well. Sets the caller's own $ConfirmPreference.
    #>
    param(
        [switch]$Force,
        [Parameter(Mandatory)][hashtable]$BoundParameters
    )

    if ($Force -and -not $BoundParameters.ContainsKey('Confirm')) {
        Set-Variable -Name ConfirmPreference -Value 'None' -Scope 1
    }
}

function Get-ModuleImportCommand {
    <#
      How a scheduled task loads this module. By name when it is installed
      where PowerShell looks for modules, so an updated version is picked up
      automatically; otherwise by the path it was loaded from.
    #>
    $moduleBase = $MyInvocation.MyCommand.Module.ModuleBase
    foreach ($searchPath in @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })) {
        $folder = $searchPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($moduleBase.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase)) {
            return "Import-Module -Name 'LazyVM'"
        }
    }
    $manifest = Join-Path -Path $moduleBase -ChildPath 'LazyVM.psd1'
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
