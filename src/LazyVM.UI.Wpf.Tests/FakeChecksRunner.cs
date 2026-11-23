namespace LazyVM.UI.Wpf.Tests;

/// <summary>Test-LazyVM, answered from memory.</summary>
internal sealed class FakeChecksRunner() : LazyVMChecksRunner(UnusedSessions.Factory)
{
    private readonly Answers<VMCheck> _Checks = new();

    public List<(string? Name, bool HostOnly)> CheckCalls { get; } = [];

    /// <summary>The Hyper-V Id each Test-LazyVM ran for.</summary>
    public List<Guid?> CheckIds { get; } = [];

    public void ReturnsChecks(params VMCheck[] results)
    {
        _Checks.Returns(results);
    }

    public void ChecksThrow(Exception exception)
    {
        _Checks.Throws(exception);
    }

    public void ChecksWaitForCancel()
    {
        _Checks.WaitsForCancel();
    }

    public override Task<IReadOnlyList<VMCheck>> GetLazyVMChecksAsync(Guid? vmId, string? name, bool hostOnly, CancellationToken cancellationToken)
    {
        CheckCalls.Add((name, hostOnly));
        CheckIds.Add(vmId);
        return _Checks.Next(cancellationToken);
    }
}
