using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>A VM's own window. Its behavior is in <see cref="ViewModels.VMViewModel"/>.</summary>
public partial class VMWindow : Window
{
    public VMWindow()
    {
        InitializeComponent();
        // The phase chosen for the VM, such as the one its last build failed in, may be below the list's fold.
        PhaseList.SelectionChanged += (_, _) =>
        {
            if (PhaseList.SelectedItem is { } chosen)
            {
                PhaseList.ScrollIntoView(chosen);
            }
        };
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e) => Close();
}
