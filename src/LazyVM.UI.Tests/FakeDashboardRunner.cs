namespace LazyVM.UI.Tests;

/// <summary>Get-LazyVMDashboard, answered from memory: for every VM, and for one.</summary>
internal sealed class FakeDashboardRunner() : LazyVMDashboardRunner(UnusedSessions.Factory)
{
    private readonly Answers<LazyVMDashboard> _Dashboards = new();
    private readonly Answers<LazyVMDashboard> _VMs = new();

    public int DashboardCalls
    {
        get; private set;
    }

    public List<string> VMCalls { get; } = [];

    /// <summary>The Hyper-V Id each Get-LazyVMDashboard -Name ran for.</summary>
    public List<Guid?> VMIds { get; } = [];

    public void Returns(params LazyVMDashboard[] entries)
    {
        _Dashboards.Returns(entries);
    }

    public void Throws(Exception exception)
    {
        _Dashboards.Throws(exception);
    }

    /// <summary>The next call waits until it is cancelled.</summary>
    public void WaitsForCancel()
    {
        _Dashboards.WaitsForCancel();
    }

    /// <summary>The next Get-LazyVMDashboard -Name finds the VM with this run.</summary>
    public void ReturnsRun(VMRun? run, string name = "DevBox")
    {
        _VMs.Returns([Sample.VM(name) with { Run = run }]);
    }

    public void VMThrows(Exception exception)
    {
        _VMs.Throws(exception);
    }

    public override Task<IReadOnlyList<LazyVMDashboard>> GetLazyVMDashboardAsync(CancellationToken cancellationToken)
    {
        DashboardCalls++;
        return _Dashboards.Next(cancellationToken);
    }

    public override async Task<LazyVMDashboard?> GetLazyVMAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        VMCalls.Add(name);
        VMIds.Add(vmId);
        return (await _VMs.Next(cancellationToken)).FirstOrDefault();
    }
}
