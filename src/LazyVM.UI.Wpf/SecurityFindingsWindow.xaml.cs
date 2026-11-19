using LazyVM.UI.Wpf.ViewModels;
using System.ComponentModel;
using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>A VM's Security findings window. Its behavior is in <see cref="SecurityFindingsViewModel"/>; this only moves keyboard focus.</summary>
public partial class SecurityFindingsWindow : Window
{
    public SecurityFindingsWindow()
    {
        InitializeComponent();
        // Once the findings are read, focus goes to the first, so Narrator reads it.
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is SecurityFindingsViewModel old)
            {
                old.PropertyChanged -= FocusOnFindings;
            }
            if (e.NewValue is SecurityFindingsViewModel now)
            {
                now.PropertyChanged += FocusOnFindings;
            }
        };
    }

    private void FocusOnFindings(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SecurityFindingsViewModel.Findings))
        {
            ListFocus.FocusFirst(List);
        }
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e)
    {
        Close();
    }
}
