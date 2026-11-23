using LazyVM.UI.Wpf.ViewModels;

using System.Windows;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>The behavior the app gives every window: finding the one a view model is shown in, and bringing one to the front.</summary>
public sealed class WindowExtensionsTests
{
    private sealed class Page : ViewModelBase;

    [Fact]
    public void WindowOf_GivesTheWindowThatShowsTheViewModel()
    {
        var found = WpfThread.Dispatcher.Invoke(() =>
        {
            var page = new Page();
            var other = new Window { DataContext = new Page() };
            var shown = new Window { DataContext = page };
            return new[] { other, shown }.WindowOf(page) == shown;
        });

        Assert.True(found);
    }

    [Fact]
    public void WindowOf_AViewModelNoWindowShows_GivesNothing()
    {
        var found = WpfThread.Dispatcher.Invoke(() => new[] { new Window { DataContext = new Page() } }.WindowOf(new Page()));

        Assert.Null(found);
    }

    [Fact]
    public void BringToFront_OfAMinimizedWindow_RestoresIt()
    {
        var state = WpfThread.Dispatcher.Invoke(() =>
        {
            var window = new Window { WindowState = WindowState.Minimized };
            window.BringToFront();
            return window.WindowState;
        });

        Assert.Equal(WindowState.Normal, state);
    }

    [Fact]
    public void BringToFront_OfAWindowThatIsNotMinimized_LeavesItsState()
    {
        var state = WpfThread.Dispatcher.Invoke(() =>
        {
            var window = new Window { WindowState = WindowState.Maximized };
            window.BringToFront();
            return window.WindowState;
        });

        Assert.Equal(WindowState.Maximized, state);
    }
}
