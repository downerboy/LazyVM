# CommandRun.ps1 - What every public command does first and last.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Assert-Administrator {
    <# Hyper-V and scheduled tasks that run elevated both need an elevated session. #>
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

function Read-TrustedVMSetting {
    <#
      Read-VMSetting for a command run: in an unattended run, which acts as
      SYSTEM, also stops when the settings name a place outside the LazyVM
      folder that their owner $OwnerSid has not allowed. Reading and
      checking together, no settings are used unchecked.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$VMName,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    $unattended = Test-Unattended
    $configuration = Read-VMSetting -Root $Root -VMName $VMName -Unattended:$unattended
    if ($unattended) { Assert-HostPathTrusted -Settings $configuration.Settings -OwnerSid $OwnerSid }
    return $configuration
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
        [string]$Root,
        [string]$OwnerSid,
        [switch]$RecordHardware
    )

    $folder = Resolve-LazyVMRoot -Root $Root -OwnerSid $OwnerSid
    $owner = if ($OwnerSid) { $OwnerSid } else { (Get-CurrentUserSid).Value }
    # Every write there, and in the places outside it its owner allowed, is
    # checked for reparse points (PathSafety.ps1).
    $script:RunRoot = $folder.Path
    $script:RunAllowedPaths = @(Get-TrustedHostPath -OwnerSid $owner)
    Initialize-ConfigFolder -ConfigDir (Get-ConfigDir -Root $folder.Path)
    # A scheduled task, as SYSTEM, acts only on paths the owner allowed,
    # the log among them.
    $configuration = Read-TrustedVMSetting -Root $folder.Path -VMName $Name -OwnerSid $owner
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
    Write-LogEntry "  Root    : $($folder.Path) (from $($folder.Source))" 'INFO'
    $missing = @($configuration.MissingKeys)
    Write-LogEntry "  Profile : $(if ($missing.Count -gt 0) { "$($missing.Count) setting(s) not yet in VM.json, taken from the shared template" } else { 'complete' })" 'INFO'
    Write-LogEntry $rule 'INFO'
    foreach ($warning in $configuration.Warnings) { Write-LogEntry $warning 'WARN' }

    # A VM from before #130 has its tooling list in files of its own: they
    # go into VM.json before anything reads it, except with -WhatIf, which
    # changes nothing (#292).
    $changed = (-not $WhatIfPreference) -and (Move-ToolingIntoProfile -Root $folder.Path -Name $vm.Name)
    # A rebuild must make the VM as it is now, not as it was first set up.
    if ($RecordHardware -and (Save-VMHardware -VM $vm)) { $changed = $true }
    if ($changed) {
        $configuration = Read-TrustedVMSetting -Root $folder.Path -VMName $vm.Name -OwnerSid $owner
        $vm = [VMContext]::new($configuration.Settings)
    }

    Sync-GuestUserFromStore -VM $vm
    if (-not (Test-Unattended)) { Write-RunReminder -VM $vm }
    return $vm
}

function Write-RunReminder {
    <#
      What a command run by hand reminds you of first: maintenance that is
      not scheduled, recovery passwords not exported yet, and open High or
      Medium security findings.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    Write-MaintenanceTaskWarning -VM $VM
    Write-RecoveryKeyReminder -VM $VM
    Write-SecurityFindingReminder -VM $VM
}

function Complete-CommandRun {
    <# The end of every command that works on a VM, however it ended: closes the guest session and the log, and forgets the run's reminders. #>
    param([AllowNull()][VMContext]$VM)

    if ($VM) { Remove-GuestSession -VM $VM }
    Stop-Log
    $script:RunRoot = $null
    $script:RunAllowedPaths = @()
    $script:RunRecoveryKeyReminder = @{}
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
        [string]$Root,
        [string]$OwnerSid,
        [switch]$RecordHardware
    )

    Assert-Administrator
    $context = $null
    try {
        $context = Initialize-CommandRun -Title $Title -Name $Name -Root $Root -OwnerSid $OwnerSid -RecordHardware:$RecordHardware
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

function Get-LazyVMModuleBase {
    <# The folder this LazyVM module was loaded from. #>
    [OutputType([string])]
    param()

    return $MyInvocation.MyCommand.Module.ModuleBase
}

function Get-ModuleImportCommand {
    <# How a scheduled task loads this module: by the path Get-ModuleImportPath gives. #>
    [OutputType([string])]
    param()

    return "Import-Module -Name '$((Get-ModuleImportPath).Replace("'", "''"))'"
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
