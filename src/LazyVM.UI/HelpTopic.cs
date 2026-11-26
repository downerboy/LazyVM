namespace LazyVM.UI;

/// <summary>
/// The documentation pages <c>Show-LazyVMHelp -Topic</c> opens (#501). The
/// names are the module's, so the app can only ask for pages it has.
/// </summary>
public enum HelpTopic
{
    /// <summary>The guide to installing and using LazyVM.</summary>
    Guide,

    /// <summary>The guide's section on what to do when something goes wrong.</summary>
    Troubleshooting,
}
