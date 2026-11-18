# RunState.ps1 - Which long run a VM has going: its build, maintenance, a rebuild, a restore or its removal (#425, #453).
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
#   Runs                one entry per command, Build, Maintenance, Rebuild,
#                       Restore (Restore-LazyVMTooling) or Remove:
#   Command             the command
#   Status              Running; at the end Completed, CompletedWithProblems,
#                       WaitingForRestart (the host restarts for Hyper-V and
#                       the resume task carries on), Failed or Stopped
#   ProcessId, Started, Ended
#   Phase, PhaseName    the build phase it is in, or was last in
#   UnfinishedPhase     the phase a failed or stopped run was in
#   PhasesWithProblems  the phases that finished with problems
#
# Stop-LazyVMBuild asks a run to stop by writing <VM>\Config\Run.stop with
# the run's ProcessId and Started (#426). The run checks for it at its safe
# points (Assert-VMRunNotStopped): between phases, between steps and in its
# wait loops. A request naming another run, one already ended, is ignored.
#
# A run that turns out to do nothing, such as a restore or removal the user
# did not confirm, calls Undo-VMRunRecord: Run.json is put back as it was,
# so the dashboard goes on showing the run before it.

$script:VMRun = $null
# The dashboard opens the lock for a moment to see whether it is held, so a
# run that finds it held tries again before giving up: 5 times, 200 ms apart.
$script:RunLockAttempts = 5
$script:RunLockRetryMilliseconds = 200

function Get-VMRunPath {
    <# The VM's run lock, run state and stop request: Run.lock, Run.json and Run.stop beside Resume.json, in its Config folder. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)

    $folder = Split-Path -Path $Settings.ResumeFile -Parent
    return [pscustomobject]@{
        Lock  = Join-Path -Path $folder -ChildPath 'Run.lock'
        State = Join-Path -Path $folder -ChildPath 'Run.json'
        Stop  = Join-Path -Path $folder -ChildPath 'Run.stop'
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
      Maintenance, Rebuild, Restore or Remove) and records it as running.
      False, writing nothing, when another run holds it. Runs never nest (maintenance runs
      a rebuild inside its own run), so a run started inside another one in
      this process is refused the same way, and the outer run's lock and
      state are left alone.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Command
    )

    if ($script:VMRun) { return $false }
    $paths = Get-VMRunPath -Settings $VM.Settings
    Assert-NoReparsePoint -Path $paths.Lock
    Assert-NoReparsePoint -Path $paths.State
    Assert-NoReparsePoint -Path $paths.Stop

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

    # As it was, for Undo-VMRunRecord. Nothing else writes the file while the lock is held.
    $previous = if (Test-Path -LiteralPath $paths.State -PathType Leaf) { [IO.File]::ReadAllText($paths.State) } else { $null }
    # The other commands' latest runs are kept.
    $runs = [ordered]@{}
    foreach ($earlier in (Read-VMRunDocument -Path $paths.State).Runs) {
        if ($earlier.Command -and $earlier.Command -ne $Command) { $runs[$earlier.Command] = $earlier }
    }
    # A request left from an earlier run is not for this one.
    Remove-VMRunStopRequest -Path $paths.Stop
    $script:VMRun = @{
        Lock     = $lock
        Path     = $paths.State
        StopPath = $paths.Stop
        VMName   = $VM.Name
        Stopping = $false
        Outcome  = $null
        Undo     = $false
        Previous = $previous
        Runs     = $runs
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

function Test-VMRunEntered {
    <# Whether this process holds a run lock. #>
    [OutputType([bool])]
    param()

    return [bool]$script:VMRun
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

function Undo-VMRunRecord {
    <#
      The run is not to be recorded, since it did nothing, or the VM's
      record goes with it: when it ends, Exit-VMRun puts Run.json back as it
      was before the run, or leaves none if there was none, and frees the
      lock. Nothing in a process that holds no run lock.
    #>
    if ($script:VMRun) { $script:VMRun.Undo = $true }
}

function Exit-VMRun {
    <#
      Records how the run ended and frees the lock. $Status is Completed
      (or the outcome the run set), Failed or Stopped; a failed or stopped
      run also records the phase it was in. After Undo-VMRunRecord it puts
      Run.json back as it was instead. Nothing in a process that holds no
      run lock, so a run that was refused never writes.
    #>
    param([Parameter(Mandatory)][ValidateSet('Completed', 'Failed', 'Stopped')][string]$Status)

    if (-not $script:VMRun) { return }
    try {
        if ($script:VMRun.Undo) {
            # Logged, not thrown, as Save-VMRunState does.
            try {
                if ($null -ne $script:VMRun.Previous) { Write-TextFileAtomic -Path $script:VMRun.Path -Text $script:VMRun.Previous }
                elseif (Test-Path -LiteralPath $script:VMRun.Path -PathType Leaf) { Remove-Item -LiteralPath $script:VMRun.Path -Force -ErrorAction Stop }
            }
            catch {
                Write-LogEntry "Could not put back the record of the run before this one in $($script:VMRun.Path): $($_.Exception.Message)" 'WARN'
            }
            Remove-VMRunStopRequest -Path $script:VMRun.StopPath
            return
        }
        $state = $script:VMRun.State
        $state.Status = if ($Status -eq 'Completed' -and $script:VMRun.Outcome) { $script:VMRun.Outcome } else { $Status }
        if ($Status -ne 'Completed') { $state.UnfinishedPhase = $state.Phase }
        $state.Ended = (Get-Date).ToString('o')
        Save-VMRunState
        Remove-VMRunStopRequest -Path $script:VMRun.StopPath
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
      Started, Ended, Phase, PhaseName, UnfinishedPhase,
      PhasesWithProblems and StopRequested, true while a running run has
      been asked to stop and has not stopped yet. The latest run, or with -Command the latest run
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
    Assert-NoReparsePoint -Path $paths.Stop -Root $Settings.Root
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
        StopRequested      = $false
    }
    if ($held -and $run.Status -ne 'Running') {
        # A new run has the lock but has not written its state yet: what is recorded is the last one's.
        foreach ($key in @($run.Keys)) { if ($key -ne 'PSTypeName') { $run[$key] = $null } }
        $run.Status = 'Running'
        $run.PhasesWithProblems = @()
        $run.StopRequested = $false
    }
    elseif (-not $held -and $run.Status -eq 'Running') {
        $run.Status = 'EndedUnexpectedly'
        $run.UnfinishedPhase = $run.Phase
    }
    elseif ($held) {
        $run.StopRequested = Test-VMRunStopMatch -Request (Read-VMRunStopRequest -Path $paths.Stop) -ProcessId $run.ProcessId -Started $run.Started
    }
    return [pscustomobject]$run
}

function Get-VMRunCommandText {
    <# A run's command as the start of a sentence, such as "A build"; $Unknown for a run that has not recorded itself yet. #>
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Command,
        [string]$Unknown = 'A run'
    )

    switch ($Command) {
        'Build' { 'A build' }
        'Maintenance' { 'Maintenance' }
        'Rebuild' { 'A rebuild' }
        'Restore' { 'A restore' }
        'Remove' { 'A removal' }
        default { $Unknown }
    }
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
    $what = Get-VMRunCommandText -Command $running.Command -Unknown 'Another long run'
    $since = if ($running.Started) { " (started $(([datetime]$running.Started).ToString('g')), process $($running.ProcessId))" } else { '' }
    return "$what of $($VM.Name) is already running$since, so this $($Title.ToLowerInvariant()) did not start. Wait for it to finish, then run it again."
}

function Read-VMRunStopRequest {
    <# The stop request at $Path: the ProcessId and Started of the run it is for. Nothing when there is none or it cannot be read. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try { $request = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return }
    if ($request -and $request.PSObject.Properties['ProcessId'] -and $request.PSObject.Properties['Started']) { return $request }
}

function Test-VMRunStopMatch {
    <#
      Whether the stop request $Request is for the run that started at
      $Started in process $ProcessId. Compared as instants: JSON may give a
      time back as text or as a date.
    #>
    [OutputType([bool])]
    param(
        [AllowNull()][object]$Request,
        [AllowNull()][object]$ProcessId,
        [AllowNull()][object]$Started
    )

    if (-not $Request -or $null -eq $ProcessId -or -not $Started -or -not $Request.Started) { return $false }
    try {
        $sameProcess = [int]$Request.ProcessId -eq [int]$ProcessId
        $sameStart = ([datetime]$Request.Started).ToUniversalTime() -eq ([datetime]$Started).ToUniversalTime()
        return $sameProcess -and $sameStart
    }
    catch { return $false }
}

function Remove-VMRunStopRequest {
    <# Deletes the stop request at $Path, if there is one. Logged, not thrown: it must not change how a run ends. #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        Assert-NoReparsePoint -Path $Path
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    }
    catch {
        Write-LogEntry "Could not remove the stop request $Path`: $($_.Exception.Message)" 'WARN'
    }
}

function Request-VMRunStop {
    <#
      Asks the run $Run of the VM, as Get-VMRunState read it, to stop: writes
      Run.stop with its ProcessId and Started, so it reaches that run and no
      later one.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][pscustomobject]$Run
    )

    $path = (Get-VMRunPath -Settings $Settings).Stop
    Assert-NoReparsePoint -Path $path -Root $Settings.Root
    $request = [pscustomobject]@{
        ProcessId = [int]$Run.ProcessId
        Started   = ([datetime]$Run.Started).ToUniversalTime().ToString('o')
        Requested = [datetime]::UtcNow.ToString('o')
    }
    Write-TextFileAtomic -Path $path -Text (ConvertTo-Json -InputObject $request)
}

function Test-VMRunStopRequested {
    <# Whether the run this process holds has been asked to stop. False in a process that holds no run lock. #>
    [OutputType([bool])]
    param()

    if (-not $script:VMRun) { return $false }
    $request = Read-VMRunStopRequest -Path $script:VMRun.StopPath
    return Test-VMRunStopMatch -Request $request -ProcessId $script:VMRun.State.ProcessId -Started $script:VMRun.State.Started
}

function Assert-VMRunNotStopped {
    <#
      A safe point of the run: throws a VMRunStoppedException when it has
      been asked to stop. Nothing in a process that holds no run lock.

      In a wait loop it throws once, so the clean-up that runs as the stop
      goes up (removing the answer-file disc, tidying up in the guest) is not
      stopped in turn. With -Boundary, between phases and between steps, it
      throws again whenever the run is stopping, so a stop that something
      took for a failure and carried on from still stops the run there.
    #>
    param([switch]$Boundary)

    if (-not $script:VMRun) { return }
    if ($script:VMRun.Stopping) {
        if ($Boundary) { throw (New-VMRunStoppedException) }
        return
    }
    if (-not (Test-VMRunStopRequested)) { return }
    $script:VMRun.Stopping = $true
    Write-LogEntry 'Asked to stop (Stop-LazyVMBuild): stopping here. Work already running in the guest carries on by itself: let an install there finish before running the build again.' 'WARN'
    throw (New-VMRunStoppedException)
}

function New-VMRunStoppedException {
    <# The VMRunStoppedException a stopped run ends with, naming the run and the phase it was in. #>
    [OutputType([VMRunStoppedException])]
    param()

    $what = switch ($script:VMRun.State.Command) {
        'Build' { 'The build' }
        'Maintenance' { 'Maintenance' }
        'Rebuild' { 'The rebuild' }
        default { 'The run' }
    }
    $where = if ($null -ne $script:VMRun.State.Phase) { " in phase $($script:VMRun.State.Phase), $($script:VMRun.State.PhaseName)" } else { '' }
    return [VMRunStoppedException]::new("$what of $($script:VMRun.VMName) was stopped$where, as asked.")
}

function Find-VMRunStoppedException {
    <#
      The VMRunStoppedException $Exception is, or wraps: as an inner
      exception, or as the exception of the error record it carries. Nothing
      when it is a failure, not a stop.
    #>
    [OutputType([VMRunStoppedException])]
    param([AllowNull()][Exception]$Exception)

    for ($current = $Exception; $current; $current = $current.InnerException) {
        if ($current -is [VMRunStoppedException]) { return $current }
        if ($current -is [System.Management.Automation.IContainsErrorRecord] -and $current.ErrorRecord -and $current.ErrorRecord.Exception -and
            -not [object]::ReferenceEquals($current.ErrorRecord.Exception, $current)) {
            $found = Find-VMRunStoppedException -Exception $current.ErrorRecord.Exception
            if ($found) { return $found }
        }
    }
}

function Test-VMRunStoppedError {
    <# Whether $Exception, or one it wraps, is a run stopping as asked rather than failing. #>
    [OutputType([bool])]
    param([AllowNull()][Exception]$Exception)

    return [bool](Find-VMRunStoppedException -Exception $Exception)
}