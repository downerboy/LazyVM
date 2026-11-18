namespace LazyVM.UI.Wpf;

/// <summary>
/// A build, maintenance or rebuild of a VM, as <c>Get-LazyVMDashboard</c>
/// reports it in <c>Run</c> and <c>LastBuild</c>: the one going now, or the
/// latest one.
/// </summary>
public sealed record VMRun
{
    /// <summary>Build, Maintenance or Rebuild; empty for a run just starting that has not recorded itself yet.</summary>
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

    public bool IsRunning => Status == Running;

    public bool IsBuild => Command == Build;

    public const string Build = "Build";
    public const string Running = "Running";
    public const string Completed = "Completed";
    public const string CompletedWithProblems = "CompletedWithProblems";
    public const string WaitingForRestart = "WaitingForRestart";
    public const string Failed = "Failed";
    public const string Stopped = "Stopped";
    public const string EndedUnexpectedly = "EndedUnexpectedly";
}

/// <summary>One phase of a build, from <c>Get-LazyVMBuildPhase</c>.</summary>
public sealed record BuildPhase(int Number, string Name, string Goal);

/// <summary>A config template a new VM can be built from, from <c>Get-LazyVMConfigTemplate</c>.</summary>
public sealed record ConfigTemplate(string Name, bool BuiltIn, bool Automatic);

/// <summary>
/// What to build: the VM's name and, for a new VM, optionally its config
/// template and administrator account. <see cref="FromPhase"/> starts at
/// that phase, such as the one a failed build was in; empty starts at the
/// beginning.
/// </summary>
public sealed record BuildRequest(string Name, string? ConfigTemplate, string? UserName, int? FromPhase = null);

/// <summary>
/// How a build process ended, as its script wrote it: Completed, Stopped or
/// Failed, with the error ID and message when it did not complete.
/// </summary>
public sealed record BuildResult(string Outcome, string? ErrorId, string? Message)
{
    public const string Completed = "Completed";
    public const string Stopped = "Stopped";
    public const string Failed = "Failed";
}
