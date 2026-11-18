using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// A question with Yes and No. Focus starts on No, which Narrator reads with
/// the question, so Enter never goes ahead by accident.
/// </summary>
public partial class QuestionWindow : Window
{
    public QuestionWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => NoButton.Focus();
    }

    private void AnswerYes(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }
}
