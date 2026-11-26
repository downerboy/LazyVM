using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// A window opens wholly inside the work area of its screen, smaller than its
/// default size when it has to be (#558).
/// </summary>
public sealed class ScreenFitTests
{
    private static readonly Int32Rect _AREA = new(480, 0, 3360, 2160);

    [Fact]
    public void FittedInto_OfARectangleThatFits_LeavesIt()
    {
        var window = new Int32Rect(600, 100, 800, 600);

        Assert.Equal(window, window.FittedInto(_AREA));
    }

    [Fact]
    public void FittedInto_OfARectanglePastTheRightAndBottom_MovesItIn()
    {
        var fitted = new Int32Rect(3000, 1800, 1000, 600).FittedInto(_AREA);

        Assert.Equal(new Int32Rect(2840, 1560, 1000, 600), fitted);
    }

    [Fact]
    public void FittedInto_OfARectanglePastTheLeftAndTop_MovesItIn()
    {
        var fitted = new Int32Rect(100, -50, 800, 600).FittedInto(_AREA);

        Assert.Equal(new Int32Rect(480, 0, 800, 600), fitted);
    }

    [Fact]
    public void FittedInto_OfARectangleLargerThanTheArea_ShrinksItToTheArea()
    {
        var fitted = new Int32Rect(768, 288, 4000, 3000).FittedInto(_AREA);

        Assert.Equal(_AREA, fitted);
    }

    [Fact]
    public void CenteredIn_OfARectangle_PutsItInTheMiddle()
    {
        var centered = new Int32Rect(0, 0, 1360, 1160).CenteredIn(_AREA);

        Assert.Equal(new Int32Rect(1480, 500, 1360, 1160), centered);
    }

    [Fact]
    public void CenteredIn_OfARectangleLargerThanTheArea_ShrinksItToTheArea()
    {
        var centered = new Int32Rect(0, 0, 4000, 3000).CenteredIn(_AREA);

        Assert.Equal(_AREA, centered);
    }

    [Theory]
    [InlineData(SizeToContent.Manual)]
    [InlineData(SizeToContent.Height)]
    public void AShownWindow_TooLargeAndOffTheScreen_IsInsideTheWorkArea(SizeToContent sizeToContent)
    {
        var window = WpfThread.Dispatcher.Invoke(() =>
        {
            var shown = new Window
            {
                Style = (Style)Application.Current.Resources["LvWindow"],
                Content = new FrameworkElement { Height = 20000 },
                Width = 20000,
                Height = sizeToContent == SizeToContent.Manual ? 20000 : double.NaN,
                SizeToContent = sizeToContent,
                WindowState = WindowState.Normal,
                Left = 200,
                Top = 200,
                ShowActivated = false,
                ShowInTaskbar = false,
            };
            shown.Show();
            return shown;
        });

        var (bounds, area) = WpfThread.Dispatcher.Invoke(() =>
        {
            var handle = new WindowInteropHelper(window).Handle;
            var found = (ScreenFit.BoundsOf(handle), ScreenFit.WorkAreaOf(handle));
            window.Close();
            return found;
        }, DispatcherPriority.ContextIdle);

        Assert.True(area.Width > 0 && bounds.Width > 0, "The window or its screen was not read.");
        Assert.Equal(bounds, bounds.FittedInto(area));
    }
}
