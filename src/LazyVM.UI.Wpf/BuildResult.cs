namespace LazyVM.UI.Wpf;

/// <summary>
/// How a build process ended, as its script wrote it: Completed, Stopped or
/// Failed, with the error ID and message when it did not complete.
/// </summary>
public sealed record BuildResult(string Outcome, string? ErrorId, string? Message)
{
    public const string COMPLETED = "Completed";
    public const string STOPPED = "Stopped";
    public const string FAILED = "Failed";
}
