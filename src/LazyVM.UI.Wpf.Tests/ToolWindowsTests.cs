using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class ToolWindowsTests
{
    private readonly FakeCommandRunner runner = new();
    private readonly FakeToolWindows tools;

    public ToolWindowsTests()
    {
        tools = new FakeToolWindows(runner);
    }

    [Fact]
    public void OpenChecks_ShowsTheChecksAndRunsThem()
    {
        runner.ReturnsChecks(Sample.Check());

        tools.OpenChecks("DevBox", hostOnly: false);

        var checks = Assert.IsType<ChecksViewModel>(Assert.Single(tools.Shown));
        Assert.Equal("DevBox", checks.VMName);
        Assert.Equal([("DevBox", false)], runner.CheckCalls);
    }

    [Fact]
    public void OpenChecks_Twice_BringsTheOpenWindowToTheFront()
    {
        runner.ReturnsChecks(Sample.Check());

        tools.OpenChecks("DevBox", hostOnly: false);
        tools.OpenChecks("devbox", hostOnly: false);

        Assert.Same(Assert.Single(tools.Shown), Assert.Single(tools.BroughtToFront));
        Assert.Single(runner.CheckCalls);
    }

    [Fact]
    public void OpenChecks_OfTheHostAndOfAVM_AreTwoWindows()
    {
        runner.ReturnsChecks(Sample.Check());
        runner.ReturnsChecks(Sample.Check());

        tools.OpenChecks(null, hostOnly: true);
        tools.OpenChecks("DevBox", hostOnly: false);

        Assert.Equal(2, tools.Shown.Count);
    }

    [Fact]
    public void ShowChecks_OfChecksAlreadyRun_ShowsThemWithoutRunningAgain()
    {
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        tools.ShowChecks(checks);

        Assert.Same(checks, Assert.Single(tools.Shown));
        Assert.Empty(runner.CheckCalls);
    }

    [Fact]
    public void OpenLog_ShowsTheLogAndReadsIt()
    {
        runner.ReturnsLog(Sample.Log("Info", "a"));

        tools.OpenLog("DevBox");

        var log = Assert.IsType<LogViewModel>(Assert.Single(tools.Shown));
        Assert.Equal("DevBox", log.VMName);
        Assert.Single(runner.LogCalls);
    }

    [Fact]
    public void OpenLog_AfterItsWindowClosed_OpensANewWindow()
    {
        runner.ReturnsLog();
        runner.ReturnsLog();
        tools.OpenLog("DevBox");
        tools.Close(tools.Shown[0]);

        tools.OpenLog("DevBox");

        Assert.Equal(2, tools.Shown.Count);
        Assert.Empty(tools.BroughtToFront);
    }
}
