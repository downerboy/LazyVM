using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class RestoreViewModelTests : IDisposable
{
    private static readonly VMRestorePoint _October = new("20261008-193000", new DateTime(2026, 10, 8, 19, 30, 0), HasToolingList: true);
    private static readonly VMRestorePoint _November = new("20261112-021000", new DateTime(2026, 11, 12, 2, 10, 0), HasToolingList: true);
    private static readonly VMRestorePoint _NoList = new("20260901-120000", new DateTime(2026, 9, 1, 12, 0, 0), HasToolingList: false);

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeToolWindows _Tools;

    public RestoreViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runner);
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private async Task<RestoreViewModel> Loaded(VMDashboard? entry = null, params VMRestorePoint[] points)
    {
        _Runner.ReturnsRestorePoints(points);
        var restore = new RestoreViewModel(entry ?? Sample.VM(), _Tools);
        await restore.LoadAsync();
        return restore;
    }

    [Fact]
    public async Task Points_AreNewestFirst_WithTheirDate_AndWhetherTheirToolingListIsThere()
    {
        var restore = await Loaded(null, _NoList, _October, _November);

        Assert.Equal(
        [
            "12 November 2026 02:10, restore point 20261112-021000, tooling list kept",
            "8 October 2026 19:30, restore point 20261008-193000, tooling list kept",
            "1 September 2026 12:00, restore point 20260901-120000, tooling list missing, so it cannot be restored",
        ], restore.Points.Select(point => point.Text));
        Assert.Same(restore.Points[0], restore.SelectedPoint);
        Assert.Equal(["DevBox"], _Runner.RestorePointCalls);
    }

    [Fact]
    public async Task RestoreHelp_SaysWhatRestoringTheChosenPointPutsBack_AndWhatIsLost()
    {
        var restore = await Loaded(null, _October, _November);
        var changed = new List<string?>();
        restore.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        restore.SelectedPoint = restore.Points[1];

        Assert.Equal(
            "Returns DevBox to 8 October 2026 19:30, with the tooling list it had then; every other setting stays as it is now. "
            + "All of its disks go back to then, including the Dev Drive, the SQL data disk and the User disk, so code not yet pushed, database changes and files in your personal folders changed since then are lost. "
            + "A checkpoint of how it is now is taken first, so this restore can be undone. Push your work first.",
            restore.RestoreHelp);
        Assert.True(restore.HasRestoreHelp);
        Assert.Contains(nameof(RestoreViewModel.RestoreHelp), changed);
        Assert.Contains(nameof(RestoreViewModel.HasRestoreHelp), changed);
    }

    [Fact]
    public async Task RestoreHelp_IsEmpty_WithNoPoints_OrForAPointThatCannotBeRestored()
    {
        Assert.False((await Loaded()).HasRestoreHelp);
        Assert.Equal(string.Empty, (await Loaded(null, _NoList)).RestoreHelp);
    }

    [Fact]
    public async Task WithNoRestorePoints_TheWindowSaysSo()
    {
        var restore = await Loaded();

        Assert.Empty(restore.Points);
        Assert.Equal("DevBox has no restore points yet. One is taken each time a change to its tooling is recorded.", restore.Status);
        Assert.False(restore.RestoreCommand.CanExecute(null));
    }

    [Fact]
    public async Task WhenThePointsCannotBeRead_TheWindowSaysWhy()
    {
        _Runner.RestorePointsThrow(new InvalidOperationException("Hyper-V is not running."));
        var restore = new RestoreViewModel(Sample.VM(), _Tools);

        await restore.LoadAsync();

        Assert.Equal("The restore points could not be read: Hyper-V is not running.", restore.Status);
    }

    [Fact]
    public async Task LoadAndRestore_AreWorkingWhileThePointsAreReadAndTheVMIsRestored()
    {
        _Runner.ReturnsRestorePoints(_October);
        var restore = new RestoreViewModel(Sample.VM(), _Tools);
        var watcher = new WorkWatcher(restore);
        await restore.LoadAsync();
        restore.SelectedPoint = restore.Points[0];
        _Tools.ConfirmsRestore = true;
        _Runner.ReturnsRestorePoints(_October);

        await restore.RestoreAsync();

        Assert.Equal(
            ["Reading the restore points", null, "Restoring DevBox", null, "Reading the restore points", null],
            watcher.Seen);
    }

    [Fact]
    public async Task Restore_AsksWhatItDoes_AndOnYes_RestoresThatPoint_ThenReadsThePointsAgain()
    {
        var restore = await Loaded(null, _October, _November);
        restore.SelectedPoint = restore.Points[1];
        _Tools.ConfirmsRestore = true;
        _Runner.ReturnsRestorePoints(_October, _November, new("20261118-090000", new DateTime(2026, 11, 18, 9, 0, 0), true));
        var listChanged = 0;
        _Tools.ToolingRestored += (_, _) => listChanged++;

        await restore.RestoreAsync();

        Assert.Equal(
            "Do you really want to restore DevBox to 8 October 2026 19:30? All of its disks go back to then, including the Dev Drive, the SQL data disk and the User disk, so code not yet pushed, database changes and files in your personal folders changed since then are lost. A checkpoint of how it is now is taken first, so this restore can be undone.",
            Assert.Single(_Tools.RestoreQuestions));
        Assert.Equal([("DevBox", "20261008-193000")], _Runner.RestoreCalls);
        Assert.Equal(1, listChanged);
        Assert.Equal("DevBox is back at 8 October 2026 19:30. A restore point of how it was just before was taken, so this can be undone.", restore.Status);
        Assert.Equal(3, restore.Points.Count);
        Assert.False(restore.IsRestoring);
    }

    [Fact]
    public async Task Restore_OnNo_RestoresNothing()
    {
        var restore = await Loaded(null, _October);
        _Tools.ConfirmsRestore = false;

        await restore.RestoreAsync();

        Assert.Single(_Tools.RestoreQuestions);
        Assert.Empty(_Runner.RestoreCalls);
        Assert.Equal("DevBox was not restored.", restore.Status);
    }

    [Fact]
    public async Task Restore_ThatFailed_GivesTheModulesReason_AndReadsThePointsAgain()
    {
        var restore = await Loaded(null, _October);
        _Tools.ConfirmsRestore = true;
        _Runner.RestoreFails = new InvalidOperationException("A build of DevBox is running now.");
        _Runner.ReturnsRestorePoints(_October);
        var listChanged = 0;
        _Tools.ToolingRestored += (_, _) => listChanged++;

        await restore.RestoreAsync();

        Assert.Equal("The restore did not finish: A build of DevBox is running now.", restore.Status);
        Assert.Equal(1, listChanged);
        Assert.Equal(2, _Runner.RestorePointCalls.Count);
    }

    [Fact]
    public async Task APointWithoutItsToolingList_CannotBeRestored_AndTheNoteSaysWhy()
    {
        var restore = await Loaded(null, _NoList);

        Assert.False(restore.RestoreCommand.CanExecute(null));
        Assert.Equal("This restore point cannot be restored: its tooling list is missing.", restore.RestoreNote);

        await restore.RestoreAsync();
        Assert.Empty(_Tools.RestoreQuestions);
    }

    [Fact]
    public async Task WhileARunIsGoing_RestoreIsDisabled_AndTheNoteSaysWhy()
    {
        var restore = await Loaded(Sample.VM() with
        {
            Run = new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9 }
        }, _October);

        Assert.False(restore.RestoreCommand.CanExecute(null));
        Assert.Equal("A build of DevBox is running now, so DevBox cannot be restored until it has ended.", restore.RestoreNote);
        Assert.True(restore.HasRestoreNote);

        await restore.RestoreAsync();
        Assert.Empty(_Tools.RestoreQuestions);
    }

    [Fact]
    public async Task ARunThatStartsLater_DisablesRestore()
    {
        var restore = await Loaded(null, _October);
        Assert.True(restore.RestoreCommand.CanExecute(null));
        Assert.False(restore.HasRestoreNote);

        restore.Update(Sample.VM() with
        {
            Run = new VMRun { Command = "Maintenance", Status = VMRun.RUNNING, ProcessId = 9 }
        });

        Assert.False(restore.RestoreCommand.CanExecute(null));
        Assert.StartsWith("Maintenance of DevBox is running now", restore.RestoreNote);
    }

    [Fact]
    public async Task WhileRestoring_ItCannotStartAgain()
    {
        var restore = await Loaded(null, _October);
        _Tools.ConfirmsRestore = true;
        _Runner.RestoreGate = new TaskCompletionSource();
        _Runner.ReturnsRestorePoints(_October);

        var restoring = restore.RestoreAsync();

        Assert.True(restore.IsRestoring);
        Assert.Equal("Restoring DevBox to 8 October 2026 19:30", restore.Status);
        Assert.False(restore.RestoreCommand.CanExecute(null));
        _Runner.RestoreGate.SetResult();
        await restoring;
        Assert.Single(_Runner.RestoreCalls);
    }

    [Fact]
    public void Title_NamesTheVM()
    {
        var restore = new RestoreViewModel(Sample.VM(), _Tools);

        Assert.Equal("Restore points of DevBox - LazyVM", restore.Title);
        Assert.Equal("DevBox", restore.Name);
    }
}
