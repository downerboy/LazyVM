using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the log runner reads a VM's log entries, and where it runs.</summary>
public sealed class LazyVMLogRunnerTests
{
    [Fact]
    public async Task GetLazyVMLogAsync_RunsInTheVMsSession()
    {
        using var sessions = new ScriptedSessions();
        var id = Guid.NewGuid();

        await new LazyVMLogRunner(sessions).GetLazyVMLogAsync(id, "DevBox", 200, CancellationToken.None);

        Assert.Same(sessions.ForVM(id), sessions.Call.Session);
        Assert.Equal("Get-LazyVMLog", sessions.Call.Command);
        Assert.Equal(200, sessions.Call.Parameters["Tail"]);
    }

    [Fact]
    public void ToLogEntry_ReadsEveryField()
    {
        var time = new DateTime(2026, 11, 12, 2, 10, 5);

        var entry = LazyVMLogRunner.LazyVMLogEntry(Entry(("Time", time), ("Level", "Error"), ("Message", "Windows Update failed\nwith 0x80070005")));

        Assert.Equal(new VMLogEntry(time, "Error", "Windows Update failed\nwith 0x80070005"), entry);
    }

    [Fact]
    public void ToLogEntry_ATimeThatCannotBeRead_IsLeftEmpty()
    {
        var entry = LazyVMLogRunner.LazyVMLogEntry(Entry(("Time", "yesterday"), ("Level", "Info"), ("Message", "Started")));

        Assert.Null(entry.Time);
        Assert.Equal("Started", entry.Message);
    }
}
