namespace LazyVM.UI.Wpf;

/// <summary>
/// A build, maintenance, rebuild, restore or removal of a VM, as <c>Get-LazyVMDashboard</c>
/// reports it in <c>Run</c> and <c>LastBuild</c>: the one going now, or the
/// latest one.
/// </summary>
public sealed record VMRun
{
    /// <summary>Build, Maintenance, Rebuild, Restore or Remove; empty for a run just starting that has not recorded itself yet.</summary>
    public string? Command
    {
        get; init;
    }

    /// <summary>Running, Completed, CompletedWithProblems, WaitingForRestart, Failed, Stopped or EndedUnexpectedly.</summary>
    public string? Status
    {
        get; init;
    }

    /// <summary>The process the run is in; empty until it has recorded itself.</summary>
    public int? ProcessId
    {
        get; init;
    }

    public DateTime? Started
    {
        get; init;
    }

    public DateTime? Ended
    {
        get; init;
    }

    /// <summary>The phase the run is in, or was last in.</summary>
    public int? Phase
    {
        get; init;
    }

    public string? PhaseName
    {
        get; init;
    }

    /// <summary>The phase a failed or stopped run was in: the one to carry on from.</summary>
    public int? UnfinishedPhase
    {
        get; init;
    }

    /// <summary>True while a running build has been asked to stop and has not stopped yet.</summary>
    public bool StopRequested
    {
        get; init;
    }

    public bool IsRunning => Status == RUNNING;

    public bool IsBuild => Command == BUILD;

    public const string BUILD = "Build";
    public const string RUNNING = "Running";
    public const string COMPLETED = "Completed";
    public const string COMPLETED_WITH_PROBLEMS = "CompletedWithProblems";
    public const string WAITING_FOR_RESTART = "WaitingForRestart";
    public const string FAILED = "Failed";
    public const string STOPPED = "Stopped";
    public const string ENDED_UNEXPECTEDLY = "EndedUnexpectedly";
}
