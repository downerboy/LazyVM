using System.ComponentModel;
using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>The Checks window. Its behavior is in <see cref="ChecksViewModel"/>; this only moves keyboard focus and copies.</summary>
public partial class ChecksWindow : Window
{
    public ChecksWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is INotifyPropertyChanged old)
            {
                old.PropertyChanged -= FocusNewChecks;
            }
            if (e.NewValue is INotifyPropertyChanged now)
            {
                now.PropertyChanged += FocusNewChecks;
            }
        };
        Loaded += (_, _) => ListFocus.FocusFirst(List);
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e)
    {
        Close();
    }

    /// <summary>When the checks come in, Narrator starts reading them from the first.</summary>
    private void FocusNewChecks(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ChecksViewModel.Checks) && IsActive)
        {
            ListFocus.FocusFirst(List);
        }
    }

    /// <summary>Ctrl+C copies the selected check's fix, or the whole check when it has none.</summary>
    private void CopyFix(object sender, ExecutedRoutedEventArgs e)
    {
        if (List.SelectedItem is CheckRowViewModel row)
        {
            RowCopy.Put(row.HasFix ? row.Fix : row.AutomationName);
        }
    }
}
