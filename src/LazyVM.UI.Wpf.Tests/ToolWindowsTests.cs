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

    [Fact]
    public void OpenBuild_ShowsTheBuildWindow_Once()
    {
        tools.OpenBuild(["DevBox"]);
        tools.OpenBuild(["DevBox"]);

        Assert.IsType<BuildViewModel>(Assert.Single(tools.Shown));
        Assert.Single(tools.BroughtToFront);
    }

    [Fact]
    public async Task ABuildStartedFromTheBuildWindow_OpensItsProgress()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(runner, launcher);
        runner.ReturnsRun(null, "TestBox");
        withLauncher.OpenBuild([]);
        var build = Assert.IsType<BuildViewModel>(withLauncher.Shown[0]);
        await build.LoadAsync();
        build.Name = "TestBox";

        await build.BuildAsync();

        var progress = Assert.IsType<BuildProgressViewModel>(withLauncher.Shown[1]);
        Assert.Equal("TestBox", progress.VMName);
        progress.StopFollowing();
    }

    [Fact]
    public void OpenProgress_Twice_BringsTheOpenWindowToTheFront()
    {
        runner.ReturnsRun(new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 });
        tools.OpenProgress("DevBox", started: null);

        tools.OpenProgress("DevBox", started: null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(tools.Shown));
        Assert.Same(progress, Assert.Single(tools.BroughtToFront));
        progress.StopFollowing();
    }

    [Fact]
    public void ClosingTheProgressWindow_StopsOnlyTheFollowing()
    {
        runner.ReturnsRun(new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 });
        tools.OpenProgress("DevBox", started: null);
        var progress = (BuildProgressViewModel)tools.Shown[0];

        tools.Close(progress);

        Assert.Empty(runner.StopCalls);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public void ANewBuild_ReplacesTheWindowOfAnEndedOne()
    {
        runner.ReturnsRun(null);
        tools.OpenProgress("DevBox", started: null);
        var ended = (BuildProgressViewModel)tools.Shown[0];
        Assert.True(ended.IsFinished);
        runner.ReturnsRun(null);

        tools.OpenProgress("DevBox", new StartedBuild(4242, new TaskCompletionSource<BuildResult>().Task));

        Assert.Same(ended, Assert.Single(tools.Closed));
        Assert.Equal(2, tools.Shown.Count);
        ((BuildProgressViewModel)tools.Shown[1]).StopFollowing();
    }

    [Fact]
    public void ABuildThatEnds_IsReported_SoTheListIsReadAgain()
    {
        var ended = 0;
        tools.BuildEnded += (_, _) => ended++;
        runner.ReturnsRun(null);

        tools.OpenProgress("DevBox", started: null);

        Assert.Equal(1, ended);
    }
}
