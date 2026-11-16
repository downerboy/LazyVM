using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class ChecksViewModelTests
{
    private readonly FakeCommandRunner runner = new();

    [Fact]
    public void Title_OfTheHostChecks_SaysHost()
    {
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        Assert.Equal("Host checks - LazyVM", checks.Title);
        Assert.Equal("Checks of this host", checks.Heading);
    }

    [Fact]
    public void Title_OfAVMsChecks_NamesTheVM()
    {
        var checks = new ChecksViewModel(runner, "DevBox", hostOnly: false);

        Assert.Equal("DevBox checks - LazyVM", checks.Title);
        Assert.Equal("Checks of DevBox", checks.Heading);
    }

    [Fact]
    public async Task Run_PassesTheVMAndHostOnlyAsTheyAre()
    {
        runner.ReturnsChecks(Sample.Check());
        runner.ReturnsChecks(Sample.Check());

        await new ChecksViewModel(runner, null, hostOnly: true).RunAsync();
        await new ChecksViewModel(runner, "DevBox", hostOnly: false).RunAsync();

        Assert.Equal([(null, true), ("DevBox", false)], runner.CheckCalls);
    }

    [Fact]
    public async Task Run_ShowsOneRowPerCheck_InTheOrderTheyCame()
    {
        runner.ReturnsChecks(Sample.Check(check: "LazyVM folder"), Sample.Check(check: "Folder access"), Sample.Check(check: "OneDrive"));
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal(["LazyVM folder", "Folder access", "OneDrive"], checks.Checks.Select(row => row.Check));
    }

    [Fact]
    public async Task Run_SaysHowManyFailedAndWarned()
    {
        runner.ReturnsChecks(
            Sample.Check(VMCheck.Failed),
            Sample.Check(VMCheck.Warning),
            Sample.Check(VMCheck.Warning),
            Sample.Check(VMCheck.Info),
            Sample.Check(VMCheck.OK));
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal("5 checks: 1 failed, 2 warnings", checks.Status);
        Assert.True(checks.HasFailures);
    }

    [Fact]
    public async Task Run_WithNothingWrong_SaysSo()
    {
        runner.ReturnsChecks(Sample.Check(VMCheck.OK), Sample.Check(VMCheck.Info));
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal("2 checks: no problems found", checks.Status);
        Assert.False(checks.HasFailures);
    }

    [Fact]
    public async Task Run_WhenTheChecksCannotRun_SaysWhy()
    {
        runner.ChecksThrow(new InvalidOperationException("The LazyVM folder was not found."));
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        await checks.RunAsync();

        Assert.Equal("Checks could not run: The LazyVM folder was not found.", checks.Status);
        Assert.True(checks.CouldNotRun);
        Assert.Empty(checks.Checks);
    }

    [Fact]
    public async Task Cancel_StopsTheChecksAndSaysSo()
    {
        runner.ChecksWaitForCancel();
        var checks = new ChecksViewModel(runner, "DevBox", hostOnly: false);

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
        runner.ReturnsChecks(Sample.Check(VMCheck.Failed, "Folder access", "others can change it", "Lock it with: Set-LazyVMRoot -Path C:\\LazyVM"));
        var checks = new ChecksViewModel(runner, null, hostOnly: true);

        await checks.RunAsync();

        var row = Assert.Single(checks.Checks);
        Assert.Equal("Failed", row.StatusText);
        Assert.True(row.NeedsAttention);
        Assert.True(row.HasFix);
        Assert.Equal("Failed, Folder access: others can change it. Fix: Lock it with: Set-LazyVMRoot -Path C:\\LazyVM", row.AutomationName);
    }

    [Theory]
    [InlineData(VMCheck.OK, "OK", false)]
    [InlineData(VMCheck.Info, "Note", false)]
    [InlineData(VMCheck.Warning, "Warning", true)]
    [InlineData(VMCheck.Failed, "Failed", true)]
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
        var row = new CheckRowViewModel(Sample.Check(VMCheck.Info, "VMs", "none yet", "Create the first one with: New-LazyVM -Name <Name>"));

        Assert.True(row.HasFix);
        Assert.False(row.NeedsAttention);
    }
}
