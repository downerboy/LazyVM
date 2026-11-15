using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>A VM's own window. Its behavior is in <see cref="ViewModels.VMViewModel"/>.</summary>
public partial class VMWindow : Window
{
    public VMWindow()
    {
        InitializeComponent();
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e) => Close();
}
