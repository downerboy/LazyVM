namespace LazyVM.UI.Tests;

/// <summary>Get-LazyVMRemovalPlan and Remove-LazyVM, answered from memory.</summary>
internal sealed class FakeRemovalRunner() : LazyVMRemovalRunner(UnusedSessions.Factory, new RemovalLauncher())
{
    private readonly Answers<RemovalPlan> _RemovalPlans = new();

    public List<string> RemovalPlanCalls { get; } = [];

    /// <summary>The Hyper-V Id each Get-LazyVMRemovalPlan ran for, in order.</summary>
    public List<Guid?> RemovalPlanIds { get; } = [];

    public List<string> RemoveCalls { get; } = [];

    /// <summary>The Hyper-V Id each Remove-LazyVM ran for.</summary>
    public List<Guid?> RemoveIds { get; } = [];

    /// <summary>Remove-LazyVM fails with this, as the module does for a partial removal.</summary>
    public Exception? RemoveFails
    {
        get; set;
    }

    /// <summary>When set, Remove-LazyVM runs until the test completes it.</summary>
    public TaskCompletionSource? RemoveGate
    {
        get; set;
    }

    /// <summary>The next Get-LazyVMRemovalPlan returns this plan.</summary>
    public void ReturnsRemovalPlan(RemovalPlan plan)
    {
        _RemovalPlans.Returns([plan]);
    }

    public void RemovalPlanThrows(Exception exception)
    {
        _RemovalPlans.Throws(exception);
    }

    public override async Task<RemovalPlan> GetLazyVMRemovalPlanAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        RemovalPlanCalls.Add(name);
        RemovalPlanIds.Add(vmId);
        return (await _RemovalPlans.Next(cancellationToken))[0];
    }

    public override async Task RemoveLazyVMAsync(Guid? vmId, string name)
    {
        RemoveCalls.Add(name);
        RemoveIds.Add(vmId);
        if (RemoveGate is { } gate)
        {
            await gate.Task;
        }
        if (RemoveFails is { } failure)
        {
            throw failure;
        }
    }
}
