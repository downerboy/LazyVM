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
# run by hand warns about it, and Test-LazyVM reports it.

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
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Trigger,
        [Parameter(Mandatory)]$Settings
    )

    $credential = Get-TaskCredential
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings `
            -User $credential.UserName -Password $credential.GetNetworkCredential().Password -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $script:TaskCredential = $null
        if (Test-LogonFailureError -ErrorRecord $_) {
            throw "Windows did not accept the password for $($credential.UserName), so '$TaskName' was not scheduled. Use your account's password, not your PIN, and try again."
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

function Write-TaskLogonWarning {
    <# Warns, and logs, when the VM's daily maintenance could not start because the password Task Scheduler has is out of date. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not (Test-TaskLogonFailure -TaskName $VM.Settings.ScheduleTaskName)) { return }
    $message = "The daily maintenance of $($VM.Name) could not start: Windows did not accept the password Task Scheduler has for you, probably because you changed it. Enter the new one with: Register-LazyVMMaintenance -Name $($VM.Name)"
    Write-LogEntry $message 'WARN'
    Write-Warning $message
}
