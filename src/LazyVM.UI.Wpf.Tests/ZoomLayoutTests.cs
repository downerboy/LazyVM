using LazyVM.UI.ViewModels;

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// The windows at the size a 1280-wide screen leaves at 200% zoom (640 by 450
/// units; 400% leaves 320 by 225): nothing is squeezed out of sight, the title
/// stays on one line and what does not fit scrolls (docs/Dashboard.md section 7,
/// issue #502). They lay the window out without showing it.
/// </summary>
public sealed class ZoomLayoutTests
{
    private static Dispatcher Ui => WpfThread.Dispatcher;

    private static T Layout<T>(Window window, Size size, Func<FrameworkElement, T> read)
    {
        return Ui.Invoke(() =>
        {
            var root = (FrameworkElement)window.Content;
            root.Measure(size);
            root.Arrange(new Rect(size));
            root.UpdateLayout();
            return read(root);
        });
    }

    private static IEnumerable<T> Visuals<T>(DependencyObject parent) where T : DependencyObject
    {
        return Enumerable.Range(0, VisualTreeHelper.GetChildrenCount(parent))
            .Select(i => VisualTreeHelper.GetChild(parent, i))
            .SelectMany(child => (child is T match ? [match] : Enumerable.Empty<T>()).Concat(Visuals<T>(child)));
    }

    private static bool OnOneLine(FrameworkElement root, string text)
    {
        var title = Visuals<TextBlock>(root).First(block => block.Text == text);
        return title.ActualHeight < title.FontSize * 1.8;
    }

    private static VMViewModel VMViewModelOf(FakeRunners runners)
    {
        var tools = new FakeToolWindows(runners);
        return new VMViewModel(Sample.VM("Alpha"), tools, tools.Dialogs, runners.Build, runners.Removal, tools.Changes);
    }

    private static MainWindow MainWindowFor(FakeRunners runners)
    {
        return Ui.Invoke(() =>
        {
            var tools = new FakeToolWindows(runners);
            var model = new MainViewModel(runners.Dashboard, runners.Checks, runners.Help, tools, tools.Changes, TimeProvider.System);
            return new MainWindow { DataContext = model };
        });
    }

    [Theory]
    [InlineData(640, 450)]
    [InlineData(320, 225)]
    public void MainWindow_KeepsTitleOnOneLine(double width, double height)
    {
        var window = MainWindowFor(new FakeRunners());

        var oneLine = Layout(window, new Size(width, height), root => OnOneLine(root, "LazyVM"));

        Assert.True(oneLine, "The title breaks across lines because the buttons take its room.");
    }

    [Theory]
    [InlineData(640, 450)]
    [InlineData(320, 225)]
    public void MainWindow_LeavesRoomForTheListOfVMs(double width, double height)
    {
        var window = MainWindowFor(new FakeRunners());

        var listHeight = Layout(window, new Size(width, height),
            root => Visuals<DataGrid>(root).Single().ActualHeight);

        Assert.True(listHeight >= 150, $"The list of VMs is {listHeight:0} units high; the window should scroll instead.");
    }

    [Theory]
    [InlineData(640, 450)]
    [InlineData(320, 225)]
    public void VMWindow_KeepsTheNameOnOneLine(double width, double height)
    {
        var runner = new FakeRunners();
        var window = Ui.Invoke(() => new VMWindow { DataContext = VMViewModelOf(runner) });

        var oneLine = Layout(window, new Size(width, height), root => OnOneLine(root, "Alpha"));

        Assert.True(oneLine, "The name breaks across lines because the buttons take its room.");
    }

    [Theory]
    [InlineData(640, 450)]
    [InlineData(320, 225)]
    public void VMWindow_ScrollsWhatDoesNotFit(double width, double height)
    {
        var runner = new FakeRunners();
        var window = Ui.Invoke(() => new VMWindow { DataContext = VMViewModelOf(runner) });

        var scrolls = Layout(window, new Size(width, height),
            root => root is ScrollViewer { ScrollableHeight: > 0 });

        Assert.True(scrolls, "Part of the window is cut off and nothing scrolls to it.");
    }

}
