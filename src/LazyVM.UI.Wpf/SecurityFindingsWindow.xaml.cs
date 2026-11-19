using LazyVM.UI.Wpf.ViewModels;

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace LazyVM.UI.Wpf;

/// <summary>
/// A VM's Security findings window. Its behavior is in
/// <see cref="SecurityFindingsViewModel"/>; this only moves keyboard focus,
/// and reads the outcome of an approval or revoke out again when it does.
/// </summary>
public partial class SecurityFindingsWindow : Window
{
    /// <summary>The button of the last approval or revoke, and its list. Click comes before the command runs, by mouse, Space or Alt key alike.</summary>
    private (Button Button, ListBox List)? _Used;

    public SecurityFindingsWindow()
    {
        InitializeComponent();
        ApproveButton.Click += (_, _) => _Used = (ApproveButton, List);
        RevokeButton.Click += (_, _) => _Used = (RevokeButton, ApprovalList);
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
        if (e.PropertyName == nameof(SecurityFindingsViewModel.Findings) && sender is SecurityFindingsViewModel { IsChanging: false })
        {
            ListFocus.FocusFirst(List);
        } else if (e.PropertyName == nameof(SecurityFindingsViewModel.IsChanging) && sender is SecurityFindingsViewModel { IsChanging: false })
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, KeepFocusAfterChange);
        }
    }

    /// <summary>
    /// After an approval or revoke, focus goes back to the button used, or,
    /// when its row is gone and it is disabled, to its list. The outcome is
    /// then read out again, since moving focus can cut it off.
    /// </summary>
    private void KeepFocusAfterChange()
    {
        if (_Used is not { } used)
        {
            return;
        }
        var (button, list) = used;
        if (button.IsEnabled)
        {
            // No, Cancel or a refused Id: the button was disabled while it asked, and is back.
            button.Focus();
        } else if (list.Items.Count > 0)
        {
            ListFocus.Focus(list, list.SelectedItem ?? list.Items[0]);
        } else
        {
            list.Focus();
        }
        Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, () => LiveRegion.AnnounceAgain(StatusText));
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e)
    {
        Close();
    }
}
