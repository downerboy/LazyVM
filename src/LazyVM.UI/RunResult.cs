namespace LazyVM.UI;

/// <summary>
/// How a build, delete or restore process ended, as its script wrote it:
/// Completed, Stopped or Failed, with the error ID and message when it did
/// not complete.
/// </summary>
public sealed record RunResult(string Outcome, string? ErrorId, string? Message)
{
    public const string COMPLETED = "Completed";
    public const string STOPPED = "Stopped";
    public const string FAILED = "Failed";
}
