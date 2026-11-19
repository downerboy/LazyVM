namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The optional reason an approval of a security finding keeps, asked
/// before the question that approves it. The module records it as it is,
/// so the dialog warns not to put a password in it.
/// </summary>
public sealed class ReasonViewModel(string title, string findingId) : ViewModelBase
{
    private string _Reason = string.Empty;

    public string Title => title;

    /// <summary>Such as "Why do you expect the finding Rdp:On? You can leave this empty."</summary>
    public string Prompt => $"Why do you expect the finding {findingId}? You can leave this empty.";

    /// <summary>What the help of Approve-LazyVMSecurityFinding says about the reason.</summary>
    public string Warning => "The reason is kept with the approval, in the VM's settings. Do not put a password in it.";

    public string Reason
    {
        get => _Reason;
        set => SetProperty(ref _Reason, value);
    }
}
