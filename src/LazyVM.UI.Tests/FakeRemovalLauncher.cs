namespace LazyVM.UI.Tests;

/// <summary>Records the deletes it is asked to start, without starting a process. Each ends with <see cref="Result"/>.</summary>
internal sealed class FakeRemovalLauncher : RemovalLauncher
{
    public List<(RemovalRequest Request, string ModuleFolder)> Started { get; } = [];

    public RunResult Result
    {
        get; set;
    } = new(RunResult.COMPLETED, null, null);

    public Exception? Fails
    {
        get; set;
    }

    public override StartedRun Start(RemovalRequest request, string moduleFolder)
    {
        if (Fails is { } failure)
        {
            throw failure;
        }
        Started.Add((request, moduleFolder));
        return new StartedRun(4243, Task.FromResult(Result));
    }
}
