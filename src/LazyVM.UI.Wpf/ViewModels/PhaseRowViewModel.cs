namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>One phase of the build: its number, its goal and how far it has got.</summary>
public sealed class PhaseRowViewModel(BuildPhase phase, string state)
{
    public const string NOT_STARTED = "Not started";
    public const string IN_PROGRESS = "In progress";
    public const string STOPPING = "Stopping";
    public const string DONE = "Done";
    public const string DONE_WITH_PROBLEMS = "Done, with problems";
    public const string WAITING_FOR_RESTART = "Waiting for the host to restart";
    public const string STOPPED = "Stopped";
    public const string FAILED = "Failed";

    public int Number => phase.Number;

    public string Goal => phase.Goal;

    public string State => state;

    /// <summary>True for the phase the build is in, or ended in.</summary>
    public bool IsCurrent => state is not (NOT_STARTED or DONE);

    /// <summary>A shape for the state, so it is never told by color alone.</summary>
    public string Symbol => state switch
    {
        DONE => "✓",
        NOT_STARTED => "○",
        IN_PROGRESS or STOPPING or WAITING_FOR_RESTART => "▶",
        DONE_WITH_PROBLEMS => "▲",
        _ => "✖",
    };

    /// <summary>The phase as a screen reader reads it, such as "Phase 7, Install Windows and the tools: In progress".</summary>
    public string AutomationName => $"Phase {Number}, {Goal}: {State}";
}
