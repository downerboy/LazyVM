using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Asks for the optional reason of an approval. Focus starts in the reason
/// box, so Narrator reads its prompt and the warning not to put a password
/// in it. Next goes on to the question; Cancel or Esc approves nothing.
/// </summary>
public partial class ReasonWindow : Window
{
    public ReasonWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => ReasonBox.Focus();
    }

    private void Accept(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }
}
