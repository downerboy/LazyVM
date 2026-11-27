using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Text shown as information that can be selected and copied, with the mouse
/// or Ctrl+A and Ctrl+C once clicked (#553). Narrator reads it as text, as it
/// read the text block it replaces, and Tab passes over it unless
/// <see cref="Control.IsTabStop"/> is set. Its look is in Themes/Styles.xaml.
/// Bind its text with <c>Mode=OneWay</c>: a text box binds both ways unless
/// told otherwise, which fails on a view model's read-only text.
/// </summary>
public sealed class SelectableText : TextBox
{
    static SelectableText()
    {
        IsReadOnlyProperty.OverrideMetadata(typeof(SelectableText), new FrameworkPropertyMetadata(true));
        IsTabStopProperty.OverrideMetadata(typeof(SelectableText), new FrameworkPropertyMetadata(false));
    }

    protected override AutomationPeer OnCreateAutomationPeer()
    {
        return new SelectableTextAutomationPeer(this);
    }

    /// <summary>Reads as text named by what it says, not as an edit box.</summary>
    private sealed class SelectableTextAutomationPeer(SelectableText owner) : TextBoxAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore()
        {
            return AutomationControlType.Text;
        }

        protected override string GetNameCore()
        {
            var name = base.GetNameCore();
            return string.IsNullOrEmpty(name) ? ((SelectableText)Owner).Text : name;
        }
    }
}
