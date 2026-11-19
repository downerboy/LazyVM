using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// The delete dialog. What it lists is in <see cref="ViewModels.RemovalViewModel"/>;
/// this only answers it and moves keyboard focus.
/// </summary>
public partial class RemovalWindow : Window
{
    public RemovalWindow()
    {
        InitializeComponent();
        // Focus on the first line, never on Yes, so Narrator starts reading
        // the list, and Enter answers No.
        Loaded += (_, _) =>
        {
            if (List.Items.Count > 0)
            {
                ListFocus.FocusFirst(List);
            } else
            {
                NoButton.Focus();
            }
        };
    }

    private void AnswerYes(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }
}
