using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>
/// The one way a window shows it is working (#499): while a command it ran
/// has not answered, <see cref="ViewModelBase.IsWorking"/> is true and
/// <see cref="ViewModelBase.WorkingText"/> says what it is doing.
/// </summary>
public sealed class WorkingTests
{
    private sealed class Working : ViewModelBase
    {
        public Task<T> Run<T>(string text, Func<Task<T>> work)
        {
            return WorkAsync(text, work);
        }

        public Task Run(string text, Func<Task> work)
        {
            return WorkAsync(text, work);
        }

        public void Holds(ViewModelBase part)
        {
            Include(part);
        }
    }

    private readonly Working _Working = new();

    [Fact]
    public async Task WhileAPartItHoldsRunsACommand_SaysWhatThePartIsDoing()
    {
        var part = new Working();
        _Working.Holds(part);
        var watcher = new WorkWatcher(_Working);
        var answer = new TaskCompletionSource<int>();

        var running = part.Run("Deleting DevBox", () => answer.Task);

        Assert.True(_Working.IsWorking);
        Assert.Equal("Deleting DevBox", _Working.WorkingText);
        answer.SetResult(7);
        await running;
        Assert.False(_Working.IsWorking);
        Assert.Equal(["Deleting DevBox", null], watcher.Seen);
    }

    [Fact]
    public async Task ItsOwnCommand_IsSaidBeforeThatOfAPart()
    {
        var part = new Working();
        _Working.Holds(part);
        var own = new TaskCompletionSource<int>();
        var parts = new TaskCompletionSource<int>();

        var reading = part.Run("Reading the build phases", () => parts.Task);
        var opening = _Working.Run("Opening the guide", () => own.Task);

        Assert.Equal("Opening the guide", _Working.WorkingText);
        own.SetResult(1);
        await opening;
        Assert.Equal("Reading the build phases", _Working.WorkingText);
        parts.SetResult(2);
        await reading;
    }

    [Fact]
    public async Task WhileTheCommandRuns_SaysWhatItIsDoing()
    {
        var answer = new TaskCompletionSource<int>();
        var changed = new List<string?>();
        _Working.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        var running = _Working.Run("Reading the log", () => answer.Task);

        Assert.True(_Working.IsWorking);
        Assert.Equal("Reading the log", _Working.WorkingText);
        Assert.Contains(nameof(ViewModelBase.IsWorking), changed);
        Assert.Contains(nameof(ViewModelBase.WorkingText), changed);
        answer.SetResult(7);
        Assert.Equal(7, await running);
    }

    [Fact]
    public async Task OnceTheCommandHasAnswered_IsNoLongerWorking()
    {
        await _Working.Run("Reading the log", () => Task.FromResult(7));

        Assert.False(_Working.IsWorking);
        Assert.Null(_Working.WorkingText);
    }

    [Fact]
    public async Task WhenTheCommandFails_IsNoLongerWorking_AndTheFailureGoesOn()
    {
        var failure = await Assert.ThrowsAsync<InvalidOperationException>(
            () => _Working.Run("Reading the log", () => Task.FromException(new InvalidOperationException("Access is denied."))));

        Assert.Equal("Access is denied.", failure.Message);
        Assert.False(_Working.IsWorking);
    }

    [Fact]
    public async Task WhenTheCommandIsCancelled_IsNoLongerWorking()
    {
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => _Working.Run("Running the checks", () => Task.FromCanceled(new CancellationToken(canceled: true))));

        Assert.False(_Working.IsWorking);
    }

    [Fact]
    public async Task TwoCommandsAtOnce_StayWorkingUntilBothHaveAnswered_SayingWhatIsStillGoing()
    {
        var first = new TaskCompletionSource<int>();
        var second = new TaskCompletionSource<int>();
        var reading = _Working.Run("Reading the restore points", () => first.Task);
        var restoring = _Working.Run("Restoring DevBox", () => second.Task);
        Assert.Equal("Restoring DevBox", _Working.WorkingText);

        second.SetResult(1);
        await restoring;

        Assert.True(_Working.IsWorking);
        Assert.Equal("Reading the restore points", _Working.WorkingText);
        first.SetResult(2);
        await reading;
        Assert.False(_Working.IsWorking);
    }
}
