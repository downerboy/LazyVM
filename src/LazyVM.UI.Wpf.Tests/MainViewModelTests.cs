using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class MainViewModelTests : IDisposable
{
    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeToolWindows _Tools;
    private readonly FakeVMWindowManager _Windows;
    private readonly MainViewModel _Main;

    public MainViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runner);
        _Windows = new FakeVMWindowManager(_Tools);
        _Main = new MainViewModel(_Runner, _Windows, _Tools, new FixedClock(new DateTimeOffset(2026, 11, 14, 14, 52, 0, TimeSpan.Zero)));
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private static VMRun RunningNow(string command)
    {
        return new VMRun { Command = command, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 };
    }

    [Fact]
    public async Task BuildProgress_IsOfferedForTheSelectedVM_OnlyWhileItBuilds()
    {
        _Runner.Returns(
            Sample.VM("Idle"),
            Sample.VM("Building") with { Run = RunningNow(VMRun.BUILD) },
            Sample.VM("Maintaining") with { Run = RunningNow("Maintenance") });
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
        _Runner.Returns(Sample.VM("DevEnv") with { Run = RunningNow(VMRun.BUILD) });
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs.Single();

        _Main.BuildProgressCommand.Execute(null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        progress.StopFollowing();
    }

    [Fact]
    public async Task BuildProgress_FollowsARefresh_WhenTheSelectedVMStartsOrStopsBuilding()
    {
        _Runner.Returns(Sample.VM("DevEnv"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs.Single();
        var changed = new List<string?>();
        _Main.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        var asked = 0;
        _Main.BuildProgressCommand.CanExecuteChanged += (_, _) => asked++;

        _Runner.Returns(Sample.VM("DevEnv") with { Run = RunningNow(VMRun.BUILD) });
        await _Main.RefreshAsync();

        Assert.True(_Main.SelectedVMIsBuilding);
        Assert.Contains(nameof(MainViewModel.SelectedVMIsBuilding), changed);
        Assert.True(asked > 0);
    }

    [Fact]
    public async Task Refresh_ShowsOneRowPerVM()
    {
        _Runner.Returns(Sample.VM("DevBox"), Sample.VM("PlainWin"), Sample.VM("TestBox"));

        await _Main.RefreshAsync();

        Assert.Equal(["DevBox", "PlainWin", "TestBox"], _Main.VMs.Select(row => row.Name));
    }

    [Fact]
    public async Task Refresh_SaysWhatItDidInTheStatusLine()
    {
        _Runner.Returns(Sample.VM("DevBox"), Sample.VM("PlainWin"), Sample.VM("TestBox"));

        await _Main.RefreshAsync();

        Assert.Equal("Refreshed 3 VMs at 14:52", _Main.Status);
    }

    [Fact]
    public async Task Refresh_OfOneVM_SaysVMNotVMs()
    {
        _Runner.Returns(Sample.VM());

        await _Main.RefreshAsync();

        Assert.Equal("Refreshed 1 VM at 14:52", _Main.Status);
    }

    [Fact]
    public async Task Refresh_WhenTheCommandFails_KeepsTheListAndSaysWhy()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        await _Main.RefreshAsync();

        await _Main.RefreshAsync();

        Assert.Equal(["DevBox"], _Main.VMs.Select(row => row.Name));
        Assert.Equal("Refresh failed: The LazyVM folder was not found.", _Main.Status);
    }

    [Fact]
    public async Task CancelRefresh_StopsTheCallAndKeepsTheList()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.WaitsForCancel();
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
        _Runner.WaitsForCancel();

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
        _Runner.Returns(Sample.VM("DevBox"), Sample.VM("TestBox"));
        _Runner.Returns(Sample.VM("DevBox", "Off"), Sample.VM("TestBox", "Off"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[1];

        await _Main.RefreshAsync();

        Assert.Equal("TestBox", _Main.SelectedVM?.Name);
        Assert.Equal("Off", _Main.SelectedVM?.State);
    }

    [Fact]
    public async Task Refresh_AddsNewVMsAndDropsDisposedOnes()
    {
        _Runner.Returns(Sample.VM("DevBox"), Sample.VM("OldBox"));
        _Runner.Returns(Sample.VM("DevBox"), Sample.VM("NewBox"));
        await _Main.RefreshAsync();

        await _Main.RefreshAsync();

        Assert.Equal(["DevBox", "NewBox"], _Main.VMs.Select(row => row.Name));
    }

    [Fact]
    public async Task OpenVM_ShowsTheSelectedVMsWindow()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];

        _Main.OpenVMCommand.Execute(null);

        Assert.Equal("DevBox", Assert.Single(_Windows.Shown).Name);
    }

    [Fact]
    public void OpenVM_WithNothingSelected_IsUnavailable()
    {
        Assert.False(_Main.OpenVMCommand.CanExecute(null));
    }

    [Fact]
    public async Task OpenVM_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];

        _Main.OpenVMCommand.Execute(null);
        _Main.OpenVMCommand.Execute(null);

        var window = Assert.Single(_Windows.Shown);
        Assert.Same(window, Assert.Single(_Windows.BroughtToFront));
    }

    [Fact]
    public async Task OpenVM_AfterItsWindowClosed_OpensANewWindow()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);
        _Windows.Close(_Windows.Shown[0]);

        _Main.OpenVMCommand.Execute(null);

        Assert.Equal(2, _Windows.Shown.Count);
        Assert.Empty(_Windows.BroughtToFront);
    }

    [Fact]
    public async Task Start_WithNoVMs_ShowsTheChecks_WithTheNoteOnTheFirstVM()
    {
        _Runner.Returns();
        _Runner.ReturnsChecks(Sample.Check(), Sample.Check(VMCheck.INFO, "VMs", "none yet", "Create the first one with: New-LazyVM -Name <Name>"));

        await _Main.StartAsync();

        // Without -HostOnly, Test-LazyVM adds the note that there are no VMs yet.
        Assert.Equal([(null, false)], _Runner.CheckCalls);
        Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Shown));
    }

    [Fact]
    public async Task Start_WhenAHostCheckFails_ShowsTheChecks()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.ReturnsChecks(Sample.Check(VMCheck.FAILED, "Folder access", "others can change it"));

        await _Main.StartAsync();

        Assert.Equal([(null, true)], _Runner.CheckCalls);
        Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Shown));
    }

    [Fact]
    public async Task Start_WithVMsAndNoFailedCheck_ShowsNoChecks()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.ReturnsChecks(Sample.Check(VMCheck.OK), Sample.Check(VMCheck.INFO), Sample.Check(VMCheck.WARNING));

        await _Main.StartAsync();

        Assert.Empty(_Tools.Shown);
        Assert.Equal("Refreshed 1 VM at 14:52", _Main.Status);
    }

    [Fact]
    public async Task Start_WhenTheRefreshFails_ChecksTheHostOnly()
    {
        // A failed refresh says nothing about whether there are VMs.
        _Runner.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        _Runner.ReturnsChecks(Sample.Check(VMCheck.OK));

        await _Main.StartAsync();

        Assert.Equal([(null, true)], _Runner.CheckCalls);
        Assert.Empty(_Tools.Shown);
    }

    [Fact]
    public async Task Start_WhenTheChecksCannotRun_ShowsTheChecksSayingWhy()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.ChecksThrow(new InvalidOperationException("Run LazyVM as administrator."));

        await _Main.StartAsync();

        var checks = Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("Checks could not run: Run LazyVM as administrator.", checks.Status);
    }

    [Fact]
    public async Task HostChecks_WithVMs_ChecksTheHostOnly()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.ReturnsChecks(Sample.Check());
        await _Main.RefreshAsync();

        _Main.HostChecksCommand.Execute(null);

        Assert.Equal([(null, true)], _Runner.CheckCalls);
        Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Shown));
    }

    [Fact]
    public async Task HostChecks_WithNoVMs_AlsoSaysThereAreNone()
    {
        _Runner.Returns();
        _Runner.ReturnsChecks(Sample.Check());
        await _Main.RefreshAsync();

        _Main.HostChecksCommand.Execute(null);

        Assert.Equal([(null, false)], _Runner.CheckCalls);
    }

    [Fact]
    public async Task HostChecks_AfterARefreshFailed_ChecksTheHostOnly()
    {
        // The empty list from before the failure no longer says there are no VMs.
        _Runner.Returns();
        _Runner.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        _Runner.ReturnsChecks(Sample.Check());
        await _Main.RefreshAsync();
        await _Main.RefreshAsync();

        _Main.HostChecksCommand.Execute(null);

        Assert.Equal([(null, true)], _Runner.CheckCalls);
    }

    [Fact]
    public async Task Refresh_UpdatesTheOpenVMWindows()
    {
        _Runner.Returns(Sample.VM("DevBox", "Running"));
        _Runner.Returns(Sample.VM("DevBox", "Off"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);

        await _Main.RefreshAsync();

        Assert.Equal("Off", _Windows.Shown[0].State);
    }

    [Fact]
    public async Task Build_OpensTheBuildWindow_KnowingTheVMsThereAre()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();

        _Main.BuildCommand.Execute(null);
        var build = Assert.IsType<BuildViewModel>(Assert.Single(_Tools.Shown));
        await build.LoadAsync();
        build.Name = "devbox";
        await build.BuildAsync();

        Assert.Equal("There is a VM named devbox already. Choose another name.", build.Status);
    }

    [Fact]
    public async Task ABuildThatEnds_ReadsTheListAgain()
    {
        _Runner.ReturnsRun(null);
        _Runner.Returns(Sample.VM("DevBox"));

        _Tools.OpenProgress("DevBox", started: null);
        await Task.Yield();

        Assert.Equal(1, _Runner.DashboardCalls);
    }

    [Fact]
    public async Task MaintenanceStartedFromAVMWindow_ReadsTheListAgain()
    {
        _Runner.Returns(Sample.VM("DevBox"));

        await _Tools.StartMaintenanceAsync("DevBox");
        await Task.Yield();

        Assert.Equal(1, _Runner.DashboardCalls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ADelete_EvenOneThatOnlyPartlyRemoved_ReadsTheListAgain(bool fails)
    {
        _Runner.Returns(Sample.VM("PlainWin"));
        _Runner.RemoveFails = fails ? new InvalidOperationException("'DevBox' was only partly removed.") : null;

        await Record.ExceptionAsync(() => _Tools.RemoveVMAsync("DevBox"));
        await Task.Yield();

        Assert.Equal(1, _Runner.DashboardCalls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ARestore_EvenOneThatFailed_ReadsTheListAgain(bool fails)
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.RestoreFails = fails ? new InvalidOperationException("The revert failed.") : null;

        await Record.ExceptionAsync(() => _Tools.RestoreToolingAsync("DevBox", "20261008-193000"));
        await Task.Yield();

        Assert.Equal(1, _Runner.DashboardCalls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AnExport_EvenOneThatFailed_ReadsTheListAgain(bool fails)
    {
        _Runner.Returns(Sample.VM("DevBox"));
        _Runner.ExportFails = fails ? new InvalidOperationException("The folder is not there.") : null;

        await Record.ExceptionAsync(() => _Tools.ExportRecoveryKeysAsync("DevBox", @"E:\keys.txt", force: false));
        await Task.Yield();

        Assert.Equal(1, _Runner.DashboardCalls);
    }

    [Fact]
    public async Task ADeletedVM_ClosesItsWindow()
    {
        _Runner.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);
        var window = Assert.Single(_Windows.Shown);
        _Runner.ReturnsRemovalPlan(new RemovalPlan { Name = "DevBox", HyperVState = "Off" });
        _Runner.Returns();
        _Tools.ConfirmsRemoval = true;

        await window.DeleteAsync();

        Assert.Same(window, Assert.Single(_Windows.Closed));
        // Its window is gone, so opening the VM again makes a new one.
        _Runner.Returns(Sample.VM("DevBox"));
        await _Main.RefreshAsync();
        _Main.SelectedVM = _Main.VMs[0];
        _Main.OpenVMCommand.Execute(null);
        Assert.Equal(2, _Windows.Shown.Count);
    }
}
