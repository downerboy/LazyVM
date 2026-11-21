using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class ChecksViewModelTests
{
    private readonly FakeCommandRunner _Runner = new();

    [Fact]
    public async Task Run_IsWorkingWhileTheChecksRun()
    {
        _Runner.ReturnsChecks();
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);
        var watcher = new WorkWatcher(checks);

        await checks.RunAsync();

        Assert.Equal(["Running the checks", null], watcher.Seen);
    }

    [Fact]
    public async Task Run_ThatIsCancelled_IsNoLongerWorking()
    {
        _Runner.ChecksWaitForCancel();
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        var running = checks.RunAsync();
        Assert.True(checks.IsWorking);
        checks.CancelCommand.Execute(null);
        await running;

        Assert.False(checks.IsWorking);
    }

    [Fact]
    public void Title_OfTheHostChecks_SaysHost()
    {
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        Assert.Equal("Host checks - LazyVM", checks.Title);
        Assert.Equal("Checks of this host", checks.Heading);
    }

    [Fact]
    public void Title_OfAVMsChecks_NamesTheVM()
    {
        var checks = new ChecksViewModel(_Runner, "DevBox", hostOnly: false);

        Assert.Equal("DevBox checks - LazyVM", checks.Title);
        Assert.Equal("Checks of DevBox", checks.Heading);
    }

    [Fact]
    public async Task Run_PassesTheVMAndHostOnlyAsTheyAre()
    {
        _Runner.ReturnsChecks(Sample.Check());
        _Runner.ReturnsChecks(Sample.Check());

        await new ChecksViewModel(_Runner, null, hostOnly: true).RunAsync();
        await new ChecksViewModel(_Runner, "DevBox", hostOnly: false).RunAsync();

        Assert.Equal([(null, true), ("DevBox", false)], _Runner.CheckCalls);
    }

    [Fact]
    public async Task Run_ShowsOneRowPerCheck_InTheOrderTheyCame()
    {
        _Runner.ReturnsChecks(Sample.Check(check: "LazyVM folder"), Sample.Check(check: "Folder access"), Sample.Check(check: "OneDrive"));
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal(["LazyVM folder", "Folder access", "OneDrive"], checks.Checks.Select(row => row.Check));
    }

    [Fact]
    public async Task Run_SaysHowManyFailedAndWarned()
    {
        _Runner.ReturnsChecks(
            Sample.Check(VMCheck.FAILED),
            Sample.Check(VMCheck.WARNING),
            Sample.Check(VMCheck.WARNING),
            Sample.Check(VMCheck.INFO),
            Sample.Check(VMCheck.OK));
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal("5 checks: 1 failed, 2 warnings", checks.Status);
        Assert.True(checks.HasFailures);
    }

    [Fact]
    public async Task Run_WithNothingWrong_SaysSo()
    {
        _Runner.ReturnsChecks(Sample.Check(VMCheck.OK), Sample.Check(VMCheck.INFO));
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal("2 checks: no problems found", checks.Status);
        Assert.False(checks.HasFailures);
    }

    [Fact]
    public async Task Run_WhenTheChecksCannotRun_SaysWhy()
    {
        _Runner.ChecksThrow(new InvalidOperationException("The LazyVM folder was not found."));
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal("Checks could not run: The LazyVM folder was not found.", checks.Status);
        Assert.True(checks.CouldNotRun);
        Assert.Empty(checks.Checks);
    }

    [Fact]
    public async Task Cancel_StopsTheChecksAndSaysSo()
    {
        _Runner.ChecksWaitForCancel();
        var checks = new ChecksViewModel(_Runner, "DevBox", hostOnly: false);

        var run = checks.RunAsync();
        Assert.True(checks.IsRunning);
        Assert.False(checks.RunCommand.CanExecute(null));
        checks.CancelCommand.Execute(null);
        await run;

        Assert.False(checks.IsRunning);
        Assert.True(checks.RunCommand.CanExecute(null));
        Assert.Equal("Checks cancelled", checks.Status);
    }

    [Fact]
    public async Task Row_ReadsStatusCheckDetailAndFix()
    {
        _Runner.ReturnsChecks(Sample.Check(VMCheck.FAILED, "Folder access", "others can change it", "Lock it with: Set-LazyVMRoot -Path C:\\LazyVM"));
        var checks = new ChecksViewModel(_Runner, null, hostOnly: true);

        await checks.RunAsync();

        var row = Assert.Single(checks.Checks);
        Assert.Equal("Failed", row.StatusText);
        Assert.True(row.NeedsAttention);
        Assert.True(row.HasFix);
        Assert.Equal("Failed, Folder access: others can change it. Fix: Lock it with: Set-LazyVMRoot -Path C:\\LazyVM", row.AutomationName);
    }

    [Theory]
    [InlineData(VMCheck.OK, "OK", false)]
    [InlineData(VMCheck.INFO, "Note", false)]
    [InlineData(VMCheck.WARNING, "Warning", true)]
    [InlineData(VMCheck.FAILED, "Failed", true)]
    public void Row_StatusIsInWords(string status, string words, bool needsAttention)
    {
        var row = new CheckRowViewModel(Sample.Check(status));

        Assert.Equal(words, row.StatusText);
        Assert.Equal(needsAttention, row.NeedsAttention);
    }

    [Fact]
    public void Row_WithoutAFix_IsReadWithoutOne()
    {
        var row = new CheckRowViewModel(Sample.Check(VMCheck.OK, "LazyVM folder", @"C:\Users\me\LazyVM"));

        Assert.False(row.HasFix);
        Assert.Equal(@"OK, LazyVM folder: C:\Users\me\LazyVM", row.AutomationName);
    }

    [Fact]
    public void Row_ANoteWithAFix_ShowsTheFix()
    {
        // Before the first VM, the note that there are none says how to make one.
        var row = new CheckRowViewModel(Sample.Check(VMCheck.INFO, "VMs", "none yet", "Create the first one with: New-LazyVM -Name <Name>"));

        Assert.True(row.HasFix);
        Assert.False(row.NeedsAttention);
    }
}
