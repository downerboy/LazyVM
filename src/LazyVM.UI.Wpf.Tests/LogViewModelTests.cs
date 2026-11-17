using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class LogViewModelTests : IDisposable
{
    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeCommandRunner _Runner = new();
    private readonly LogViewModel _Log;

    public LogViewModelTests()
    {
        _Log = new LogViewModel(_Runner, "DevBox");
    }

    public void Dispose() => _Culture.Dispose();

    [Fact]
    public void Title_NamesTheVM()
    {
        Assert.Equal("DevBox log - LazyVM", _Log.Title);
        Assert.Equal("Log of DevBox", _Log.Heading);
    }

    [Fact]
    public async Task Load_AsksForTheVMsLastEntriesOnly()
    {
        _Runner.ReturnsLog();

        await _Log.LoadAsync();

        Assert.Equal([("DevBox", LogViewModel.Tail)], _Runner.LogCalls);
    }

    [Fact]
    public async Task Load_ShowsTheEntriesOldestFirst_AndSelectsTheNewest()
    {
        _Runner.ReturnsLog(Sample.Log("Phase", "Build", 1), Sample.Log("Info", "Copying the ISO", 2), Sample.Log("OK", "Done", 3));

        await _Log.LoadAsync();

        Assert.Equal(["Build", "Copying the ISO", "Done"], _Log.Entries.Select(entry => entry.Message));
        Assert.Same(_Log.Entries[^1], _Log.SelectedEntry);
    }

    [Fact]
    public async Task Load_SaysHowManyEntriesWarningsAndErrors()
    {
        _Runner.ReturnsLog(
            Sample.Log("Info", "a"), Sample.Log("Error", "b"), Sample.Log("Warning", "c"),
            Sample.Log("Warning", "d"), Sample.Log("Error", "e"), Sample.Log("Error", "f"));

        await _Log.LoadAsync();

        Assert.Equal("6 entries: 3 errors, 2 warnings", _Log.Status);
    }

    [Fact]
    public async Task Load_OfAQuietLog_SaysThereAreNoWarningsOrErrors()
    {
        _Runner.ReturnsLog(Sample.Log("Info", "a"));

        await _Log.LoadAsync();

        Assert.Equal("1 entry: no warnings or errors", _Log.Status);
    }

    [Fact]
    public async Task Load_BeforeThereIsALog_SaysSo()
    {
        _Runner.ReturnsLog();

        await _Log.LoadAsync();

        Assert.Empty(_Log.Entries);
        Assert.Null(_Log.SelectedEntry);
        Assert.Equal("No log entries yet", _Log.Status);
    }

    [Fact]
    public async Task Load_OfAFullTail_SaysOnlyTheLastAreShown()
    {
        _Runner.ReturnsLog([.. Enumerable.Range(0, LogViewModel.Tail).Select(_ => Sample.Log("Info", "a"))]);

        await _Log.LoadAsync();

        Assert.Equal($"The last {LogViewModel.Tail} entries: no warnings or errors", _Log.Status);
    }

    [Fact]
    public async Task Load_WhenTheLogCannotBeRead_SaysWhy()
    {
        _Runner.LogThrows(new InvalidOperationException("Access to the path is denied."));

        await _Log.LoadAsync();

        Assert.Equal("The log could not be read: Access to the path is denied.", _Log.Status);
    }

    [Fact]
    public async Task Entry_IsReadAsLevelTimeAndMessage()
    {
        _Runner.ReturnsLog(Sample.Log("Error", "Windows Update failed", 10));

        await _Log.LoadAsync();

        var entry = Assert.Single(_Log.Entries);
        Assert.Equal("12 November 2026 02:10:05", entry.TimeText);
        Assert.Equal("Error, 12 November 2026 02:10:05, Windows Update failed", entry.AutomationName);
        Assert.True(entry.IsProblem);
    }

    [Fact]
    public async Task PreviousProblem_FromTheNewest_JumpsToTheLastWarningOrError()
    {
        _Runner.ReturnsLog(Sample.Log("Error", "a"), Sample.Log("Info", "b"), Sample.Log("Warning", "c"), Sample.Log("Info", "d"));
        await _Log.LoadAsync();
        LogEntryRowViewModel? jumpedTo = null;
        _Log.JumpedTo += entry => jumpedTo = entry;

        _Log.PreviousProblemCommand.Execute(null);

        Assert.Equal("c", _Log.SelectedEntry?.Message);
        Assert.Same(_Log.SelectedEntry, jumpedTo);
    }

    [Fact]
    public async Task NextProblem_SkipsEntriesThatAreNotWarningsOrErrors()
    {
        _Runner.ReturnsLog(Sample.Log("Info", "a"), Sample.Log("OK", "b"), Sample.Log("Phase", "c"), Sample.Log("Error", "d"), Sample.Log("Info", "e"));
        await _Log.LoadAsync();
        _Log.SelectedEntry = _Log.Entries[0];

        _Log.NextProblemCommand.Execute(null);

        Assert.Equal("d", _Log.SelectedEntry?.Message);
    }

    [Fact]
    public async Task NextProblem_WithNoneLeft_StaysAndSaysSo()
    {
        _Runner.ReturnsLog(Sample.Log("Error", "a"), Sample.Log("Info", "b"));
        await _Log.LoadAsync();

        _Log.NextProblemCommand.Execute(null);

        Assert.Equal("b", _Log.SelectedEntry?.Message);
        Assert.Equal("No warnings or errors after this entry", _Log.Status);
    }

    [Fact]
    public async Task PreviousProblem_WithNoneBefore_StaysAndSaysSo()
    {
        _Runner.ReturnsLog(Sample.Log("Info", "a"), Sample.Log("Error", "b"));
        await _Log.LoadAsync();
        _Log.SelectedEntry = _Log.Entries[0];

        _Log.PreviousProblemCommand.Execute(null);

        Assert.Equal("a", _Log.SelectedEntry?.Message);
        Assert.Equal("No warnings or errors before this entry", _Log.Status);
    }

    [Fact]
    public async Task NextProblem_WithNothingSelected_StartsAtTheTop()
    {
        _Runner.ReturnsLog(Sample.Log("Warning", "a"), Sample.Log("Info", "b"));
        await _Log.LoadAsync();
        _Log.SelectedEntry = null;

        _Log.NextProblemCommand.Execute(null);

        Assert.Equal("a", _Log.SelectedEntry?.Message);
    }
}
