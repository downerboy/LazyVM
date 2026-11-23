namespace LazyVM.UI.Tests;

/// <summary>Get-LazyVMLog, answered from memory.</summary>
internal sealed class FakeLogRunner() : LazyVMLogRunner(UnusedSessions.Factory)
{
    private readonly Answers<VMLogEntry> _Logs = new();

    public List<(string Name, int Tail)> LogCalls { get; } = [];

    /// <summary>The Hyper-V Id each Get-LazyVMLog ran for.</summary>
    public List<Guid?> LogIds { get; } = [];

    public void ReturnsLog(params VMLogEntry[] entries)
    {
        _Logs.Returns(entries);
    }

    public void LogThrows(Exception exception)
    {
        _Logs.Throws(exception);
    }

    public override Task<IReadOnlyList<VMLogEntry>> GetLazyVMLogAsync(Guid? vmId, string name, int tail, CancellationToken cancellationToken)
    {
        LogCalls.Add((name, tail));
        LogIds.Add(vmId);
        return _Logs.Next(cancellationToken);
    }
}
