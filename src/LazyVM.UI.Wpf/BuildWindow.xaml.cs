using LazyVM.UI.Wpf.ViewModels;
using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>The Build new VM window. Its behavior is in <see cref="BuildViewModel"/>; this only moves keyboard focus and closes.</summary>
public partial class BuildWindow : Window
{
    public BuildWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is BuildViewModel old)
            {
                old.CloseRequested -= CloseOnStart;
            }
            if (e.NewValue is BuildViewModel now)
            {
                now.CloseRequested += CloseOnStart;
            }
        };
        Loaded += (_, _) => NameBox.Focus();
    }

    /// <summary>Esc and Close close the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e)
    {
        Close();
    }

    /// <summary>The build has started and its progress window has opened.</summary>
    private void CloseOnStart(object? sender, EventArgs e)
    {
        Close();
    }
}
