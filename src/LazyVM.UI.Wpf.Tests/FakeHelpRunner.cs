namespace LazyVM.UI.Wpf.Tests;

/// <summary>Show-LazyVMHelp, answered from memory: no browser opens.</summary>
internal sealed class FakeHelpRunner() : LazyVMHelpRunner(UnusedSessions.Factory)
{
    public List<HelpTopic> HelpCalls { get; } = [];

    /// <summary>Show-LazyVMHelp fails with this, as it does when no browser opens.</summary>
    public Exception? HelpFails
    {
        get; set;
    }

    public override Task ShowLazyVMHelpAsync(HelpTopic topic, CancellationToken cancellationToken)
    {
        HelpCalls.Add(topic);
        return HelpFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }
}
