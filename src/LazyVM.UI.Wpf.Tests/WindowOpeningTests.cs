using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// A window opens maximized. A pop-up opens smaller, centered on its screen,
/// and every pop-up opens at the same size (#563).
/// </summary>
public sealed class WindowOpeningTests
{
    private static readonly Type[] _POP_UPS =
        [typeof(PasswordWindow), typeof(QuestionWindow), typeof(ReasonWindow), typeof(RemovalWindow)];

    public static TheoryData<Type> Windows => new(
        typeof(MainWindow), typeof(VMWindow), typeof(ChecksWindow), typeof(LogWindow), typeof(BuildWindow),
        typeof(BuildProgressWindow), typeof(RestoreWindow), typeof(RecoveryKeysWindow), typeof(SecurityFindingsWindow));

    private static T Create<T>(Type type, Func<Window, T> read)
    {
        return WpfThread.Dispatcher.Invoke(() => read((Window)Activator.CreateInstance(type)!));
    }

    private static Window Show(string style)
    {
        return WpfThread.Dispatcher.Invoke(() =>
        {
            var window = new Window
            {
                Style = (Style)Application.Current.Resources[style],
                Left = 0,
                Top = 0,
                ShowActivated = false,
                ShowInTaskbar = false,
            };
            window.Show();
            return window;
        });
    }

    /// <summary>Reads the window after it has finished what showing or changing it started.</summary>
    private static T WhenIdle<T>(Func<T> read)
    {
        return WpfThread.Dispatcher.Invoke(read, DispatcherPriority.ContextIdle);
    }

    private static (Int32Rect Bounds, Int32Rect Area) PlaceOf(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        return (ScreenFit.BoundsOf(handle), ScreenFit.WorkAreaOf(handle));
    }

    [Theory]
    [MemberData(nameof(Windows))]
    public void AWindow_IsMadeToOpenMaximized(Type type)
    {
        Assert.Equal(WindowState.Maximized, Create(type, window => window.WindowState));
    }

    [Fact]
    public void PopUps_AreAllMadeToOpenAtTheSameSizeAndNotMaximized()
    {
        var made = _POP_UPS
            .Select(type => Create(type, window => (window.WindowState, window.SizeToContent, window.Width, window.Height)))
            .ToList();

        var size = Assert.Single(made.Distinct());
        Assert.Equal(WindowState.Normal, size.WindowState);
        Assert.Equal(SizeToContent.Manual, size.SizeToContent);
        Assert.True(size.Width > 0 && size.Height > 0, "A pop-up has no set size.");
    }

    [Fact]
    public void AShownPopUp_IsCenteredInTheWorkArea()
    {
        var window = Show("LvPopUp");

        var (bounds, area) = WhenIdle(() =>
        {
            var place = PlaceOf(window);
            window.Close();
            return place;
        });

        Assert.True(area.Width > 0 && bounds.Width > 0, "The window or its screen was not read.");
        Assert.InRange((2 * bounds.X) + bounds.Width - ((2 * area.X) + area.Width), -2, 2);
        Assert.InRange((2 * bounds.Y) + bounds.Height - ((2 * area.Y) + area.Height), -2, 2);
    }

    /// <summary>Its size when it is not maximized can be larger than the screen, as on a high scale (#558).</summary>
    [Fact]
    public void AMaximizedWindow_StaysMaximized_AndIsInsideTheWorkAreaOnceRestored()
    {
        var window = WpfThread.Dispatcher.Invoke(() =>
        {
            var shown = new Window
            {
                Style = (Style)Application.Current.Resources["LvWindow"],
                Width = 20000,
                Height = 20000,
                ShowInTaskbar = false,
            };
            shown.Show();
            return shown;
        });

        var opened = WhenIdle(() => window.WindowState);
        WpfThread.Dispatcher.Invoke(() => window.WindowState = WindowState.Normal);
        var (bounds, area) = WhenIdle(() =>
        {
            var place = PlaceOf(window);
            window.Close();
            return place;
        });

        Assert.Equal(WindowState.Maximized, opened);
        Assert.True(area.Width > 0 && bounds.Width > 0, "The window or its screen was not read.");
        Assert.Equal(bounds, bounds.FittedInto(area));
    }
}
