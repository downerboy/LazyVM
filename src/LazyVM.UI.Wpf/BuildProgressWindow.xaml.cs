using System.Windows;
using System.Windows.Input;
using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf;

/// <summary>
/// The build progress window. Its behavior is in <see cref="BuildProgressViewModel"/>;
/// this only closes. Closing it stops the following, never the build.
/// </summary>
public partial class BuildProgressWindow : Window
{
    public BuildProgressWindow()
    {
        InitializeComponent();
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e) => Close();
}
