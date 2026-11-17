using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class BuildProgressViewModelTests
{
    private const int Process = 4242;
    private readonly FakeCommandRunner runner = new();
    private readonly TaskCompletionSource<BuildResult> ending = new();
    private readonly FixedClock clock = new(DateTimeOffset.UnixEpoch);

    /// <summary>The phases Carry on was asked to start from.</summary>
    private readonly List<int> carriedOn = [];

    private BuildProgressViewModel Started() => new(runner, "DevBox", new StartedBuild(Process, ending.Task), clock);

    private BuildProgressViewModel Following() => new(runner, "DevBox", started: null, clock);

    private static VMRun Running(int? phase, int? process = Process, bool stopRequested = false) => new()
    {
        Command = VMRun.Build,
        Status = VMRun.Running,
        ProcessId = process,
        Phase = phase,
        StopRequested = stopRequested,
    };

    private static VMRun Ended(string status, int? phase, int? process = Process) => new()
    {
        Command = VMRun.Build,
        Status = status,
        ProcessId = process,
        Phase = phase,
        UnfinishedPhase = status is VMRun.Stopped or VMRun.Failed or VMRun.EndedUnexpectedly ? phase : null,
    };

    private static async Task<BuildProgressViewModel> Loaded(BuildProgressViewModel progress)
    {
        await progress.LoadPhasesAsync(CancellationToken.None);
        return progress;
    }

    /// <summary>A started build whose window offers Carry on, recording the phase it starts from.</summary>
    private BuildProgressViewModel StartedWithCarryOn(Exception? fails = null) =>
        new(runner, "DevBox", new StartedBuild(Process, ending.Task), clock, phase =>
        {
            carriedOn.Add(phase);
            return fails is null ? Task.CompletedTask : Task.FromException(fails);
        });

    [Theory]
    [InlineData(VMRun.Failed)]
    [InlineData(VMRun.Stopped)]
    [InlineData(VMRun.EndedUnexpectedly)]
    public async Task ABuildThatDidNotFinish_OffersToCarryOnFromItsPhase(string status)
    {
        var progress = await Loaded(StartedWithCarryOn());
        ending.SetResult(new BuildResult(BuildResult.Failed, null, "It did not finish."));
        runner.ReturnsRun(Ended(status, 7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal(7, progress.CarryOnPhase);
        Assert.True(progress.CanCarryOn);
        Assert.Equal("Carry on from phase 7", progress.CarryOnText);
        Assert.Contains("Then choose Carry on from phase 7.", progress.Advice);
        Assert.DoesNotContain("PowerShell", progress.Advice);
        Assert.True(progress.CarryOnCommand.CanExecute(null));
    }

    [Theory]
    [InlineData(VMRun.Completed)]
    [InlineData(VMRun.CompletedWithProblems)]
    [InlineData(VMRun.WaitingForRestart)]
    public async Task ABuildThatFinishedOrCarriesOnByItself_OffersNoCarryOn(string status)
    {
        var progress = await Loaded(StartedWithCarryOn());
        runner.ReturnsRun(Ended(status, 8));

        await progress.PollAsync(CancellationToken.None);

        Assert.Null(progress.CarryOnPhase);
        Assert.False(progress.CarryOnCommand.CanExecute(null));
    }

    [Fact]
    public async Task WhileTheBuildRuns_ThereIsNoCarryOn()
    {
        var progress = await Loaded(StartedWithCarryOn());
        runner.ReturnsRun(Running(7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Null(progress.CarryOnPhase);
        Assert.False(progress.CarryOnCommand.CanExecute(null));
    }

    [Fact]
    public async Task CarryOn_StartsTheBuildFromThePhaseItStoppedIn()
    {
        var progress = await Loaded(StartedWithCarryOn());
        runner.ReturnsRun(Ended(VMRun.Stopped, 7));
        await progress.PollAsync(CancellationToken.None);

        await progress.CarryOnAsync();

        Assert.Equal([7], carriedOn);
        Assert.Equal("Starting the build of DevBox from phase 7", progress.Status);
    }

    [Fact]
    public async Task CarryOn_WhenTheBuildCannotStart_SaysWhy_AndCanBeTriedAgain()
    {
        var progress = await Loaded(StartedWithCarryOn(new InvalidOperationException("PowerShell 7.6 or later was not found.")));
        runner.ReturnsRun(Ended(VMRun.Failed, 7));
        await progress.PollAsync(CancellationToken.None);

        await progress.CarryOnAsync();

        Assert.Equal("The build could not start: PowerShell 7.6 or later was not found.", progress.Status);
        Assert.True(progress.CarryOnCommand.CanExecute(null));
    }

    [Fact]
    public async Task ABuildThatDidNotStartAtAll_OffersNoCarryOn()
    {
        var progress = await Loaded(StartedWithCarryOn());
        ending.SetResult(new BuildResult(BuildResult.Failed, null, "There is no Windows ISO."));
        runner.ReturnsRun(null);

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
        Assert.All(progress.Phases, phase => Assert.Equal(PhaseRowViewModel.NotStarted, phase.State));
    }

    [Fact]
    public async Task Running_ShowsThePhaseByNumberAndGoal_AndMarksTheEarlierOnesDone()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Running(7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("Phase 7: Install Windows and the tools", progress.Status);
        Assert.Equal(
            [PhaseRowViewModel.Done, PhaseRowViewModel.Done, PhaseRowViewModel.InProgress, PhaseRowViewModel.NotStarted],
            progress.Phases.Select(phase => phase.State));
        Assert.Equal("Phase 7, Install Windows and the tools: In progress", progress.Phases[2].AutomationName);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public async Task BeforeTheBuildRecordsItself_ThePreviousRunIsNotShown()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Ended(VMRun.Failed, 7, process: 1111));

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
        ending.SetResult(new BuildResult(BuildResult.Failed, null, "There is no Windows ISO."));
        runner.ReturnsRun(null);

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Equal("The build of DevBox did not start: There is no Windows ISO.", progress.Status);
        Assert.Equal(1, ended);
    }

    [Fact]
    public async Task Completed_SaysTheVMIsReady_AndMarksEveryPhaseDone()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Ended(VMRun.Completed, 8));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Equal("The build of DevBox is complete. DevBox is ready.", progress.Status);
        Assert.All(progress.Phases, phase => Assert.Equal(PhaseRowViewModel.Done, phase.State));
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task Failed_SaysThePhaseAndTheReason_AndHowToCarryOn()
    {
        var progress = await Loaded(Started());
        ending.SetResult(new BuildResult(BuildResult.Failed, null, "Visual Studio did not install."));
        runner.ReturnsRun(Ended(VMRun.Failed, 7));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The build of DevBox failed in phase 7: Visual Studio did not install.", progress.Status);
        Assert.Contains("Build-LazyVM -Name DevBox -FromPhase 7", progress.Advice);
        Assert.Equal(PhaseRowViewModel.Failed, progress.Phases[2].State);
    }

    [Fact]
    public async Task Cancel_AsksTheBuildToStop_AndShowsItIsStopping()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Running(7));
        await progress.PollAsync(CancellationToken.None);
        runner.StopReturns(Running(7, stopRequested: true));

        Assert.True(progress.CancelCommand.CanExecute(null));
        progress.CancelCommand.Execute(null);
        await Task.Yield();

        Assert.Equal(["DevBox"], runner.StopCalls);
        Assert.True(progress.IsStopping);
        Assert.StartsWith("Stopping at the next safe point in phase 7.", progress.Status);
        Assert.Contains("An install already started inside the VM finishes by itself.", progress.Status);
        Assert.Equal(PhaseRowViewModel.Stopping, progress.Phases[2].State);
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task StopRequested_ShowsStopping_EvenWhenAskedFromElsewhere()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Running(7, stopRequested: true));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsStopping);
        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task Stopped_SaysToLetTheInstallFinish_ThenCarryOnFromThePhase()
    {
        var progress = await Loaded(Started());
        ending.SetResult(new BuildResult(BuildResult.Stopped, "LazyVM.RunStopped", "The build of DevBox was stopped in phase 7, as asked."));
        runner.ReturnsRun(Ended(VMRun.Stopped, 7));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.False(progress.IsStopping);
        Assert.Equal("The build of DevBox stopped in phase 7, as asked.", progress.Status);
        Assert.StartsWith("Let any install still running inside the VM finish first", progress.Advice);
        Assert.Contains("-FromPhase 7", progress.Advice);
        Assert.Equal(PhaseRowViewModel.Stopped, progress.Phases[2].State);
    }

    [Fact]
    public async Task Cancel_WhenNothingWasStopped_SaysWhy()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Running(7));
        await progress.PollAsync(CancellationToken.None);
        runner.StopThrows(new InvalidOperationException("A run of DevBox is just starting and has not recorded itself yet, so nothing was stopped. Try again in a moment."));

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
        runner.ReturnsRun(Running(null) with { Command = "Maintenance" });

        await progress.PollAsync(CancellationToken.None);

        Assert.False(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task AReadFailure_SaysSo_AndKeepsFollowing()
    {
        var progress = await Loaded(Started());
        runner.VMThrows(new InvalidOperationException("The LazyVM folder could not be read."));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The build's progress could not be read: The LazyVM folder could not be read. Trying again.", progress.Status);
        Assert.False(progress.IsFinished);
    }

    [Fact]
    public async Task Following_ABuildTheAppDidNotStart_ShowsItsPhase()
    {
        var progress = await Loaded(Following());
        runner.ReturnsRun(Running(7, process: 9999));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("Phase 7: Install Windows and the tools", progress.Status);
        Assert.True(progress.CancelCommand.CanExecute(null));
    }

    [Fact]
    public async Task Following_WhenNoBuildIsRunning_SaysSo()
    {
        var progress = await Loaded(Following());
        runner.ReturnsRun(Ended(VMRun.Completed, 8, process: 9999));

        await progress.PollAsync(CancellationToken.None);

        Assert.True(progress.IsFinished);
        Assert.Equal("No build of DevBox is running.", progress.Status);
    }

    [Fact]
    public async Task Following_ABuildThatEnds_SaysHowItEnded()
    {
        var progress = await Loaded(Following());
        runner.ReturnsRun(Running(7, process: 9999));
        await progress.PollAsync(CancellationToken.None);
        runner.ReturnsRun(Ended(VMRun.EndedUnexpectedly, 7, process: 9999));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The build of DevBox ended unexpectedly in phase 7: its process was closed, crashed or lost power.", progress.Status);
        Assert.Contains("-FromPhase 7", progress.Advice);
    }

    [Fact]
    public async Task WaitingForRestart_SaysTheBuildCarriesOnByItself()
    {
        var progress = await Loaded(Started());
        runner.ReturnsRun(Ended(VMRun.WaitingForRestart, 2));

        await progress.PollAsync(CancellationToken.None);

        Assert.Equal("The host is restarting to finish turning on Hyper-V.", progress.Status);
        Assert.Equal("The build carries on by itself after the restart.", progress.Advice);
    }

    [Fact]
    public async Task FollowAsync_EndsWhenTheBuildHasEnded()
    {
        var progress = Started();
        ending.SetResult(new BuildResult(BuildResult.Failed, null, "Another run of DevBox is going."));
        runner.ReturnsRun(null);

        await progress.FollowAsync().WaitAsync(TimeSpan.FromSeconds(10));

        Assert.True(progress.IsFinished);
        Assert.Equal(["DevBox"], runner.VMCalls);
    }

    [Fact]
    public async Task FollowAsync_WhenTheProcessHasEndedAndTheReadFails_WaitsBeforeReadingAgain()
    {
        var progress = Started();
        ending.SetResult(new BuildResult(BuildResult.Completed, null, null));
        for (var i = 0; i < 100; i++)
        {
            runner.VMThrows(new InvalidOperationException("The LazyVM folder could not be read."));
        }
        var following = progress.FollowAsync();

        await Task.Delay(500);
        progress.StopFollowing();
        await following.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Single(runner.VMCalls);
    }

    [Fact]
    public async Task StopFollowing_EndsTheFollowing_WithoutStoppingTheBuild()
    {
        var progress = Started();
        runner.ReturnsRun(Running(7));
        var following = progress.FollowAsync();

        progress.StopFollowing();
        await following.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.False(progress.IsFinished);
        Assert.Empty(runner.StopCalls);
    }
}
