namespace LazyVM.UI.Tests;

/// <summary>Get-LazyVMRestorePoint and Restore-LazyVMTooling, answered from memory.</summary>
internal sealed class FakeRestoreRunner() : LazyVMRestoreRunner(UnusedSessions.Factory, new RestoreLauncher())
{
    private readonly Answers<VMRestorePoint> _RestorePoints = new();

    public List<string> RestorePointCalls { get; } = [];

    public List<(string Name, string Stamp)> RestoreCalls { get; } = [];

    /// <summary>Restore-LazyVMTooling fails with this.</summary>
    public Exception? RestoreFails
    {
        get; set;
    }

    /// <summary>When set, Restore-LazyVMTooling runs until the test completes it.</summary>
    public TaskCompletionSource? RestoreGate
    {
        get; set;
    }

    /// <summary>The next Get-LazyVMRestorePoint returns these points, oldest first as the module does.</summary>
    public void ReturnsRestorePoints(params VMRestorePoint[] points)
    {
        _RestorePoints.Returns(points);
    }

    public void RestorePointsThrow(Exception exception)
    {
        _RestorePoints.Throws(exception);
    }

    public override Task<IReadOnlyList<VMRestorePoint>> GetLazyVMRestorePointsAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        RestorePointCalls.Add(name);
        return _RestorePoints.Next(cancellationToken);
    }

    public override async Task RestoreLazyVMToolingAsync(Guid? vmId, string name, string stamp)
    {
        RestoreCalls.Add((name, stamp));
        if (RestoreGate is { } gate)
        {
            await gate.Task;
        }
        if (RestoreFails is { } failure)
        {
            throw failure;
        }
    }
}
