using System.Windows;
using System.Windows.Input;
using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf;

/// <summary>The Log window. Its behavior is in <see cref="LogViewModel"/>; this only moves keyboard focus.</summary>
public partial class LogWindow : Window
{
    public LogWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is LogViewModel old)
            {
                old.JumpedTo -= FocusEntry;
            }
            if (e.NewValue is LogViewModel now)
            {
                now.JumpedTo += FocusEntry;
            }
        };
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e) => Close();

    /// <summary>Puts keyboard focus on the entry jumped to, so Narrator reads it.</summary>
    private void FocusEntry(LogEntryRowViewModel entry) => ListFocus.Focus(List, entry);
}
