using LazyVM.UI.Wpf.ViewModels;
using System.ComponentModel;
using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>A VM's Recovery keys window. Its behavior is in <see cref="RecoveryKeysViewModel"/>; this only moves keyboard focus.</summary>
public partial class RecoveryKeysWindow : Window
{
    public RecoveryKeysWindow()
    {
        InitializeComponent();
        // Once the keys are read, focus goes to the first, so Narrator reads it.
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is RecoveryKeysViewModel old)
            {
                old.PropertyChanged -= FocusOnKeys;
            }
            if (e.NewValue is RecoveryKeysViewModel now)
            {
                now.PropertyChanged += FocusOnKeys;
            }
        };
    }

    private void FocusOnKeys(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(RecoveryKeysViewModel.Keys) && sender is RecoveryKeysViewModel { IsExporting: false })
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
