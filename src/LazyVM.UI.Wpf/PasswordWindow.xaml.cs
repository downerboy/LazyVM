using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>A VM's Password window. Its behavior is in <see cref="ViewModels.PasswordViewModel"/>; this only blocks copying and closes.</summary>
public partial class PasswordWindow : Window
{
    public PasswordWindow()
    {
        InitializeComponent();
    }

    /// <summary>The password is never copied or dragged out of its box: Copy password puts it on the clipboard the safe way.</summary>
    private void BlockCopy(object sender, DataObjectCopyingEventArgs e)
    {
        e.CancelCommand();
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e)
    {
        Close();
    }
}
