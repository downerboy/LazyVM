using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class BuildProgressViewModelTests
{
    private const int _PROCESS = 4242;
    private readonly FakeCommandRunner _Runner = new();
    private readonly TaskCompletionSource<BuildResult> _Ending = new();
    private readonly FixedClock _Clock = new(DateTimeOffset.UnixEpoch);

    /// <summary>The phases Carry on was asked to start from.</summary>
    private readonly List<int> _CarriedOn = [];

    private BuildProgressViewModel Started()
    {
        return new(_Runner, "DevBox", new StartedBuild(_PROCESS, _Ending.Task), _Clock);
    }

    private BuildProgressViewModel Following()
    {
        return new(_Runner, "DevBox", started: null, _Clock);
    }

    private static VMRun Running(int? phase, int? process = _PROCESS, bool stopRequested = false)
    {
        return new()
        {
            Command = VMRun.BUILD,
            Status = VMRun.RUNNING,
            ProcessId = process,
            Phase = phase,
            StopRequested = stopRequested,
        };
    }

    private static VMRun Ended(string status, int? phase, int? process = _PROCESS)
    {
        return new()
        {
            Command = VMRun.BUILD,
            Status = status,
            ProcessId = process,
            Phase = phase,
            UnfinishedPhase = status is VMRun.STOPPED or VMRun.FAILED or VMRun.ENDED_UNEXPECTEDLY ? phase : null,
        };
    }

    private static async Task<BuildProgressViewModel> Loaded(BuildProgressViewModel progress)
    {
        await progress.LoadPhasesAsync(CancellationToken.None);
        return progress;
    }

    /// <summary>A started build whose window offers Carry on, recording the phase it starts from.</summary>
    private BuildProgressViewModel StartedWithCarryOn(Exception? fails = null)
    {
        return new(_Runner, "DevBox", new StartedBuild(_PROCESS, _Ending.Task), _Clock, phase =>
        {
            _CarriedOn.Add(phase);
            return fails is null ? Task.CompletedTask : Task.FromException(fails);
        });
    }

    [Theory]
    [InlineData(VMRun.FAILED)]
    [InlineData(VMRun.STOPPED)]
    [InlineData(VMRun.ENDED_UNEXPECTEDLY)]
    public async Task ABuildThatDidNotFinish_OffersToCarryOnFromItsPhase(string status)
    {
        var progress = await Loaded(StartedWithCarryOn());
        _Ending.SetResult(new BuildResult(BuildResult.FAILED, null, "It did not finish."));
        _Runner.ReturnsRun(Ended(status, 7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal(7, progress.CarryOnPhase);
        Assert.True(progress.CanCarryOn);
        Assert.Equal("Carry on from phase 7", progress.CarryOnText);
        Assert.Contains("Then choose Carry on from phase 7.", progress.Advice);
        Assert.DoesNotContain("PowerShell", progress.Advice);
        Assert.True(progress.CarryOnCommand.CanExecute(null));
    }

    [Theory]
    [InlineData(VMRun.COMPLETED)]
    [InlineData(VMRun.COMPLETED_WITH_PROBLEMS)]
    [InlineData(VMRun.WAITING_FOR_RESTART)]
    public async Task ABuildThatFinishedOrCarriesOnByItself_OffersNoCarryOn(string status)
    {
        var progress = await Loaded(StartedWithCarryOn());
        _Runner.ReturnsRun(Ended(status, 8));

        await progress.PollAsync(CancellationToken.None);

        Assert.Null(progress.CarryOnPhase);
        Assert.False(progress.CarryOnCommand.CanExecute(null));
    }

    [Fact]
    public async Task WhileTheBuildRuns_ThereIsNoCarryOn()
    {
        var progress = await Loaded(StartedWithCarryOn());
        _Runner.ReturnsRun(Running(7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Null(progress.CarryOnPhase);
        Assert.False(progress.CarryOnCommand.CanExecute(null));
    }

    [Fact]
    public async Task CarryOn_StartsTheBuildFromThePhaseItStoppedIn()
    {
        var progress = await Loaded(StartedWithCarryOn());
        _Runner.ReturnsRun(Ended(VMRun.STOPPED, 7));
        await progress.PollAsync(CancellationToken.None);

        await progress.CarryOnAsync();

        Assert.Equal([7], _CarriedOn);
        Assert.Equal("Starting the build of DevBox from phase 7", progress.Status);
    }

    [Fact]
    public async Task CarryOn_WhenTheBuildCannotStart_SaysWhy_AndCanBeTriedAgain()
    {
        var progress = await Loaded(StartedWithCarryOn(new InvalidOperationException("PowerShell 7.6 or later was not found.")));
        _Runner.ReturnsRun(Ended(VMRun.FAILED, 7));
        await progress.PollAsync(CancellationToken.None);

        await progress.CarryOnAsync();

        Assert.Equal("The build could not start: PowerShell 7.6 or later was not found.", progress.Status);
        Assert.True(progress.CarryOnCommand.CanExecute(null));
    }

    [Fact]
    public async Task ABuildThatDidNotStartAtAll_OffersNoCarryOn()
    {
        var progress = await Loaded(StartedWithCarryOn());
        _Ending.SetResult(new BuildResult(BuildResult.FAILED, null, "There is no Windows ISO."));
        _Runner.ReturnsRun(null);

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Null(progress.CarryOnPhase);
    }

    [Fact]
    public async Task Phases_ShowEachPhaseAsItsNumberAndGoal()
    {
        var progress = Started();

        await progress.LoadPhasesAsync(CancellationToken.None);

        Assert.Equal([0, 1, 7, 8], progress.Phases.Select(phase => phase.Number));
        Assert.Equal("Install Windows and the tools", progress.Phases[2].Goal);
        Assert.All(progress.Phases, phase => Assert.Equal(PhaseRowViewModel.NOT_STARTED, phase.State));
    }

    [Fact]
    public async Task Running_ShowsThePhaseByNumberAndGoal_AndMarksTheEarlierOnesDone()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Running(7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("Phase 7: Install Windows and the tools", progress.Status);
        Assert.Equal(
            [PhaseRowViewModel.DONE, PhaseRowViewModel.DONE, PhaseRowViewModel.IN_PROGRESS, PhaseRowViewModel.NOT_STARTED],
            progress.Phases.Select(phase => phase.State));
        Assert.Equal("Phase 7, Install Windows and the tools: In progress", progress.Phases[2].AutomationName);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public async Task BeforeTheBuildRecordsItself_ThePreviousRunIsNotShown()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Ended(VMRun.FAILED, 7, process: 1111));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("Starting the build of DevBox", progress.Status);
        Assert.False(progress.IsFinished);
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task WhenTheProcessEndsBeforeRecordingARun_SaysWhyTheBuildDidNotStart()
    {
        var progress = await Loaded(Started());
        var ended = 0;
        progress.Ended += (_, _) => ended++;
        _Ending.SetResult(new BuildResult(BuildResult.FAILED, null, "There is no Windows ISO."));
        _Runner.ReturnsRun(null);

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Equal("The build of DevBox did not start: There is no Windows ISO.", progress.Status);
        Assert.Equal(1, ended);
    }

    [Fact]
    public async Task Completed_SaysTheVMIsReady_AndMarksEveryPhaseDone()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Ended(VMRun.COMPLETED, 8));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Equal("The build of DevBox is complete. DevBox is ready.", progress.Status);
        Assert.All(progress.Phases, phase => Assert.Equal(PhaseRowViewModel.DONE, phase.State));
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task WhileTheBuildRuns_SaysClosingDoesNotStopIt_AndHowToComeBack()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Running(7));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.HasReturnText);
        Assert.Equal(
            "Closing this window does not stop the build. To see it again, select DevBox in the list and choose Build progress, or choose Build progress in the window of DevBox.",
            progress.ReturnText);
    }

    [Fact]
    public async Task OnceTheBuildHasEnded_SaysNothingAboutComingBack()
    {
        var progress = await Loaded(Started());
        var changed = new List<string?>();
        progress.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        _Runner.ReturnsRun(Ended(VMRun.COMPLETED, 8));

        await progress.PollAsync(CancellationToken.None);

        Assert.False(progress.HasReturnText);
        Assert.Null(progress.ReturnText);
        Assert.Contains(nameof(BuildProgressViewModel.ReturnText), changed);
        Assert.Contains(nameof(BuildProgressViewModel.HasReturnText), changed);
    }

    [Fact]
    public async Task Failed_SaysThePhaseAndTheReason_AndHowToCarryOn()
    {
        var progress = await Loaded(Started());
        _Ending.SetResult(new BuildResult(BuildResult.FAILED, null, "Visual Studio did not install."));
        _Runner.ReturnsRun(Ended(VMRun.FAILED, 7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The build of DevBox failed in phase 7: Visual Studio did not install.", progress.Status);
        Assert.Contains("Build-LazyVM -Name DevBox -FromPhase 7", progress.Advice);
        Assert.Equal(PhaseRowViewModel.FAILED, progress.Phases[2].State);
    }

    [Fact]
    public async Task Cancel_AsksTheBuildToStop_AndShowsItIsStopping()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Running(7));
        await progress.PollAsync(CancellationToken.None);
        _Runner.StopReturns(Running(7, stopRequested: true));

        Assert.True(progress.CancelCommand.CanExecute(null));
        progress.CancelCommand.Execute(null);
        await Task.Yield();

        Assert.Equal(["DevBox"], _Runner.StopCalls);
        Assert.True(progress.IsStopping);
        Assert.StartsWith("Stopping at the next safe point in phase 7.", progress.Status);
        Assert.Contains("An install already started inside the VM finishes by itself.", progress.Status);
        Assert.Equal(PhaseRowViewModel.STOPPING, progress.Phases[2].State);
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task StopRequested_ShowsStopping_EvenWhenAskedFromElsewhere()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Running(7, stopRequested: true));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsStopping);
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task Stopped_SaysToLetTheInstallFinish_ThenCarryOnFromThePhase()
    {
        var progress = await Loaded(Started());
        _Ending.SetResult(new BuildResult(BuildResult.STOPPED, "LazyVM.RunStopped", "The build of DevBox was stopped in phase 7, as asked."));
        _Runner.ReturnsRun(Ended(VMRun.STOPPED, 7));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.False(progress.IsStopping);
        Assert.Equal("The build of DevBox stopped in phase 7, as asked.", progress.Status);
        Assert.StartsWith("Let any install still running inside the VM finish first", progress.Advice);
        Assert.Contains("-FromPhase 7", progress.Advice);
        Assert.Equal(PhaseRowViewModel.STOPPED, progress.Phases[2].State);
    }

    [Fact]
    public async Task Cancel_WhenNothingWasStopped_SaysWhy()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Running(7));
        await progress.PollAsync(CancellationToken.None);
        _Runner.StopThrows(new InvalidOperationException("A run of DevBox is just starting and has not recorded itself yet, so nothing was stopped. Try again in a moment."));

        progress.CancelCommand.Execute(null);
        await Task.Yield();

        Assert.StartsWith("The build could not be stopped: A run of DevBox is just starting", progress.Status);
        Assert.False(progress.IsStopping);
        Assert.True(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task Cancel_IsOfferedOnlyForABuild_NotForMaintenance()
    {
        var progress = await Loaded(Following());
        _Runner.ReturnsRun(Running(null) with
        {
            Command = "Maintenance"
        });

        await progress.PollAsync(CancellationToken.None);

        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task AReadFailure_SaysSo_AndKeepsFollowing()
    {
        var progress = await Loaded(Started());
        _Runner.VMThrows(new InvalidOperationException("The LazyVM folder could not be read."));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The build's progress could not be read: The LazyVM folder could not be read. Trying again.", progress.Status);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public async Task Following_ABuildTheAppDidNotStart_ShowsItsPhase()
    {
        var progress = await Loaded(Following());
        _Runner.ReturnsRun(Running(7, process: 9999));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("Phase 7: Install Windows and the tools", progress.Status);
        Assert.True(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task Following_WhenNoBuildIsRunning_SaysSo()
    {
        var progress = await Loaded(Following());
        _Runner.ReturnsRun(Ended(VMRun.COMPLETED, 8, process: 9999));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Equal("No build of DevBox is running.", progress.Status);
    }

    [Fact]
    public async Task Following_ABuildThatEnds_SaysHowItEnded()
    {
        var progress = await Loaded(Following());
        _Runner.ReturnsRun(Running(7, process: 9999));
        await progress.PollAsync(CancellationToken.None);
        _Runner.ReturnsRun(Ended(VMRun.ENDED_UNEXPECTEDLY, 7, process: 9999));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The build of DevBox ended unexpectedly in phase 7: its process was closed, crashed or lost power.", progress.Status);
        Assert.Contains("-FromPhase 7", progress.Advice);
    }

    [Fact]
    public async Task WaitingForRestart_SaysTheBuildCarriesOnByItself()
    {
        var progress = await Loaded(Started());
        _Runner.ReturnsRun(Ended(VMRun.WAITING_FOR_RESTART, 2));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The host is restarting to finish turning on Hyper-V.", progress.Status);
        Assert.Equal("The build carries on by itself after the restart.", progress.Advice);
    }

    [Fact]
    public async Task FollowAsync_EndsWhenTheBuildHasEnded()
    {
        var progress = Started();
        _Ending.SetResult(new BuildResult(BuildResult.FAILED, null, "Another run of DevBox is going."));
        _Runner.ReturnsRun(null);

        await progress.FollowAsync().WaitAsync(TimeSpan.FromSeconds(10));

        Assert.True(progress.IsFinished);
        Assert.Equal(["DevBox"], _Runner.VMCalls);
    }

    [Fact]
    public async Task FollowAsync_WhenTheProcessHasEndedAndTheReadFails_WaitsBeforeReadingAgain()
    {
        var progress = Started();
        _Ending.SetResult(new BuildResult(BuildResult.COMPLETED, null, null));
        for (var i = 0; i < 100; i++)
        {
            _Runner.VMThrows(new InvalidOperationException("The LazyVM folder could not be read."));
        }
        var following = progress.FollowAsync();

        await Task.Delay(500);
        progress.StopFollowing();
        await following.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Single(_Runner.VMCalls);
    }

    [Fact]
    public async Task StopFollowing_EndsTheFollowing_WithoutStoppingTheBuild()
    {
        var progress = Started();
        _Runner.ReturnsRun(Running(7));
        var following = progress.FollowAsync();

        progress.StopFollowing();
        await following.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.False(progress.IsFinished);
        Assert.Empty(_Runner.StopCalls);
    }
}
