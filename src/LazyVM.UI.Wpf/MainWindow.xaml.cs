using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>The main window: the list of VMs. Its behavior is in <see cref="ViewModels.MainViewModel"/>.</summary>
public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    /// <summary>
    /// Selects the row that has keyboard focus. Tab into the list focuses a
    /// cell without selecting its row, and with one VM the arrow keys cannot
    /// select it either, so Enter would open nothing.
    /// </summary>
    private void SelectFocusedRow(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (e.NewFocus is DependencyObject focused && DataGridRow.GetRowContainingElement(focused as FrameworkElement) is { IsSelected: false } row)
        {
            row.IsSelected = true;
        }
    }
}
