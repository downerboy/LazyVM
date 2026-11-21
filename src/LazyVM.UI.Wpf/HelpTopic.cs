namespace LazyVM.UI.Wpf;

/// <summary>
/// The documentation pages <c>Show-LazyVMHelp -Topic</c> opens (#501). The
/// names are the module's, so the app can only ask for pages it has.
/// </summary>
public enum HelpTopic
{
    /// <summary>The guide to installing and using LazyVM.</summary>
    Guide,

    /// <summary>What LazyVM is for, case by case.</summary>
    UseCases,

    /// <summary>The flow of each command, as pictures and numbered lists.</summary>
    Diagrams,
}
