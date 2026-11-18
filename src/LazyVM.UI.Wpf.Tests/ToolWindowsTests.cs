using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class ToolWindowsTests
{
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeToolWindows _Tools;

    public ToolWindowsTests()
    {
        _Tools = new FakeToolWindows(_Runner);
    }

    [Fact]
    public void OpenChecks_ShowsTheChecksAndRunsThem()
    {
        _Runner.ReturnsChecks(Sample.Check());

        _Tools.OpenChecks("DevBox", hostOnly: false);

        var checks = Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("DevBox", checks.VMName);
        Assert.Equal([("DevBox", false)], _Runner.CheckCalls);
    }

    [Fact]
    public void OpenChecks_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runner.ReturnsChecks(Sample.Check());

        _Tools.OpenChecks("DevBox", hostOnly: false);
        _Tools.OpenChecks("devbox", hostOnly: false);

        Assert.Same(Assert.Single(_Tools.Shown), Assert.Single(_Tools.BroughtToFront));
        Assert.Single(_Runner.CheckCalls);
    }

    [Fact]
    public void OpenChecks_OfTheHostAndOfAVM_AreTwoWindows()
    {
        _Runner.ReturnsChecks(Sample.Check());
        _Runner.ReturnsChecks(Sample.Check());

        _Tools.OpenChecks(null, hostOnly: true);
        _Tools.OpenChecks("DevBox", hostOnly: false);

        Assert.Equal(2, _Tools.Shown.Count);
    }

    [Fact]
    public void ShowChecks_OfChecksAlreadyRun_ShowsThemWithoutRunningAgain()
    {
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        _Tools.ShowChecks(checks);

        Assert.Same(checks, Assert.Single(_Tools.Shown));
        Assert.Empty(_Runner.CheckCalls);
    }

    [Fact]
    public void OpenLog_ShowsTheLogAndReadsIt()
    {
        _Runner.ReturnsLog(Sample.Log("Info", "a"));

        _Tools.OpenLog("DevBox");

        var log = Assert.IsType<LogViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("DevBox", log.VMName);
        Assert.Single(_Runner.LogCalls);
    }

    [Fact]
    public void OpenLog_AfterItsWindowClosed_OpensANewWindow()
    {
        _Runner.ReturnsLog();
        _Runner.ReturnsLog();
        _Tools.OpenLog("DevBox");
        _Tools.Close(_Tools.Shown[0]);

        _Tools.OpenLog("DevBox");

        Assert.Equal(2, _Tools.Shown.Count);
        Assert.Empty(_Tools.BroughtToFront);
    }

    [Fact]
    public void OpenBuild_ShowsTheBuildWindow_Once()
    {
        _Tools.OpenBuild(["DevBox"]);
        _Tools.OpenBuild(["DevBox"]);

        Assert.IsType<BuildViewModel>(Assert.Single(_Tools.Shown));
        Assert.Single(_Tools.BroughtToFront);
    }

    [Fact]
    public async Task ABuildStartedFromTheBuildWindow_OpensItsProgress()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(_Runner, launcher);
        _Runner.ReturnsRun(null, "TestBox");
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
        _Runner.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 });
        _Tools.OpenProgress("DevBox", started: null);

        _Tools.OpenProgress("DevBox", started: null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Shown));
        Assert.Same(progress, Assert.Single(_Tools.BroughtToFront));
        progress.StopFollowing();
    }

    [Fact]
    public void ClosingTheProgressWindow_StopsOnlyTheFollowing()
    {
        _Runner.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 });
        _Tools.OpenProgress("DevBox", started: null);
        var progress = (BuildProgressViewModel)_Tools.Shown[0];

        _Tools.Close(progress);

        Assert.Empty(_Runner.StopCalls);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public void ANewBuild_ReplacesTheWindowOfAnEndedOne()
    {
        _Runner.ReturnsRun(null);
        _Tools.OpenProgress("DevBox", started: null);
        var ended = (BuildProgressViewModel)_Tools.Shown[0];
        Assert.True(ended.IsFinished);
        _Runner.ReturnsRun(null);

        _Tools.OpenProgress("DevBox", new StartedBuild(4242, new TaskCompletionSource<BuildResult>().Task));

        Assert.Same(ended, Assert.Single(_Tools.Closed));
        Assert.Equal(2, _Tools.Shown.Count);
        ((BuildProgressViewModel)_Tools.Shown[1]).StopFollowing();
    }

    [Fact]
    public async Task StartBuild_FromAPhase_StartsItOpensItsProgress_AndReportsIt()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(_Runner, launcher);
        var started = 0;
        withLauncher.RunStarted += (_, _) => started++;
        _Runner.ReturnsRun(null);

        await withLauncher.StartBuildAsync(new BuildRequest("DevBox", null, null, 7));

        var (request, _) = Assert.Single(launcher.Started);
        Assert.Equal(new BuildRequest("DevBox", null, null, 7), request);
        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(withLauncher.Shown));
        Assert.Equal("DevBox", progress.VMName);
        Assert.Equal(1, started);
        progress.StopFollowing();
    }

    [Fact]
    public async Task StartBuild_WhenItCannotStart_ThrowsAndReportsNothing()
    {
        var launcher = new FakeBuildLauncher { Fails = new InvalidOperationException("PowerShell 7.6 or later was not found.") };
        var withLauncher = new FakeToolWindows(_Runner, launcher);
        var started = 0;
        withLauncher.RunStarted += (_, _) => started++;

        await Assert.ThrowsAsync<InvalidOperationException>(() => withLauncher.StartBuildAsync(new BuildRequest("DevBox", null, null, 7)));

        Assert.Empty(withLauncher.Shown);
        Assert.Equal(0, started);
    }

    [Fact]
    public async Task CarryOn_FromAFailedBuildsWindow_StartsFromItsPhase_InANewWindow()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(_Runner, launcher);
        _Runner.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 });
        withLauncher.OpenProgress("DevBox", started: null);
        var failed = (BuildProgressViewModel)withLauncher.Shown[0];
        // The window follows the build it found running, until it reads the build as failed.
        failed.StopFollowing();
        _Runner.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.FAILED, ProcessId = 9, Phase = 7, UnfinishedPhase = 7 });
        await failed.PollAsync(CancellationToken.None);
        _Runner.ReturnsRun(null);

        await failed.CarryOnAsync();

        Assert.Equal(7, Assert.Single(launcher.Started).Request.FromPhase);
        Assert.Same(failed, Assert.Single(withLauncher.Closed));
        var next = Assert.IsType<BuildProgressViewModel>(withLauncher.Shown[1]);
        Assert.NotSame(failed, next);
        next.StopFollowing();
    }

    [Fact]
    public async Task StartMaintenance_RunsTheModulesCommand_AndReportsIt()
    {
        var started = 0;
        _Tools.RunStarted += (_, _) => started++;

        await _Tools.StartMaintenanceAsync("DevBox");

        Assert.Equal(["DevBox"], _Runner.MaintenanceCalls);
        Assert.Equal(1, started);
    }

    [Fact]
    public async Task StartMaintenance_WhenTheModuleStartsNothing_ThrowsItsReason_AndReportsNothing()
    {
        var started = 0;
        _Tools.RunStarted += (_, _) => started++;
        _Runner.MaintenanceFails = new InvalidOperationException("A build of DevBox is running, so maintenance was not started.");

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => _Tools.StartMaintenanceAsync("DevBox"));

        Assert.Contains("A build of DevBox is running", failure.Message);
        Assert.Equal(0, started);
    }

    [Fact]
    public void ABuildThatEnds_IsReported_SoTheListIsReadAgain()
    {
        var ended = 0;
        _Tools.BuildEnded += (_, _) => ended++;
        _Runner.ReturnsRun(null);

        _Tools.OpenProgress("DevBox", started: null);

        Assert.Equal(1, ended);
    }
}
