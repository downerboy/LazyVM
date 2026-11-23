namespace LazyVM.UI;

/// <summary>A build, delete or restore process the app started: its ID, and its outcome once it has ended.</summary>
public sealed record StartedRun(int ProcessId, Task<RunResult> Ended);
