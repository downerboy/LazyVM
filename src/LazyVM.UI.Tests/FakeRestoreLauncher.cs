namespace LazyVM.UI.Tests;

/// <summary>Records the restores it is asked to start, without starting a process. Each ends with <see cref="Result"/>.</summary>
internal sealed class FakeRestoreLauncher : RestoreLauncher
{
    public List<(RestoreRequest Request, string ModuleFolder)> Started { get; } = [];

    public RunResult Result
    {
        get; set;
    } = new(RunResult.COMPLETED, null, null);

    public Exception? Fails
    {
        get; set;
    }

    public override StartedRun Start(RestoreRequest request, string moduleFolder)
    {
        if (Fails is { } failure)
        {
            throw failure;
        }
        Started.Add((request, moduleFolder));
        return new StartedRun(4244, Task.FromResult(Result));
    }
}
