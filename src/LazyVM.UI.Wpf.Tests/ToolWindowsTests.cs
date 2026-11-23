using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class ToolWindowsTests
{
    private readonly FakeRunners _Runners = new();
    private readonly FakeToolWindows _Tools;

    public ToolWindowsTests()
    {
        _Tools = new FakeToolWindows(_Runners);
    }

    [Fact]
    public void OpenChecks_ShowsTheChecksAndRunsThem()
    {
        _Runners.Checks.ReturnsChecks(Sample.Check());

        _Tools.OpenChecks(null, "DevBox", hostOnly: false);

        var checks = Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Equal("DevBox", checks.VMName);
        Assert.Equal([("DevBox", false)], _Runners.Checks.CheckCalls);
    }

    [Fact]
    public void OpenChecks_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runners.Checks.ReturnsChecks(Sample.Check());

        _Tools.OpenChecks(null, "DevBox", hostOnly: false);
        _Tools.OpenChecks(null, "devbox", hostOnly: false);

        Assert.Same(Assert.Single(_Tools.Windows.Shown), Assert.Single(_Tools.Windows.BroughtToFront));
        Assert.Single(_Runners.Checks.CheckCalls);
    }

    [Fact]
    public void OpenChecks_OfTheHostAndOfAVM_AreTwoWindows()
    {
        _Runners.Checks.ReturnsChecks(Sample.Check());
        _Runners.Checks.ReturnsChecks(Sample.Check());

        _Tools.OpenChecks(null, null, hostOnly: true);
        _Tools.OpenChecks(null, "DevBox", hostOnly: false);

        Assert.Equal(2, _Tools.Windows.Shown.Count);
    }

    [Fact]
    public void ShowChecks_OfChecksAlreadyRun_ShowsThemWithoutRunningAgain()
    {
        var checks = new ChecksViewModel(_Runners.Checks, null, null, hostOnly: true);

        _Tools.ShowChecks(checks);

        Assert.Same(checks, Assert.Single(_Tools.Windows.Shown));
        Assert.Empty(_Runners.Checks.CheckCalls);
    }

    [Fact]
    public void OpenLog_ShowsTheLogAndReadsIt()
    {
        _Runners.Log.ReturnsLog(Sample.Log("Info", "a"));

        _Tools.OpenLog(null, "DevBox");

        var log = Assert.IsType<LogViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Equal("DevBox", log.VMName);
        Assert.Single(_Runners.Log.LogCalls);
    }

    [Fact]
    public void OpenLog_AfterItsWindowClosed_OpensANewWindow()
    {
        _Runners.Log.ReturnsLog();
        _Runners.Log.ReturnsLog();
        _Tools.OpenLog(null, "DevBox");
        _Tools.Windows.UserCloses(_Tools.Windows.Shown[0]);

        _Tools.OpenLog(null, "DevBox");

        Assert.Equal(2, _Tools.Windows.Shown.Count);
        Assert.Empty(_Tools.Windows.BroughtToFront);
    }

    [Fact]
    public void OpenBuild_ShowsTheBuildWindow_Once()
    {
        _Tools.OpenBuild(["DevBox"]);
        _Tools.OpenBuild(["DevBox"]);

        Assert.IsType<BuildViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Single(_Tools.Windows.BroughtToFront);
    }

    [Fact]
    public async Task ABuildStartedFromTheBuildWindow_OpensItsProgress()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(_Runners, launcher);
        _Runners.Dashboard.ReturnsRun(null, "TestBox");
        withLauncher.OpenBuild([]);
        var build = Assert.IsType<BuildViewModel>(withLauncher.Windows.Shown[0]);
        await build.LoadAsync();
        build.Name = "TestBox";

        await build.BuildAsync();

        var progress = Assert.IsType<BuildProgressViewModel>(withLauncher.Windows.Shown[1]);
        Assert.Equal("TestBox", progress.VMName);
        progress.StopFollowing();
    }

    [Fact]
    public void OpenProgress_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runners.Dashboard.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 });
        _Tools.OpenProgress(null, "DevBox", started: null);

        _Tools.OpenProgress(null, "DevBox", started: null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Same(progress, Assert.Single(_Tools.Windows.BroughtToFront));
        progress.StopFollowing();
    }

    [Fact]
    public void ClosingTheProgressWindow_StopsOnlyTheFollowing()
    {
        _Runners.Dashboard.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 });
        _Tools.OpenProgress(null, "DevBox", started: null);
        var progress = (BuildProgressViewModel)_Tools.Windows.Shown[0];

        _Tools.Windows.UserCloses(progress);

        Assert.Empty(_Runners.Build.StopCalls);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public void ANewBuild_ReplacesTheWindowOfAnEndedOne()
    {
        _Runners.Dashboard.ReturnsRun(null);
        _Tools.OpenProgress(null, "DevBox", started: null);
        var ended = (BuildProgressViewModel)_Tools.Windows.Shown[0];
        Assert.True(ended.IsFinished);
        _Runners.Dashboard.ReturnsRun(null);

        _Tools.OpenProgress(null, "DevBox", new StartedBuild(4242, new TaskCompletionSource<BuildResult>().Task));

        Assert.Same(ended, Assert.Single(_Tools.Windows.Closed));
        Assert.Equal(2, _Tools.Windows.Shown.Count);
        ((BuildProgressViewModel)_Tools.Windows.Shown[1]).StopFollowing();
    }

    [Fact]
    public async Task StartBuild_FromAPhase_StartsItOpensItsProgress_AndReportsIt()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(_Runners, launcher);
        var started = 0;
        withLauncher.Changes.Changed += (_, _) => started++;
        _Runners.Dashboard.ReturnsRun(null);

        await withLauncher.StartBuildAsync(null, new BuildRequest("DevBox", null, null, 7));

        var (request, _) = Assert.Single(launcher.Started);
        Assert.Equal(new BuildRequest("DevBox", null, null, 7), request);
        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(withLauncher.Windows.Shown));
        Assert.Equal("DevBox", progress.VMName);
        Assert.Equal(1, started);
        progress.StopFollowing();
    }

    [Fact]
    public async Task StartBuild_WhenItCannotStart_ThrowsAndReportsNothing()
    {
        var launcher = new FakeBuildLauncher { Fails = new InvalidOperationException("PowerShell 7.6 or later was not found.") };
        var withLauncher = new FakeToolWindows(_Runners, launcher);
        var started = 0;
        withLauncher.Changes.Changed += (_, _) => started++;

        await Assert.ThrowsAsync<InvalidOperationException>(() => withLauncher.StartBuildAsync(null, new BuildRequest("DevBox", null, null, 7)));

        Assert.Empty(withLauncher.Windows.Shown);
        Assert.Equal(0, started);
    }

    [Fact]
    public async Task CarryOn_FromAFailedBuildsWindow_StartsFromItsPhase_InANewWindow()
    {
        var launcher = new FakeBuildLauncher();
        var withLauncher = new FakeToolWindows(_Runners, launcher);
        _Runners.Dashboard.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 });
        withLauncher.OpenProgress(null, "DevBox", started: null);
        var failed = (BuildProgressViewModel)withLauncher.Windows.Shown[0];
        // The window follows the build it found running, until it reads the build as failed.
        failed.StopFollowing();
        _Runners.Dashboard.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.FAILED, ProcessId = 9, Phase = 7, UnfinishedPhase = 7 });
        await failed.PollAsync(CancellationToken.None);
        _Runners.Dashboard.ReturnsRun(null);

        await failed.CarryOnAsync();

        Assert.Equal(7, Assert.Single(launcher.Started).Request.FromPhase);
        Assert.Same(failed, Assert.Single(withLauncher.Windows.Closed));
        var next = Assert.IsType<BuildProgressViewModel>(withLauncher.Windows.Shown[1]);
        Assert.NotSame(failed, next);
        next.StopFollowing();
    }

    [Fact]
    public async Task StartMaintenance_RunsTheModulesCommand_AndReportsIt()
    {
        var started = 0;
        _Tools.Changes.Changed += (_, _) => started++;

        await _Tools.StartMaintenanceAsync(null, "DevBox");

        Assert.Equal(["DevBox"], _Runners.Build.MaintenanceCalls);
        Assert.Equal(1, started);
    }

    [Fact]
    public async Task StartMaintenance_WhenTheModuleStartsNothing_ThrowsItsReason_AndReportsNothing()
    {
        var started = 0;
        _Tools.Changes.Changed += (_, _) => started++;
        _Runners.Build.MaintenanceFails = new InvalidOperationException("A build of DevBox is running, so maintenance was not started.");

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => _Tools.StartMaintenanceAsync(null, "DevBox"));

        Assert.Contains("A build of DevBox is running", failure.Message);
        Assert.Equal(0, started);
    }

    [Fact]
    public void ABuildThatEnds_IsReported_SoTheListIsReadAgain()
    {
        var ended = 0;
        _Tools.Changes.Changed += (_, _) => ended++;
        _Runners.Dashboard.ReturnsRun(null);

        _Tools.OpenProgress(null, "DevBox", started: null);

        Assert.Equal(1, ended);
    }
}
