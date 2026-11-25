namespace LazyVM.UI.ViewModels;

/// <summary>
/// One thing that needs attention in a VM's window, what is wrong in words,
/// and the button that opens the window to put it right.
/// </summary>
public sealed record VMAttentionReason(string Text, string ButtonText, RelayCommand Command)
{
    /// <summary>The button for a screen reader: what it opens, and for which VM.</summary>
    public string AutomationName => $"{ButtonText}: {Text}";
}
