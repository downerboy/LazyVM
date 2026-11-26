using LazyVM.UI.ViewModels;

using System.Windows;
using System.Windows.Threading;

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

    [Theory]
    [InlineData(WindowState.Normal)]
    [InlineData(WindowState.Maximized)]
    public void BringToFront_OfAMinimizedWindow_RestoresItAsItWas(WindowState before)
    {
        var window = WpfThread.Dispatcher.Invoke(() =>
        {
            // WPF shows a maximized window only when it may activate it.
            var shown = new Window { WindowState = before, ShowInTaskbar = false };
            shown.Show();
            shown.WindowState = WindowState.Minimized;
            return shown;
        });

        WpfThread.Dispatcher.Invoke(window.BringToFront, DispatcherPriority.ContextIdle);
        var state = WpfThread.Dispatcher.Invoke(() =>
        {
            var found = window.WindowState;
            window.Close();
            return found;
        }, DispatcherPriority.ContextIdle);

        Assert.Equal(before, state);
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
