using LazyVM.UI.ViewModels;

using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Xml.Linq;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// The text a window shows as information can be copied (#553): text outside a
/// list can be selected, Ctrl+C copies a list's selected row, and Ctrl+Shift+C
/// copies just the path of a security finding. A recovery password is never
/// copied the ordinary way.
/// </summary>
public sealed class CopyTextTests
{
    private static readonly XNamespace _Presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace _Xaml = "http://schemas.microsoft.com/winfx/2006/xaml";

    /// <summary>Text that stays a text block: a title, a heading, or a status line that Narrator reads out when it changes.</summary>
    private static readonly string[] _NOT_SELECTABLE_STYLES =
        ["{StaticResource LvTitle}", "{StaticResource LvSubtitle}", "{StaticResource LvHeading}", "{StaticResource LvStatus}"];

    /// <summary>What a text block inside one of these is part of: a list row, a label, a button or a template.</summary>
    private static readonly string[] _PART_OF = ["DataTemplate", "ControlTemplate", "Label", "Button"];

    private static string WpfFolder
    {
        get
        {
            var folder = new DirectoryInfo(AppContext.BaseDirectory);
            while (folder is not null && !Directory.Exists(Path.Combine(folder.FullName, "LazyVM.UI.Wpf", "Themes")))
            {
                folder = folder.Parent;
            }
            return Path.Combine(folder?.FullName ?? throw new DirectoryNotFoundException("LazyVM.UI.Wpf"), "LazyVM.UI.Wpf");
        }
    }

    private static XDocument Load(string window) => XDocument.Load(Path.Combine(WpfFolder, window));

    public static TheoryData<string> Windows => new(Directory.GetFiles(WpfFolder, "*Window.xaml").Select(Path.GetFileName).OfType<string>());

    private static string? NameOf(XElement element) => (string?)element.Attribute(_Xaml + "Name");

    private static bool CopiesRows(XElement list) =>
        list.Attributes().Any(a => a.Name.LocalName == "RowCopy.IsEnabled" && a.Value == "True");

    [Theory]
    [MemberData(nameof(Windows))]
    public void EveryInformationText_CanBeSelected(string window)
    {
        var unselectable = Load(window).Descendants(_Presentation + "TextBlock")
            .Where(block => !block.Ancestors().Any(parent => _PART_OF.Contains(parent.Name.LocalName)))
            .Where(block => !_NOT_SELECTABLE_STYLES.Contains((string?)block.Attribute("Style")))
            .Where(block => !block.Attributes().Any(a => a.Name.LocalName == "LiveRegion.Announce"))
            .Where(block => !block.Elements(_Presentation + "Run").Any())
            .Select(block => (string?)block.Attribute("Text") ?? block.ToString(SaveOptions.DisableFormatting))
            .ToList();

        Assert.Empty(unselectable);
    }

    /// <summary>Every list copies its selected row, but the checks, which copy a check's fix, and the recovery keys, which hold passwords.</summary>
    [Theory]
    [MemberData(nameof(Windows))]
    public void EveryList_CopiesItsSelectedRow(string window)
    {
        var silent = Load(window).Descendants(_Presentation + "ListBox")
            .Where(list => (window, NameOf(list)) is not ("ChecksWindow.xaml", "List") and not ("RecoveryKeysWindow.xaml", "List"))
            .Where(list => !CopiesRows(list))
            .Select(list => NameOf(list) ?? (string?)list.Attribute("AutomationProperties.Name"))
            .ToList();

        Assert.Empty(silent);
    }

    [Fact]
    public void TheRecoveryKeysList_NeverCopiesARow_SinceARowHoldsItsPasswordOnceShown()
    {
        var list = Load("RecoveryKeysWindow.xaml").Descendants(_Presentation + "ListBox").Single(found => NameOf(found) == "List");

        Assert.False(CopiesRows(list));
    }

    /// <summary>The main window's list copies what every column shows, not only its plain text columns.</summary>
    [Fact]
    public void TheMainList_CopiesEveryColumn()
    {
        var blank = Load("MainWindow.xaml").Descendants(_Presentation + "DataGridTemplateColumn")
            .Where(column => column.Attribute("ClipboardContentBinding") is null)
            .Select(column => (string?)column.Attribute("Header"))
            .ToList();

        Assert.Empty(blank);
    }

    [Fact]
    public void RowCopy_CopiesTheSelectedRowAsNarratorReadsIt()
    {
        var copied = WpfThread.Dispatcher.Invoke(() =>
        {
            var row = new Style(typeof(ListBoxItem));
            row.Setters.Add(new Setter(AutomationProperties.NameProperty, new System.Windows.Data.Binding(".") { StringFormat = "Row {0}" }));
            var list = new ListBox { ItemsSource = new[] { "one", "two" }, ItemContainerStyle = row };
            _ = new Window { Content = list };
            list.Measure(new Size(400, 400));
            list.Arrange(new Rect(0, 0, 400, 400));
            var none = RowCopy.TextOf(list);
            list.SelectedIndex = 1;
            list.UpdateLayout();
            return (None: none, Second: RowCopy.TextOf(list));
        });

        Assert.Null(copied.None);
        Assert.Equal("Row two", copied.Second);
    }

    [Fact]
    public void CopyPath_CopiesOnlyTheFilesAFindingIsAbout()
    {
        static SecurityFindingRow Finding(params string[] where) => new(new VMSecurityFinding(
            "PERSIST-SERVICE", VMSecurityFinding.HIGH, "A new service", "A service was installed.", where,
            "It runs as SYSTEM.", "Remove it.", null, "New"));

        Assert.Equal(@"C:\Tools\agent.exe", SecurityFindingsWindow.PathOf(Finding(@"C:\Tools\agent.exe")));
        Assert.Null(SecurityFindingsWindow.PathOf(Finding()));
        Assert.Null(SecurityFindingsWindow.PathOf(null));
    }

    [Fact]
    public void CopyPath_IsCtrlShiftC_OnTheFindingsList()
    {
        var gestures = WpfThread.Dispatcher.Invoke(() =>
        {
            var window = new SecurityFindingsWindow();
            var list = (ListBox)window.FindName("List");
            var bound = list.CommandBindings.Cast<CommandBinding>().Any(binding => binding.Command == SecurityFindingsWindow.CopyPathCommand);
            var keys = SecurityFindingsWindow.CopyPathCommand.InputGestures.OfType<KeyGesture>()
                .Select(gesture => (gesture.Key, gesture.Modifiers)).ToList();
            return (Bound: bound, Keys: keys);
        });

        Assert.True(gestures.Bound);
        Assert.Contains((Key.C, ModifierKeys.Control | ModifierKeys.Shift), gestures.Keys);
    }

    /// <summary>Text that can be selected is read by Narrator as text, as before, and Tab passes over it.</summary>
    [Fact]
    public void SelectableText_IsReadAsText_AndTabPassesOverIt()
    {
        var text = WpfThread.Dispatcher.Invoke(() =>
        {
            var block = new SelectableText { Text = "Where: C:\\Tools\\agent.exe" };
            var peer = UIElementAutomationPeer.CreatePeerForElement(block);
            return (block.IsReadOnly, block.IsTabStop, Type: peer.GetAutomationControlType(), Name: peer.GetName());
        });

        Assert.True(text.IsReadOnly);
        Assert.False(text.IsTabStop);
        Assert.Equal(AutomationControlType.Text, text.Type);
        Assert.Equal("Where: C:\\Tools\\agent.exe", text.Name);
    }

    /// <summary>A view model's text is read-only, so a binding to it only reads it: a text box would bind both ways, and fail.</summary>
    [Theory]
    [MemberData(nameof(Windows))]
    public void SelectableText_BindsOneWay(string window)
    {
        var twoWay = Load(window).Descendants().Where(element => element.Name.LocalName == "SelectableText")
            .Select(text => (string?)text.Attribute("Text") ?? "")
            .Where(text => text.StartsWith("{Binding", StringComparison.Ordinal) && !text.Contains("Mode=OneWay", StringComparison.Ordinal))
            .ToList();

        Assert.Empty(twoWay);
    }

    /// <summary>The mouse wheel over selectable text scrolls the page it is on.</summary>
    [Fact]
    public void TheMouseWheel_OverSelectableText_ScrollsThePage()
    {
        var offset = WpfThread.Dispatcher.Invoke(() =>
        {
            var text = new SelectableText { Text = "Some help" };
            var page = new ScrollViewer
            {
                Content = new StackPanel { Children = { text, new Border { Height = 2000 } } },
            };
            page.Measure(new Size(400, 300));
            page.Arrange(new Rect(0, 0, 400, 300));
            page.UpdateLayout();
            var host = (UIElement)text.Template.FindName("PART_ContentHost", text);
            host.RaiseEvent(new MouseWheelEventArgs(Mouse.PrimaryDevice, 0, -120) { RoutedEvent = UIElement.MouseWheelEvent });
            page.UpdateLayout();
            return page.VerticalOffset;
        });

        Assert.True(offset > 0, "The text took the mouse wheel, so the page did not scroll.");
    }
}
