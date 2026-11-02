# HostTask.ps1 - LazyVM's scheduled tasks on the host, run as the user who installed it (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The daily maintenance and the build that resumes after a restart run as
# the installing user, elevated, whether or not they are signed in. Such a
# task needs the user's Windows password, which Task Scheduler stores: it
# is asked for once per PowerShell session and kept only in memory.
#
# When the password changes, Windows cannot sign the task in any more and
# it does not start; its last result is then a logon failure. Every command
# run by hand warns about it, or about a built VM with no maintenance task,
# and Test-LazyVM reports both.

# The password, once Task Scheduler has accepted it, for the rest of the
# session. Never written anywhere.
$script:TaskCredential = $null

function Get-TaskUserName {
    <# The current Windows account, as DOMAIN\user or COMPUTER\user. #>
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-TaskCredential {
    <# The account and Windows password to register a task with: the accepted one, or asked for. #>
    [OutputType([pscredential])]
    param()

    if ($script:TaskCredential) { return $script:TaskCredential }
    if (Test-Unattended) {
        throw 'Scheduling a LazyVM task needs your Windows password, and nobody is here to type it. Schedule it from PowerShell 7 run as administrator: Register-LazyVMMaintenance'
    }
    $message = 'Your Windows password, so LazyVM''s scheduled tasks can run as you while you are signed out. Task Scheduler keeps it; LazyVM does not. Use your account''s password, not your PIN.'
    $credential = Get-Credential -UserName (Get-TaskUserName) -Message $message
    if (-not $credential) { throw 'No password was entered, so the task was not scheduled.' }
    return $credential
}

function Get-HostTaskCommand {
    <# The LazyVM command a host task runs, worked out from its name; $null for a name LazyVM does not give its tasks. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$TaskName)

    $commands = [ordered]@{
        $script:MaintenanceTaskPrefix = 'Invoke-LazyVMMaintenance'
        $script:ResumeTaskPrefix      = 'Build-LazyVM'
    }
    foreach ($prefix in $commands.Keys) {
        if ($TaskName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return "$($commands[$prefix]) -Name '$($TaskName.Substring($prefix.Length))'"
        }
    }
    return $null
}

function Test-TaskUserName {
    <# Whether a user name typed for the tasks is $Expected (DOMAIN\user), with or without the domain. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Entered,
        [Parameter(Mandatory)][string]$Expected
    )

    $bare = ($Expected -split '\\')[-1]
    return ($Entered -ieq $Expected -or $Entered -ieq $bare)
}

function Test-LogonFailureError {
    <# Whether an error from Task Scheduler means Windows did not accept the account's password. #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    return ("$($ErrorRecord.FullyQualifiedErrorId)" -like "HRESULT 0x$('{0:x}' -f $script:LogonFailureResult)*" -or
        ([long]$ErrorRecord.Exception.HResult -band 0xFFFFFFFFL) -eq $script:LogonFailureResult)
}

function Register-LazyVMHostTask {
    <#
      Registers a LazyVM task on the host to run as the current user,
      elevated, whether or not they are signed in, replacing a task of the
      same name. Asks for the Windows password the first time in a session.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][CimInstance[]]$Action,
        [Parameter(Mandatory)][CimInstance[]]$Trigger,
        [Parameter(Mandatory)][CimInstance]$Settings
    )

    # Always the account running LazyVM: its secrets are encrypted for it.
    $user = Get-TaskUserName
    $credential = Get-TaskCredential
    if (-not (Test-TaskUserName -Entered $credential.UserName -Expected $user)) {
        $script:TaskCredential = $null
        throw "LazyVM's tasks run as $user, the account running LazyVM, so they need its password; one for '$($credential.UserName)' was entered. '$TaskName' was not scheduled."
    }
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings `
            -User $user -Password $credential.GetNetworkCredential().Password -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $script:TaskCredential = $null
        if (Test-LogonFailureError -ErrorRecord $_) {
            throw "Windows did not accept the password for $user, so '$TaskName' was not scheduled. Use your account's password, not your PIN, and try again."
        }
        throw
    }
    $script:TaskCredential = $credential
}

function Test-TaskLogonFailure {
    <#
      Whether a task's last run failed because Windows could not sign it in,
      as after the user changed their password. False when there is no such
      task or it cannot be checked: this is only ever a warning.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$TaskName)

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        return [bool]($info -and [long]$info.LastTaskResult -eq $script:LogonFailureResult)
    }
    catch {
        return $false
    }
}

function Get-TaskLogonFailureMessage {
    <# What to tell the user when the VM's maintenance task could not start because its password is out of date. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)

    return "The daily maintenance of $VMName could not start: Windows did not accept the password Task Scheduler has for you, probably because you changed it. Enter the new one with: Register-LazyVMMaintenance -Name $VMName"
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
    <# Warns, and logs, when the VM's daily maintenance will not run: its password is out of date, or it is not scheduled. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $message = $null
    if (Test-TaskLogonFailure -TaskName $VM.Settings.ScheduleTaskName) {
        $message = Get-TaskLogonFailureMessage -VMName $VM.Name
    }
    elseif (Test-MaintenanceTaskMissing -VM $VM) {
        $message = "The daily maintenance of $($VM.Name) is not scheduled, so nothing looks after it. Schedule it with: Register-LazyVMMaintenance -Name $($VM.Name)"
    }
    if (-not $message) { return }
    Write-LogEntry $message 'WARN'
    Write-Warning $message
}
