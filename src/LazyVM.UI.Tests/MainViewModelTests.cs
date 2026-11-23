using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

public sealed class MainViewModelTests : IDisposable
{
    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeRunners _Runners = new();
    private readonly FakeToolWindows _Tools;

    /// <summary>The VM windows opened, as view models.</summary>
    private IReadOnlyList<VMViewModel> ShownVMs => [.. _Tools.Windows.Shown.OfType<VMViewModel>()];
    private readonly MainViewModel _Main;

    public MainViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runners);
        _Main = new MainViewModel(_Runners.Dashboard, _Runners.Checks, _Runners.Help, _Tools, _Tools.Changes, new FixedClock(new DateTimeOffset(2026, 11, 14, 14, 52, 0, TimeSpan.Zero)));
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private static VMRun RunningNow(string command)
    {
        return new VMRun { Command = command, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 };
    }

    [Theory]
    [InlineData(HelpTopic.Guide, "the guide")]
    [InlineData(HelpTopic.UseCases, "the use cases")]
    [InlineData(HelpTopic.Diagrams, "the diagrams")]
    public async Task OpenHelp_AsksForThePage_AndSaysWhichOpened(HelpTopic topic, string said)
    {
        await _Main.OpenHelpAsync(topic);

        Assert.Equal([topic], _Runners.Help.HelpCalls);
        Assert.Equal($"Opened {said} in your browser", _Main.Status);
    }

    [Fact]
    public async Task OpenHelp_WhenTheBrowserDoesNotOpen_SaysWhy()
    {
        _Runners.Help.HelpFails = new InvalidOperationException("Could not open your browser: none is set.");

        await _Main.OpenHelpAsync(HelpTopic.UseCases);

        Assert.Equal("Could not open the use cases: Could not open your browser: none is set.", _Main.Status);
        Assert.False(_Main.IsWorking);
    }

    [Fact]
    public void HelpCommands_EachOpenTheirOwnPage()
    {
        _Main.GuideCommand.Execute(null);
        _Main.UseCasesCommand.Execute(null);
        _Main.DiagramsCommand.Execute(null);

        Assert.Equal([HelpTopic.Guide, HelpTopic.UseCases, HelpTopic.Diagrams], _Runners.Help.HelpCalls);
    }

    [Fact]
    public async Task BuildProgress_IsOfferedForTheSelectedVM_OnlyWhileItBuilds()
    {
        _Runners.Dashboard.Returns(
            Sample.VM("Idle"),
            Sample.VM("Building") with
            {
                Run = RunningNow(VMRun.BUILD)
            },
            Sample.VM("Maintaining") with
            {
                Run = RunningNow("Maintenance")
            });
        await _Main.RefreshAsync();

        // A loop, not a query: each row is selected in turn.
        var offered = new List<(string, bool, bool)>();
        foreach (var row in _Main.VMs)
        {
            _Main.SelectedVM = row;
            offered.Add((row.Name, _Main.BuildProgressCommand.CanExecute(null), _Main.SelectedVMIsBuilding));
        }
        _Main.SelectedVM = null;

        Assert.Equal([("Idle", false, false), ("Building", true, true), ("Maintaining", false, false)], offered);
        Assert.False(_Main.BuildProgressCommand.CanExecute(null));
    }

    [Fact]
    public async Task BuildProgress_OpensTheProgressOfTheSelectedVMsBuild()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevEnv") with
        {
            Run = RunningNow(VMRun.BUILD)
        });
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs.Single();

        _Main.BuildProgressCommand.Execute(null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        progress.StopFollowing();
    }

    [Fact]
    public async Task BuildProgress_FollowsARefresh_WhenTheSelectedVMStartsOrStopsBuilding()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevEnv"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs.Single();
        var changed = new List<string?>();
        _Main.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        var asked = 0;
        _Main.BuildProgressCommand.CanExecuteChanged += (_, _) => asked++;

        _Runners.Dashboard.Returns(Sample.VM("DevEnv") with
        {
            Run = RunningNow(VMRun.BUILD)
        });
        await _Main.RefreshAsync();

        Assert.True(_Main.SelectedVMIsBuilding);
        Assert.Contains(nameof(MainViewModel.SelectedVMIsBuilding), changed);
        Assert.True(asked > 0);
    }

    [Fact]
    public async Task Refresh_IsWorkingWhileTheListIsRead()
    {
        _Runners.Dashboard.Returns(Sample.VM());
        var watcher = new WorkWatcher(_Main);

        await _Main.RefreshAsync();

        Assert.Equal(["Reading your VMs", null], watcher.Seen);
    }

    [Fact]
    public async Task Refresh_ShowsOneRowPerVM()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"), Sample.VM("PlainWin"), Sample.VM("TestBox"));

        await _Main.RefreshAsync();

        Assert.Equal(["DevBox", "PlainWin", "TestBox"], _Main.VMs.Select(row => row.Name));
    }

    [Fact]
    public async Task Refresh_SaysWhatItDidInTheStatusLine()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"), Sample.VM("PlainWin"), Sample.VM("TestBox"));

        await _Main.RefreshAsync();

        Assert.Equal("Refreshed 3 VMs at 14:52", _Main.Status);
    }

    [Fact]
    public async Task Refresh_OfOneVM_SaysVMNotVMs()
    {
        _Runners.Dashboard.Returns(Sample.VM());

        await _Main.RefreshAsync();

        Assert.Equal("Refreshed 1 VM at 14:52", _Main.Status);
    }

    [Fact]
    public async Task Refresh_WhenTheCommandFails_KeepsTheListAndSaysWhy()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        _Runners.Dashboard.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        await _Main.RefreshAsync();

        await _Main.RefreshAsync();

        Assert.Equal(["DevBox"], _Main.VMs.Select(row => row.Name));
        Assert.Equal("Refresh failed: The LazyVM folder was not found.", _Main.Status);
    }

    [Fact]
    public async Task CancelRefresh_StopsTheCallAndKeepsTheList()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        _Runners.Dashboard.WaitsForCancel();
        await _Main.RefreshAsync();

        var refresh = _Main.RefreshAsync();
        Assert.True(_Main.IsRefreshing);
        _Main.CancelRefreshCommand.Execute(null);
        await refresh;

        Assert.False(_Main.IsRefreshing);
        Assert.Equal(["DevBox"], _Main.VMs.Select(row => row.Name));
        Assert.Equal("Refresh cancelled", _Main.Status);
    }

    [Fact]
    public async Task RefreshCommand_IsUnavailableWhileARefreshRuns()
    {
        _Runners.Dashboard.WaitsForCancel();

        var refresh = _Main.RefreshAsync();

        Assert.False(_Main.RefreshCommand.CanExecute(null));
        Assert.True(_Main.CancelRefreshCommand.CanExecute(null));
        _Main.CancelRefreshCommand.Execute(null);
        await refresh;
        Assert.True(_Main.RefreshCommand.CanExecute(null));
        Assert.False(_Main.CancelRefreshCommand.CanExecute(null));
    }

    [Fact]
    public async Task Refresh_KeepsTheSelectedVMSelected()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"), Sample.VM("TestBox"));
        _Runners.Dashboard.Returns(Sample.VM("DevBox", "Off"), Sample.VM("TestBox", "Off"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[1];

        await _Main.RefreshAsync();

        Assert.Equal("TestBox", _Main.SelectedVM?.Name);
        Assert.Equal("Off", _Main.SelectedVM?.State);
    }

    [Fact]
    public async Task Refresh_AddsNewVMsAndDropsDisposedOnes()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"), Sample.VM("OldBox"));
        _Runners.Dashboard.Returns(Sample.VM("DevBox"), Sample.VM("NewBox"));
        await _Main.RefreshAsync();

        await _Main.RefreshAsync();

        Assert.Equal(["DevBox", "NewBox"], _Main.VMs.Select(row => row.Name));
    }

    [Fact]
    public async Task OpenVM_ShowsTheSelectedVMsWindow()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];

        _Main.OpenVMCommand.Execute(null);

        Assert.Equal("DevBox", Assert.Single(ShownVMs).Name);
    }

    [Fact]
    public void OpenVM_WithNothingSelected_IsUnavailable()
    {
        Assert.False(_Main.OpenVMCommand.CanExecute(null));
    }

    [Fact]
    public async Task OpenVM_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];

        _Main.OpenVMCommand.Execute(null);
        _Main.OpenVMCommand.Execute(null);

        var window = Assert.Single(ShownVMs);
        Assert.Same(window, Assert.Single(_Tools.Windows.BroughtToFront));
    }

    [Fact]
    public async Task OpenVM_AfterItsWindowClosed_OpensANewWindow()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);
        _Tools.Windows.UserCloses(ShownVMs[0]);

        _Main.OpenVMCommand.Execute(null);

        Assert.Equal(2, ShownVMs.Count);
        Assert.Empty(_Tools.Windows.BroughtToFront);
    }

    [Fact]
    public async Task Start_WithNoVMs_ShowsTheChecks_WithTheNoteOnTheFirstVM()
    {
        _Runners.Dashboard.Returns();
        _Runners.Checks.ReturnsChecks(Sample.Check(), Sample.Check(VMCheck.INFO, "VMs", "none yet", "Create the first one with: New-LazyVM -Name <Name>"));

        await _Main.StartAsync();

        // Without -HostOnly, Test-LazyVM adds the note that there are no VMs yet.
        Assert.Equal([(null, false)], _Runners.Checks.CheckCalls);
        Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Windows.Shown));
    }

    [Fact]
    public async Task Start_WhenAHostCheckFails_ShowsTheChecks()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        _Runners.Checks.ReturnsChecks(Sample.Check(VMCheck.FAILED, "Folder access", "others can change it"));

        await _Main.StartAsync();

        Assert.Equal([(null, true)], _Runners.Checks.CheckCalls);
        Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Windows.Shown));
    }

    [Fact]
    public async Task Start_WithVMsAndNoFailedCheck_ShowsNoChecks()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        _Runners.Checks.ReturnsChecks(Sample.Check(VMCheck.OK), Sample.Check(VMCheck.INFO), Sample.Check(VMCheck.WARNING));

        await _Main.StartAsync();

        Assert.Empty(_Tools.Windows.Shown);
        Assert.Equal("Refreshed 1 VM at 14:52", _Main.Status);
    }

    [Fact]
    public async Task Start_WhenTheRefreshFails_ChecksTheHostOnly()
    {
        // A failed refresh says nothing about whether there are VMs.
        _Runners.Dashboard.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        _Runners.Checks.ReturnsChecks(Sample.Check(VMCheck.OK));

        await _Main.StartAsync();

        Assert.Equal([(null, true)], _Runners.Checks.CheckCalls);
        Assert.Empty(_Tools.Windows.Shown);
    }

    [Fact]
    public async Task Start_WhenTheChecksCannotRun_ShowsTheChecksSayingWhy()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        _Runners.Checks.ChecksThrow(new InvalidOperationException("Run LazyVM as administrator."));

        await _Main.StartAsync();

        var checks = Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Equal("Checks could not run: Run LazyVM as administrator.", checks.Status);
    }

    [Fact]
    public async Task HostChecks_WithVMs_ChecksTheHostOnly()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        _Runners.Checks.ReturnsChecks(Sample.Check());
        await _Main.RefreshAsync();

        _Main.HostChecksCommand.Execute(null);

        Assert.Equal([(null, true)], _Runners.Checks.CheckCalls);
        Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Windows.Shown));
    }

    [Fact]
    public async Task HostChecks_WithNoVMs_AlsoSaysThereAreNone()
    {
        _Runners.Dashboard.Returns();
        _Runners.Checks.ReturnsChecks(Sample.Check());
        await _Main.RefreshAsync();

        _Main.HostChecksCommand.Execute(null);

        Assert.Equal([(null, false)], _Runners.Checks.CheckCalls);
    }

    [Fact]
    public async Task HostChecks_AfterARefreshFailed_ChecksTheHostOnly()
    {
        // The empty list from before the failure no longer says there are no VMs.
        _Runners.Dashboard.Returns();
        _Runners.Dashboard.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        _Runners.Checks.ReturnsChecks(Sample.Check());
        await _Main.RefreshAsync();
        await _Main.RefreshAsync();

        _Main.HostChecksCommand.Execute(null);

        Assert.Equal([(null, true)], _Runners.Checks.CheckCalls);
    }

    [Fact]
    public async Task Refresh_UpdatesTheOpenVMWindows()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox", "Running"));
        _Runners.Dashboard.Returns(Sample.VM("DevBox", "Off"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);

        await _Main.RefreshAsync();

        Assert.Equal("Off", ShownVMs[0].State);
    }

    [Fact]
    public async Task Build_OpensTheBuildWindow_KnowingTheVMsThereAre()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();

        _Main.BuildCommand.Execute(null);
        var build = Assert.IsType<BuildViewModel>(Assert.Single(_Tools.Windows.Shown));
        await build.LoadAsync();
        build.Name = "devbox";
        await build.BuildAsync();

        Assert.Equal("There is a VM named devbox already. Choose another name.", build.Status);
    }

    [Fact]
    public async Task ABuildThatEnds_ReadsTheListAgain()
    {
        _Runners.Dashboard.ReturnsRun(null);
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));

        _Tools.OpenProgress(null, "DevBox", started: null);
        await Task.Yield();

        Assert.Equal(1, _Runners.Dashboard.DashboardCalls);
    }

    [Fact]
    public async Task AChangeThatSomethingElseReports_ReadsTheListAgain()
    {
        // A run started, a delete, a restore, an export or an approval: whatever changed it reports it, and the list is read again.
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));

        _Tools.Changes.Raise();
        await Task.Yield();

        Assert.Equal(1, _Runners.Dashboard.DashboardCalls);
    }

    [Fact]
    public async Task ADeletedVM_ClosesItsWindow()
    {
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);
        var window = Assert.Single(ShownVMs);
        _Runners.Removal.ReturnsRemovalPlan(new RemovalPlan { Name = "DevBox", HyperVState = "Off" });
        _Runners.Dashboard.Returns();
        _Tools.Dialogs.ConfirmsRemoval = true;

        await window.Deletion.DeleteAsync();

        Assert.Same(window, Assert.Single(_Tools.Windows.Closed));
        // Its window is gone, so opening the VM again makes a new one.
        _Runners.Dashboard.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);
        Assert.Equal(2, ShownVMs.Count);
    }
}
