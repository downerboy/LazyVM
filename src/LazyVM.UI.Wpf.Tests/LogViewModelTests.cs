using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class LogViewModelTests : IDisposable
{
    private readonly CultureScope culture = new("en-GB");
    private readonly FakeCommandRunner runner = new();
    private readonly LogViewModel log;

    public LogViewModelTests()
    {
        log = new LogViewModel(runner, "DevBox");
    }

    public void Dispose() => culture.Dispose();

    [Fact]
    public void Title_NamesTheVM()
    {
        Assert.Equal("DevBox log - LazyVM", log.Title);
        Assert.Equal("Log of DevBox", log.Heading);
    }

    [Fact]
    public async Task Load_AsksForTheVMsLastEntriesOnly()
    {
        runner.ReturnsLog();

        await log.LoadAsync();

        Assert.Equal([("DevBox", LogViewModel.Tail)], runner.LogCalls);
    }

    [Fact]
    public async Task Load_ShowsTheEntriesOldestFirst_AndSelectsTheNewest()
    {
        runner.ReturnsLog(Sample.Log("Phase", "Build", 1), Sample.Log("Info", "Copying the ISO", 2), Sample.Log("OK", "Done", 3));

        await log.LoadAsync();

        Assert.Equal(["Build", "Copying the ISO", "Done"], log.Entries.Select(entry => entry.Message));
        Assert.Same(log.Entries[^1], log.SelectedEntry);
    }

    [Fact]
    public async Task Load_SaysHowManyEntriesWarningsAndErrors()
    {
        runner.ReturnsLog(
            Sample.Log("Info", "a"), Sample.Log("Error", "b"), Sample.Log("Warning", "c"),
            Sample.Log("Warning", "d"), Sample.Log("Error", "e"), Sample.Log("Error", "f"));

        await log.LoadAsync();

        Assert.Equal("6 entries: 3 errors, 2 warnings", log.Status);
    }

    [Fact]
    public async Task Load_OfAQuietLog_SaysThereAreNoWarningsOrErrors()
    {
        runner.ReturnsLog(Sample.Log("Info", "a"));

        await log.LoadAsync();

        Assert.Equal("1 entry: no warnings or errors", log.Status);
    }

    [Fact]
    public async Task Load_BeforeThereIsALog_SaysSo()
    {
        runner.ReturnsLog();

        await log.LoadAsync();

        Assert.Empty(log.Entries);
        Assert.Null(log.SelectedEntry);
        Assert.Equal("No log entries yet", log.Status);
    }

    [Fact]
    public async Task Load_OfAFullTail_SaysOnlyTheLastAreShown()
    {
        runner.ReturnsLog([.. Enumerable.Range(0, LogViewModel.Tail).Select(_ => Sample.Log("Info", "a"))]);

        await log.LoadAsync();

        Assert.Equal($"The last {LogViewModel.Tail} entries: no warnings or errors", log.Status);
    }

    [Fact]
    public async Task Load_WhenTheLogCannotBeRead_SaysWhy()
    {
        runner.LogThrows(new InvalidOperationException("Access to the path is denied."));

        await log.LoadAsync();

        Assert.Equal("The log could not be read: Access to the path is denied.", log.Status);
    }

    [Fact]
    public async Task Entry_IsReadAsLevelTimeAndMessage()
    {
        runner.ReturnsLog(Sample.Log("Error", "Windows Update failed", 10));

        await log.LoadAsync();

        var entry = Assert.Single(log.Entries);
        Assert.Equal("12 November 2026 02:10:05", entry.TimeText);
        Assert.Equal("Error, 12 November 2026 02:10:05, Windows Update failed", entry.AutomationName);
        Assert.True(entry.IsProblem);
    }

    [Fact]
    public async Task PreviousProblem_FromTheNewest_JumpsToTheLastWarningOrError()
    {
        runner.ReturnsLog(Sample.Log("Error", "a"), Sample.Log("Info", "b"), Sample.Log("Warning", "c"), Sample.Log("Info", "d"));
        await log.LoadAsync();
        LogEntryRowViewModel? jumpedTo = null;
        log.JumpedTo += entry => jumpedTo = entry;

        log.PreviousProblemCommand.Execute(null);

        Assert.Equal("c", log.SelectedEntry?.Message);
        Assert.Same(log.SelectedEntry, jumpedTo);
    }

    [Fact]
    public async Task NextProblem_SkipsEntriesThatAreNotWarningsOrErrors()
    {
        runner.ReturnsLog(Sample.Log("Info", "a"), Sample.Log("OK", "b"), Sample.Log("Phase", "c"), Sample.Log("Error", "d"), Sample.Log("Info", "e"));
        await log.LoadAsync();
        log.SelectedEntry = log.Entries[0];

        log.NextProblemCommand.Execute(null);

        Assert.Equal("d", log.SelectedEntry?.Message);
    }

    [Fact]
    public async Task NextProblem_WithNoneLeft_StaysAndSaysSo()
    {
        runner.ReturnsLog(Sample.Log("Error", "a"), Sample.Log("Info", "b"));
        await log.LoadAsync();

        log.NextProblemCommand.Execute(null);

        Assert.Equal("b", log.SelectedEntry?.Message);
        Assert.Equal("No warnings or errors after this entry", log.Status);
    }

    [Fact]
    public async Task PreviousProblem_WithNoneBefore_StaysAndSaysSo()
    {
        runner.ReturnsLog(Sample.Log("Info", "a"), Sample.Log("Error", "b"));
        await log.LoadAsync();
        log.SelectedEntry = log.Entries[0];

        log.PreviousProblemCommand.Execute(null);

        Assert.Equal("a", log.SelectedEntry?.Message);
        Assert.Equal("No warnings or errors before this entry", log.Status);
    }

    [Fact]
    public async Task NextProblem_WithNothingSelected_StartsAtTheTop()
    {
        runner.ReturnsLog(Sample.Log("Warning", "a"), Sample.Log("Info", "b"));
        await log.LoadAsync();
        log.SelectedEntry = null;

        log.NextProblemCommand.Execute(null);

        Assert.Equal("a", log.SelectedEntry?.Message);
    }
}
