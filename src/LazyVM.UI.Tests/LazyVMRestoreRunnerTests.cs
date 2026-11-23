using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the restore runner reads a VM's restore points, and returns the VM to one in a process of its own.</summary>
public sealed class LazyVMRestoreRunnerTests
{
    private const string _MODULE_FOLDER = @"C:\Program Files\LazyVM\Modules\LazyVM\6.43.0";

    private readonly FakeRestoreLauncher _Launcher = new();

    private static ScriptedSessions SessionsOfTheModule()
    {
        return new ScriptedSessions { Answer = ScriptedSessions.Output(Entry(("ModuleBase", _MODULE_FOLDER))) };
    }

    [Fact]
    public void ToRestorePoint_ReadsEveryField()
    {
        var point = LazyVMRestoreRunner.LazyVMToRestorePoint(Entry(
            ("Name", "DevBox"),
            ("RestorePoint", "20261008-193000"),
            ("Taken", new DateTime(2026, 10, 8, 19, 30, 0)),
            ("Checkpoint", "LazyVM tooling 20261008-193000"),
            ("HasToolingList", false)));

        Assert.Equal(new VMRestorePoint("20261008-193000", new DateTime(2026, 10, 8, 19, 30, 0), HasToolingList: false), point);
    }

    [Fact]
    public async Task RestoreLazyVMToolingAsync_RunsInAProcessOfItsOwn()
    {
        using var sessions = SessionsOfTheModule();

        await new LazyVMRestoreRunner(sessions, _Launcher).RestoreLazyVMToolingAsync(null, "DevBox", "20261008-193000");

        Assert.Equal((new RestoreRequest("DevBox", "20261008-193000"), _MODULE_FOLDER), Assert.Single(_Launcher.Started));
        // Only the module's folder was read, in the host's session: the restore is not run in the app's.
        Assert.Equal("Get-Module", sessions.Call.Command);
    }

    [Fact]
    public async Task RestoreLazyVMToolingAsync_ThatFailed_ThrowsTheScriptsReason()
    {
        using var sessions = SessionsOfTheModule();
        _Launcher.Result = new RunResult(RunResult.FAILED, "LazyVM.RunInProgress", "A build of DevBox is running, so it was not restored.");

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(
            () => new LazyVMRestoreRunner(sessions, _Launcher).RestoreLazyVMToolingAsync(null, "DevBox", "20261008-193000"));

        Assert.Equal("A build of DevBox is running, so it was not restored.", failure.Message);
    }
}
