# RunState.ps1 - Which long run a VM has going: its build, maintenance or a rebuild (#425).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A run that changes a VM for a long time holds <VM>\Config\Run.lock open,
# shared with no one, until it ends. Windows closes the file when the
# process ends, however it ends, so a lock that can be opened means nothing
# is running, whatever Run.json says, and a process id used again never
# matters. Only the run holding the lock writes Run.json, each time whole
# (Write-TextFileAtomic): what the run is, the phase it is in and, at the
# end, how it ended. A run that finds the lock held is refused and writes
# nothing.
#
# Run.json holds the latest run of each command, so the nightly maintenance
# never hides where a failed build stopped:
#   Last                the command of the latest run
#   Runs                one entry per command, Build, Maintenance or Rebuild:
#   Command             the command
#   Status              Running; at the end Completed, CompletedWithProblems,
#                       WaitingForRestart (the host restarts for Hyper-V and
#                       the resume task carries on), Failed or Stopped
#   ProcessId, Started, Ended
#   Phase, PhaseName    the build phase it is in, or was last in
#   UnfinishedPhase     the phase a failed or stopped run was in
#   PhasesWithProblems  the phases that finished with problems

$script:VMRun = $null
# The dashboard opens the lock for a moment to see whether it is held, so a
# run that finds it held tries again before giving up: 5 times, 200 ms apart.
$script:RunLockAttempts = 5
$script:RunLockRetryMilliseconds = 200

function Get-VMRunPath {
    <# The VM's run lock and run state: Run.lock and Run.json beside Resume.json, in its Config folder. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $folder = Split-Path -Path $Settings.ResumeFile -Parent
    return [pscustomobject]@{
        Lock  = Join-Path -Path $folder -ChildPath 'Run.lock'
        State = Join-Path -Path $folder -ChildPath 'Run.json'
    }
}

function Test-SharingViolation {
    <# Whether $Exception, or one it wraps, says another process has the file open. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][Exception]$Exception)

    # ERROR_SHARING_VIOLATION and ERROR_LOCK_VIOLATION, as HRESULTs.
    $inUse = -2147024864, -2147024863
    for ($current = $Exception; $current; $current = $current.InnerException) {
        if ($current -is [IO.IOException] -and $current.HResult -in $inUse) { return $true }
    }
    return $false
}

function Enter-VMRun {
    <#
      Takes the VM's run lock for this process's $Command (Build,
      Maintenance or Rebuild) and records it as running. False, writing
      nothing, when another run holds it. True when this process holds it
      already, so a run inside a run is not refused.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Command
    )

    if ($script:VMRun) { return $true }
    $paths = Get-VMRunPath -Settings $VM.Settings
    Assert-NoReparsePoint -Path $paths.Lock
    Assert-NoReparsePoint -Path $paths.State

    $lock = $null
    for ($attempt = 1; -not $lock; $attempt++) {
        try {
            $lock = [IO.File]::Open($paths.Lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch {
            if (-not (Test-SharingViolation -Exception $_.Exception)) { throw }
            if ($attempt -ge $script:RunLockAttempts) { return $false }
            Start-Sleep -Milliseconds $script:RunLockRetryMilliseconds
        }
    }

    # The other commands' latest runs are kept. Nothing else writes the file while the lock is held.
    $runs = [ordered]@{}
    foreach ($earlier in (Read-VMRunDocument -Path $paths.State).Runs) {
        if ($earlier.Command -and $earlier.Command -ne $Command) { $runs[$earlier.Command] = $earlier }
    }
    $script:VMRun = @{
        Lock    = $lock
        Path    = $paths.State
        Outcome = $null
        Runs    = $runs
        State   = [ordered]@{
            Command            = $Command
            Status             = 'Running'
            ProcessId          = $PID
            Started            = (Get-Date).ToString('o')
            Ended              = $null
            Phase              = $null
            PhaseName          = $null
            UnfinishedPhase    = $null
            PhasesWithProblems = @()
        }
    }
    Save-VMRunState
    return $true
}

function Save-VMRunState {
    <#
      Writes the run's state. A state that cannot be written is logged, not
      thrown: it must never stop the build it describes.
    #>
    try {
        $runs = [ordered]@{}
        foreach ($key in $script:VMRun.Runs.Keys) { $runs[$key] = $script:VMRun.Runs[$key] }
        $runs[$script:VMRun.State.Command] = [pscustomobject]$script:VMRun.State
        $document = [pscustomobject]@{ Last = $script:VMRun.State.Command; Runs = [pscustomobject]$runs }
        Write-TextFileAtomic -Path $script:VMRun.Path -Text (ConvertTo-Json -InputObject $document -Depth 4)
    }
    catch {
        Write-LogEntry "Could not record the run's progress in $($script:VMRun.Path): $($_.Exception.Message)" 'WARN'
    }
}

function Set-VMRunPhase {
    <# Records the build phase the run is starting. Nothing in a process that holds no run lock. #>
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $script:VMRun) { return }
    $script:VMRun.State.Phase = $Number
    $script:VMRun.State.PhaseName = $Name
    Save-VMRunState
}

function Add-VMRunProblemPhase {
    <# Records that phase $Number finished with problems. Nothing in a process that holds no run lock. #>
    param([Parameter(Mandatory)][int]$Number)

    if (-not $script:VMRun) { return }
    $script:VMRun.State.PhasesWithProblems = @($script:VMRun.State.PhasesWithProblems) + $Number
    Save-VMRunState
}

function Set-VMRunOutcome {
    <#
      How the run ends if it ends without an error: CompletedWithProblems,
      or WaitingForRestart when the host restarts and the resume task
      carries on.
    #>
    param([Parameter(Mandatory)][ValidateSet('CompletedWithProblems', 'WaitingForRestart')][string]$Status)

    if ($script:VMRun) { $script:VMRun.Outcome = $Status }
}

function Exit-VMRun {
    <#
      Records how the run ended and frees the lock. $Status is Completed
      (or the outcome the run set), Failed or Stopped; a failed or stopped
      run also records the phase it was in. Nothing in a process that holds
      no run lock, so a run that was refused never writes.
    #>
    param([Parameter(Mandatory)][ValidateSet('Completed', 'Failed', 'Stopped')][string]$Status)

    if (-not $script:VMRun) { return }
    try {
        $state = $script:VMRun.State
        $state.Status = if ($Status -eq 'Completed' -and $script:VMRun.Outcome) { $script:VMRun.Outcome } else { $Status }
        if ($Status -ne 'Completed') { $state.UnfinishedPhase = $state.Phase }
        $state.Ended = (Get-Date).ToString('o')
        Save-VMRunState
    }
    finally {
        $script:VMRun.Lock.Dispose()
        $script:VMRun = $null
    }
}

function Test-VMRunLockHeld {
    <#
      Whether a run holds the lock at $Path. Opens it for a moment to see,
      never creates it. Only "in use" counts as held; any other problem is
      thrown, for the caller to report.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite).Dispose()
        return $false
    }
    catch {
        if (Test-SharingViolation -Exception $_.Exception) { return $true }
        # Gone between the test and the open: nothing holds it.
        if ($_.Exception.InnerException -is [IO.FileNotFoundException] -or $_.Exception -is [IO.FileNotFoundException]) { return $false }
        throw
    }
}

function Read-VMRunDocument {
    <#
      Run.json as Last and Runs, Runs as a list of the runs recorded.
      Empty when there is no file or it cannot be read: it only describes
      runs, so a damaged one is started again rather than stopping a build.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $empty = [pscustomobject]@{ Last = $null; Runs = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    try { $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return $empty }
    if (-not $document -or -not $document.PSObject.Properties['Runs'] -or -not $document.Runs) { return $empty }
    return [pscustomobject]@{
        Last = if ($document.PSObject.Properties['Last']) { $document.Last } else { $null }
        Runs = @($document.Runs.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $_ -and $_.PSObject.Properties['Command'] })
    }
}

function Get-VMRunState {
    <#
      A long run of the VM, as a LazyVM.VMRun: Command, Status, ProcessId,
      Started, Ended, Phase, PhaseName, UnfinishedPhase and
      PhasesWithProblems. The latest run, or with -Command the latest run
      of that command (Build, Maintenance or Rebuild). Status is Running
      while a run holds the lock, even one that has not written its state
      yet, and EndedUnexpectedly for one recorded as running whose lock is
      free: its process was killed, crashed or lost power. Nothing when
      there has been no such run. Only reads.
    #>
    [OutputType('LazyVM.VMRun')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [ValidateSet('Build', 'Maintenance', 'Rebuild')][string]$Command
    )

    $paths = Get-VMRunPath -Settings $Settings
    Assert-NoReparsePoint -Path $paths.State -Root $Settings.Root
    $held = Test-VMRunLockHeld -Path $paths.Lock
    $document = Read-VMRunDocument -Path $paths.State
    $wanted = if ($Command) { $Command } else { $document.Last }
    $recorded = $document.Runs | Where-Object { $_.Command -eq $wanted } | Select-Object -First 1
    # The lock belongs to the latest run: an earlier one of another command is not the one running.
    if ($wanted -ne $document.Last) { $held = $false }
    if ($Command -and -not $recorded) { return }
    if (-not $recorded -and -not $held) { return }

    function Read-Field([string]$Name) { if ($recorded -and $recorded.PSObject.Properties[$Name]) { $recorded.$Name } }
    $run = [ordered]@{
        PSTypeName         = 'LazyVM.VMRun'
        Command            = Read-Field 'Command'
        Status             = Read-Field 'Status'
        ProcessId          = Read-Field 'ProcessId'
        Started            = Read-Field 'Started'
        Ended              = Read-Field 'Ended'
        Phase              = Read-Field 'Phase'
        PhaseName          = Read-Field 'PhaseName'
        UnfinishedPhase    = Read-Field 'UnfinishedPhase'
        PhasesWithProblems = @(Read-Field 'PhasesWithProblems' | Where-Object { $null -ne $_ })
    }
    if ($held -and $run.Status -ne 'Running') {
        # A new run has the lock but has not written its state yet: what is recorded is the last one's.
        foreach ($key in @($run.Keys)) { if ($key -ne 'PSTypeName') { $run[$key] = $null } }
        $run.Status = 'Running'
        $run.PhasesWithProblems = @()
    }
    elseif (-not $held -and $run.Status -eq 'Running') {
        $run.Status = 'EndedUnexpectedly'
        $run.UnfinishedPhase = $run.Phase
    }
    return [pscustomobject]$run
}

function Get-VMRunBusyMessage {
    <# Why $Title of the VM $VM did not start: the run already going, as Get-VMRunState reads it. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Title
    )

    $running = $null
    try { $running = Get-VMRunState -Settings $VM.Settings } catch { $null = $_ }
    $what = switch ($running.Command) {
        'Build' { 'A build' }
        'Maintenance' { 'Maintenance' }
        'Rebuild' { 'A rebuild' }
        default { 'Another long run' }
    }
    $since = if ($running.Started) { " (started $(([datetime]$running.Started).ToString('g')), process $($running.ProcessId))" } else { '' }
    return "$what of $($VM.Name) is already running$since, so this $($Title.ToLowerInvariant()) did not start. Wait for it to finish, then run it again."
}
