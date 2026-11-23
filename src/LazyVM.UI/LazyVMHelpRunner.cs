namespace LazyVM.UI;

/// <summary>Runs <c>Show-LazyVMHelp</c>, which opens a page of the documentation.</summary>
public class LazyVMHelpRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>
    /// Runs <c>Show-LazyVMHelp -Topic</c>: opens the page in the browser, for
    /// the installed version. It only opens an address. Throws with the
    /// module's reason when the browser did not open.
    /// </summary>
    public virtual async Task ShowLazyVMHelpAsync(HelpTopic topic, CancellationToken cancellationToken)
    {
        await InvokeAsync(Sessions.ForHost(), "Show-LazyVMHelp", [("Topic", topic.ToString())], cancellationToken, failsOnlyByThrowing: true, failsByItsOwnErrors: true)
            .ConfigureAwait(false);
    }
}
