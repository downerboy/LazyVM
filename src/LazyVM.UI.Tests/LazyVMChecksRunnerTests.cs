using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the checks runner reads Test-LazyVM's checks, and where it runs them.</summary>
public sealed class LazyVMChecksRunnerTests
{
    [Fact]
    public async Task GetLazyVMChecksAsync_OfTheHost_RunsInTheHostsSession_WithHostOnly()
    {
        using var sessions = new ScriptedSessions();

        await new LazyVMChecksRunner(sessions).GetLazyVMChecksAsync(null, null, hostOnly: true, CancellationToken.None);

        Assert.Same(sessions.ForHost(), sessions.Call.Session);
        Assert.Equal(["HostOnly"], sessions.Call.Parameters.Keys);
    }

    [Fact]
    public async Task GetLazyVMChecksAsync_OfAVM_RunsInTheVMsSession_WithItsName()
    {
        using var sessions = new ScriptedSessions();
        var id = Guid.NewGuid();

        await new LazyVMChecksRunner(sessions).GetLazyVMChecksAsync(id, "DevBox", hostOnly: false, CancellationToken.None);

        Assert.Same(sessions.ForVM(id), sessions.Call.Session);
        Assert.Equal("DevBox", Assert.Single(sessions.Call.Parameters).Value);
    }

    [Fact]
    public void ToCheck_ReadsEveryField()
    {
        var check = LazyVMChecksRunner.LazyVMCheck(Entry(
            ("Name", "DevBox"),
            ("Area", "Schedule"),
            ("Check", "Maintenance task"),
            ("Status", "WARN"),
            ("Detail", "not scheduled"),
            ("Fix", "Schedule it with: Register-LazyVMMaintenance -Name DevBox")));

        Assert.Equal(new VMCheck("Schedule", "Maintenance task", "WARN", "not scheduled", "Schedule it with: Register-LazyVMMaintenance -Name DevBox"), check);
    }

    [Fact]
    public void ToCheck_WithoutAFix_HasAnEmptyFix()
    {
        var check = LazyVMChecksRunner.LazyVMCheck(Entry(("Area", "Host"), ("Check", "LazyVM folder"), ("Status", "OK"), ("Detail", @"C:\Users\me\LazyVM")));

        Assert.Equal(string.Empty, check.Fix);
    }
}
