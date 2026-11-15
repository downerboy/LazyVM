using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>The main window: the list of VMs. Its behavior is in <see cref="ViewModels.MainViewModel"/>.</summary>
public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }
}
