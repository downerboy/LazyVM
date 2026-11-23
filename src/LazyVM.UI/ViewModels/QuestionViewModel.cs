namespace LazyVM.UI.ViewModels;

/// <summary>A question with Yes and No, No the default, such as the one a restore asks first.</summary>
public sealed class QuestionViewModel(string title, string question) : ViewModelBase
{
    public string Title => title;

    public string Question => question;
}
