using System.Xml.Linq;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// The automated part of the accessibility pass (docs/Dashboard.md section 7, issue #502).
/// They read the XAML as text, so they need no window and no screen reader.
/// What a person has to hear or see is checked by hand and recorded in ACCESSIBILITY.md.
/// </summary>
public sealed class AccessibilityXamlTests
{
    private static readonly XNamespace _Presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace _Xaml = "http://schemas.microsoft.com/winfx/2006/xaml";

    private static readonly string[] _NAME_NEEDED = ["TextBox", "PasswordBox", "ComboBox", "ListBox", "ListView", "DataGrid", "CheckBox", "RadioButton"];

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

    private static XDocument Load(string relativePath) => XDocument.Load(Path.Combine(WpfFolder, relativePath));

    public static IEnumerable<object[]> Windows =>
        Directory.GetFiles(WpfFolder, "*Window.xaml").Select(path => new object[] { Path.GetFileName(path) });

    public static IEnumerable<object[]> Themes =>
        Directory.GetFiles(Path.Combine(WpfFolder, "Themes"), "*.xaml")
            .Where(path => !path.EndsWith("Styles.xaml", StringComparison.Ordinal))
            .Select(path => new object[] { Path.GetFileName(path) });

    private static IEnumerable<string> BrushKeys(string theme) =>
        Load(Path.Combine("Themes", theme)).Descendants()
            .Select(element => (string?)element.Attribute(_Xaml + "Key"))
            .OfType<string>()
            .Order(StringComparer.Ordinal);

    private static bool HasName(XElement control, XDocument document) =>
        control.Attributes().Any(a => a.Name.LocalName is "AutomationProperties.Name" or "AutomationProperties.LabeledBy" && a.Value.Length > 0)
        || control.Attribute("Header") is not null
        || IsLabelTarget(control, document);

    private static bool IsLabelTarget(XElement control, XDocument document)
    {
        var name = (string?)control.Attribute(_Xaml + "Name");
        return name is not null && document.Descendants(_Presentation + "Label")
            .Any(label => ((string?)label.Attribute("Target") ?? "").Contains("ElementName=" + name, StringComparison.Ordinal));
    }

    /// <summary>The window style carries what every window needs, such as opening inside the screen (#558).</summary>
    [Theory]
    [MemberData(nameof(Windows))]
    public void EveryWindow_UsesTheWindowStyle(string window)
    {
        var style = (string?)Load(window).Root?.Attribute("Style");

        Assert.Contains(style, new[] { "{StaticResource LvWindow}", "{StaticResource LvPopUp}" });
    }

    [Theory]
    [MemberData(nameof(Windows))]
    public void EveryInputControl_HasAName(string window)
    {
        var document = Load(window);

        var unnamed = document.Descendants()
            .Where(e => e.Name.Namespace == _Presentation && _NAME_NEEDED.Contains(e.Name.LocalName))
            .Where(e => !HasName(e, document))
            .Select(e => e.Name.LocalName + " " + e.ToString(SaveOptions.DisableFormatting)[..Math.Min(80, e.ToString(SaveOptions.DisableFormatting).Length)])
            .ToList();

        Assert.Empty(unnamed);
    }

    [Theory]
    [MemberData(nameof(Windows))]
    public void EveryButton_HasTextOrAName(string window)
    {
        var document = Load(window);

        var unnamed = document.Descendants(_Presentation + "Button")
            .Where(b => b.Attribute("Content") is null && !b.HasElements && string.IsNullOrWhiteSpace(b.Value))
            .Where(b => !HasName(b, document))
            .Select(b => b.ToString(SaveOptions.DisableFormatting))
            .ToList();

        Assert.Empty(unnamed);
    }

    [Theory]
    [MemberData(nameof(Windows))]
    public void TabOrder_FollowsTheLayout(string window)
    {
        // Tab order is the order in the XAML. An explicit TabIndex would move it away from the layout.
        var document = Load(window);

        Assert.DoesNotContain(document.Descendants().SelectMany(e => e.Attributes()), a => a.Name.LocalName == "TabIndex");
    }

    [Theory]
    [MemberData(nameof(Windows))]
    public void EveryWindowButTheMainOne_ClosesWithEscape(string window)
    {
        if (window == "MainWindow.xaml")
        {
            return;
        }

        // Either an Escape key binding, or a Cancel button, which Escape presses.
        var document = Load(window);
        var closesWithEscape = document.Descendants(_Presentation + "KeyBinding").Any(k => (string?)k.Attribute("Key") == "Escape")
            || document.Descendants(_Presentation + "Button").Any(b => (string?)b.Attribute("IsCancel") == "True");

        Assert.True(closesWithEscape, window + " does not close with Escape.");
    }

    [Theory]
    [MemberData(nameof(Windows))]
    public void Windows_UseThemeColorsOnly(string window)
    {
        var colored = Load(window).Descendants().SelectMany(e => e.Attributes())
            .Where(a => a.Name.LocalName is "Foreground" or "Background" or "BorderBrush" or "Fill" or "Stroke")
            .Where(a => !a.Value.StartsWith('{') && a.Value != "Transparent")
            .Select(a => a.Name.LocalName + "=" + a.Value)
            .ToList();

        Assert.Empty(colored);
    }

    [Fact]
    public void Styles_TakeTheirColorsFromTheThemeResources()
    {
        var colored = Load(Path.Combine("Themes", "Styles.xaml")).Descendants().SelectMany(e => e.Attributes())
            .Where(a => a.Name.LocalName is "Foreground" or "Background" or "BorderBrush" or "Fill" or "Stroke" or "Color")
            .Where(a => !a.Value.StartsWith('{') && a.Value != "Transparent")
            .Select(a => a.Name.LocalName + "=" + a.Value)
            .ToList();

        Assert.Empty(colored);
    }

    [Fact]
    public void Styles_UseOnlyThemeBrushesThatEveryThemeDefines()
    {
        var used = System.Text.RegularExpressions.Regex
            .Matches(File.ReadAllText(Path.Combine(WpfFolder, "Themes", "Styles.xaml")) + string.Concat(Directory.GetFiles(WpfFolder, "*.xaml").Select(File.ReadAllText)),
                     @"DynamicResource (Lv\w+)")
            .Select(m => m.Groups[1].Value)
            .Distinct();
        var defined = BrushKeys("Light.xaml").ToHashSet();
        var styles = Load(Path.Combine("Themes", "Styles.xaml")).Descendants()
            .Select(e => (string?)e.Attribute(_Xaml + "Key")).OfType<string>().ToHashSet();

        Assert.All(used, key => Assert.True(defined.Contains(key) || styles.Contains(key), key + " is not defined."));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void EveryTheme_DefinesTheSameTokensAsLight(string theme)
    {
        Assert.Equal(BrushKeys("Light.xaml"), BrushKeys(theme));
    }

    [Fact]
    public void HighContrast_UsesSystemColorsOnly()
    {
        var custom = Load(Path.Combine("Themes", "HighContrast.xaml")).Descendants(_Presentation + "SolidColorBrush")
            .Where(b => !((string?)b.Attribute("Color") ?? "").Contains("SystemColors.", StringComparison.Ordinal))
            .Select(b => (string?)b.Attribute(_Xaml + "Key"))
            .ToList();

        Assert.Empty(custom);
    }
}
