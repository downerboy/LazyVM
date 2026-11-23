using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>Records the builds it is asked to start, without starting a process. Each build ends when the test says.</summary>
internal sealed class FakeBuildLauncher : BuildLauncher
{
    public List<(BuildRequest Request, string ModuleFolder)> Started { get; } = [];

    public TaskCompletionSource<BuildResult> Ending { get; private set; } = new();

    public Exception? Fails
    {
        get; set;
    }

    public int ProcessId { get; set; } = 4242;

    public override StartedBuild Start(BuildRequest request, string moduleFolder)
    {
        if (Fails is { } failure)
        {
            throw failure;
        }
        Started.Add((request, moduleFolder));
        Ending = new();
        return new StartedBuild(ProcessId, Ending.Task);
    }
}
