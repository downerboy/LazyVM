# HostTask.ps1 - LazyVM's scheduled tasks on the host (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The daily maintenance and the build that carries on after a host restart
# run as SYSTEM, elevated, whether or not anyone is signed in: the account
# needs no password, which a Windows Hello account does not have. SYSTEM
# cannot read the user's registry, so each task's command names the LazyVM
# folder (-Root) and its owner (-OwnerSid), and loads the module by its
# folder in Program Files (Get-ModuleImportCommand, TrustedCode.ps1).

function Get-HostTaskCommand {
    <#
      The LazyVM command a host task runs, worked out from its name, for the
      LazyVM folder $Root of the user $OwnerSid; $null for a name LazyVM
      does not give its tasks.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    if ($OwnerSid -notmatch '^S-1-\d+(-\d+)+$') { throw "'$OwnerSid' is not a security identifier." }

    $commands = [ordered]@{
        $script:MaintenanceTaskPrefix = 'Invoke-LazyVMMaintenance'
        $script:ResumeTaskPrefix      = 'Build-LazyVM'
    }
    foreach ($prefix in $commands.Keys) {
        if ($TaskName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return "$($commands[$prefix]) -Name '$($TaskName.Substring($prefix.Length))' -Root '$($Root.Replace("'", "''"))' -OwnerSid '$OwnerSid'"
        }
    }
    return $null
}

function Register-LazyVMHostTask {
    <#
      Registers a LazyVM task on the host to run as SYSTEM, elevated,
      whether or not anyone is signed in, replacing a task of the same name;
      only when the code it runs is administrators' alone to change.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][CimInstance[]]$Action,
        [Parameter(Mandatory)][CimInstance[]]$Trigger,
        [Parameter(Mandatory)][CimInstance]$Settings
    )

    Assert-TrustedCode
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $principal -Force -ErrorAction Stop | Out-Null
}

function Test-MaintenanceTaskMissing {
    <#
      Whether a VM that has been built has no maintenance task, so nothing
      looks after it. False for a VM not built yet, or when it cannot be
      checked: this is only ever a warning.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        if (Get-ScheduledTask -TaskName $VM.Settings.ScheduleTaskName -ErrorAction SilentlyContinue) { return $false }
        return [bool](Get-VM -Name $VM.Name -ErrorAction SilentlyContinue)
    }
    catch {
        return $false
    }
}

function Write-MaintenanceTaskWarning {
    <# Warns, and logs, when a built VM's daily maintenance is not scheduled. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not (Test-MaintenanceTaskMissing -VM $VM)) { return }
    $message = "The daily maintenance of $($VM.Name) is not scheduled, so nothing looks after it. Schedule it with: Register-LazyVMMaintenance -Name $($VM.Name)"
    Write-LogEntry $message 'WARN'
    Write-Warning $message
}
