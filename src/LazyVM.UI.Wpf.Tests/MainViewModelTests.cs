using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class MainViewModelTests : IDisposable
{
    private readonly CultureScope culture = new("en-GB");
    private readonly FakeCommandRunner runner = new();
    private readonly FakeVMWindowManager windows = new();
    private readonly MainViewModel main;

    public MainViewModelTests()
    {
        main = new MainViewModel(runner, windows, new FixedClock(new DateTimeOffset(2026, 11, 14, 14, 52, 0, TimeSpan.Zero)));
    }

    public void Dispose() => culture.Dispose();

    [Fact]
    public async Task Refresh_ShowsOneRowPerVM()
    {
        runner.Returns(Sample.VM("DevBox"), Sample.VM("PlainWin"), Sample.VM("TestBox"));

        await main.RefreshAsync();

        Assert.Equal(["DevBox", "PlainWin", "TestBox"], main.VMs.Select(row => row.Name));
    }

    [Fact]
    public async Task Refresh_SaysWhatItDidInTheStatusLine()
    {
        runner.Returns(Sample.VM("DevBox"), Sample.VM("PlainWin"), Sample.VM("TestBox"));

        await main.RefreshAsync();

        Assert.Equal("Refreshed 3 VMs at 14:52", main.Status);
    }

    [Fact]
    public async Task Refresh_OfOneVM_SaysVMNotVMs()
    {
        runner.Returns(Sample.VM());

        await main.RefreshAsync();

        Assert.Equal("Refreshed 1 VM at 14:52", main.Status);
    }

    [Fact]
    public async Task Refresh_WhenTheCommandFails_KeepsTheListAndSaysWhy()
    {
        runner.Returns(Sample.VM("DevBox"));
        runner.Throws(new InvalidOperationException("The LazyVM folder was not found."));
        await main.RefreshAsync();

        await main.RefreshAsync();

        Assert.Equal(["DevBox"], main.VMs.Select(row => row.Name));
        Assert.Equal("Refresh failed: The LazyVM folder was not found.", main.Status);
    }

    [Fact]
    public async Task CancelRefresh_StopsTheCallAndKeepsTheList()
    {
        runner.Returns(Sample.VM("DevBox"));
        runner.WaitsForCancel();
        await main.RefreshAsync();

        var refresh = main.RefreshAsync();
        Assert.True(main.IsRefreshing);
        main.CancelRefreshCommand.Execute(null);
        await refresh;

        Assert.False(main.IsRefreshing);
        Assert.Equal(["DevBox"], main.VMs.Select(row => row.Name));
        Assert.Equal("Refresh cancelled", main.Status);
    }

    [Fact]
    public async Task RefreshCommand_IsUnavailableWhileARefreshRuns()
    {
        runner.WaitsForCancel();

        var refresh = main.RefreshAsync();

        Assert.False(main.RefreshCommand.CanExecute(null));
        Assert.True(main.CancelRefreshCommand.CanExecute(null));
        main.CancelRefreshCommand.Execute(null);
        await refresh;
        Assert.True(main.RefreshCommand.CanExecute(null));
        Assert.False(main.CancelRefreshCommand.CanExecute(null));
    }

    [Fact]
    public async Task Refresh_KeepsTheSelectedVMSelected()
    {
        runner.Returns(Sample.VM("DevBox"), Sample.VM("TestBox"));
        runner.Returns(Sample.VM("DevBox", "Off"), Sample.VM("TestBox", "Off"));
        await main.RefreshAsync();
        main.SelectedVM = main.VMs[1];

        await main.RefreshAsync();

        Assert.Equal("TestBox", main.SelectedVM?.Name);
        Assert.Equal("Off", main.SelectedVM?.State);
    }

    [Fact]
    public async Task Refresh_AddsNewVMsAndDropsDisposedOnes()
    {
        runner.Returns(Sample.VM("DevBox"), Sample.VM("OldBox"));
        runner.Returns(Sample.VM("DevBox"), Sample.VM("NewBox"));
        await main.RefreshAsync();

        await main.RefreshAsync();

        Assert.Equal(["DevBox", "NewBox"], main.VMs.Select(row => row.Name));
    }

    [Fact]
    public async Task OpenVM_ShowsTheSelectedVMsWindow()
    {
        runner.Returns(Sample.VM("DevBox"));
        await main.RefreshAsync();
        main.SelectedVM = main.VMs[0];

        main.OpenVMCommand.Execute(null);

        Assert.Equal("DevBox", Assert.Single(windows.Shown).Name);
    }

    [Fact]
    public void OpenVM_WithNothingSelected_IsUnavailable()
    {
        Assert.False(main.OpenVMCommand.CanExecute(null));
    }

    [Fact]
    public async Task OpenVM_Twice_BringsTheOpenWindowToTheFront()
    {
        runner.Returns(Sample.VM("DevBox"));
        await main.RefreshAsync();
        main.SelectedVM = main.VMs[0];

        main.OpenVMCommand.Execute(null);
        main.OpenVMCommand.Execute(null);

        var window = Assert.Single(windows.Shown);
        Assert.Same(window, Assert.Single(windows.BroughtToFront));
    }

    [Fact]
    public async Task OpenVM_AfterItsWindowClosed_OpensANewWindow()
    {
        runner.Returns(Sample.VM("DevBox"));
        await main.RefreshAsync();
        main.SelectedVM = main.VMs[0];
        main.OpenVMCommand.Execute(null);
        windows.Close(windows.Shown[0]);

        main.OpenVMCommand.Execute(null);

        Assert.Equal(2, windows.Shown.Count);
        Assert.Empty(windows.BroughtToFront);
    }

    [Fact]
    public async Task Refresh_UpdatesTheOpenVMWindows()
    {
        runner.Returns(Sample.VM("DevBox", "Running"));
        runner.Returns(Sample.VM("DevBox", "Off"));
        await main.RefreshAsync();
        main.SelectedVM = main.VMs[0];
        main.OpenVMCommand.Execute(null);

        await main.RefreshAsync();

        Assert.Equal("Off", windows.Shown[0].State);
    }
}
