using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// Text longer than the box it is in is not cut off: it wraps, and a text box
/// with more lines than it shows scrolls (#554). The windows are laid out at
/// the size of a pop-up and of a screen at 400% zoom, without showing them.
/// </summary>
public sealed class TextCutOffTests
{
    private sealed record Row(string Text);

    private static readonly string _LONG_TEXT =
        string.Join(' ', Enumerable.Repeat("a long reason that does not fit on one line", 20)) + " " + new string('x', 200);

    public static TheoryData<Type, string, double, double> TextBoxes => SizesOf(
        (typeof(BuildWindow), "NameBox"), (typeof(BuildWindow), "UserNameBox"),
        (typeof(PasswordWindow), "UserNameBox"), (typeof(PasswordWindow), "PasswordBox"),
        (typeof(ReasonWindow), "ReasonBox"));

    public static TheoryData<Type, string, double, double> Lists => SizesOf(
        (typeof(BuildWindow), "TemplateList"), (typeof(VMWindow), "PhaseList"));

    private static TheoryData<Type, string, double, double> SizesOf(params (Type Window, string Name)[] boxes)
    {
        var data = new TheoryData<Type, string, double, double>();
        foreach (var (window, name) in boxes)
        {
            data.Add(window, name, 720, 620);
            data.Add(window, name, 320, 225);
        }
        return data;
    }

    /// <summary>Lays the window out with <paramref name="fill"/> done to its box, then reads the box.</summary>
    private static TResult Layout<TBox, TResult>(Type type, string name, Size size, Action<TBox> fill, Func<TBox, TResult> read)
        where TBox : FrameworkElement
    {
        return WpfThread.Dispatcher.Invoke(() =>
        {
            var window = (Window)Activator.CreateInstance(type)!;
            var box = (TBox)window.FindName(name);
            fill(box);
            var root = (FrameworkElement)window.Content;
            root.Measure(size);
            root.Arrange(new Rect(size));
            root.UpdateLayout();
            return read(box);
        });
    }

    private static IEnumerable<T> Visuals<T>(DependencyObject parent) where T : DependencyObject
    {
        return Enumerable.Range(0, VisualTreeHelper.GetChildrenCount(parent))
            .Select(i => VisualTreeHelper.GetChild(parent, i))
            .SelectMany(child => (child is T match ? [match] : Enumerable.Empty<T>()).Concat(Visuals<T>(child)));
    }

    [Theory]
    [MemberData(nameof(TextBoxes))]
    public void ATextBox_WrapsLongText_AndScrollsToTheRest(Type type, string name, double width, double height)
    {
        var box = Layout<TextBox, (double Across, double Shown, double Down, double Tall, Visibility Bar)>(
            type, name, new Size(width, height), found => found.Text = _LONG_TEXT,
            found => (found.ExtentWidth, found.ViewportWidth, found.ExtentHeight, found.ViewportHeight,
                Visuals<ScrollViewer>(found).Single().ComputedVerticalScrollBarVisibility));

        Assert.True(box.Shown > 0, "The text box was not laid out.");
        Assert.True(box.Across <= box.Shown + 1, $"The text is {box.Across:0} units wide in {box.Shown:0}, so it is cut off.");
        Assert.True(box.Down > box.Tall, "The box grows to hold any amount of text, pushing what follows it away.");
        Assert.Equal(Visibility.Visible, box.Bar);
    }

    [Theory]
    [MemberData(nameof(Lists))]
    public void AListRow_WrapsLongText(Type type, string name, double width, double height)
    {
        var lines = Layout<ListBox, double>(
            type, name, new Size(width, height), list => list.ItemsSource = new[] { new Row(_LONG_TEXT) },
            list =>
            {
                var text = Visuals<TextBlock>(list).Single(block => block.Text == _LONG_TEXT);
                return text.ActualHeight / text.FontSize;
            });

        Assert.True(lines > 2, "The row stays on one line, so the end of its text is cut off.");
    }

    /// <summary>Typing in a list goes to the row that starts with what is typed.</summary>
    [Theory]
    [InlineData(typeof(BuildWindow), "TemplateList")]
    [InlineData(typeof(VMWindow), "PhaseList")]
    public void AList_StillFindsARowByItsTypedText(Type type, string name)
    {
        var path = Layout<ListBox, string>(type, name, new Size(720, 620), _ => { },
            list => TextSearch.GetTextPath(list) is { Length: > 0 } set ? set : list.DisplayMemberPath);

        Assert.Equal("Text", path);
    }
}
