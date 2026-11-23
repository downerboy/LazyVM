using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs <c>Test-LazyVM</c>, for the host or a VM, and reads its checks.</summary>
public class LazyVMChecksRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>
    /// Runs <c>Test-LazyVM</c>: the checks of the VM <paramref name="name"/>,
    /// in its session, or with no name, of the host and the only VM, if there
    /// is one, in the host's. <paramref name="hostOnly"/> checks the host alone.
    /// </summary>
    public virtual async Task<IReadOnlyList<VMCheck>> GetLazyVMChecksAsync(Guid? vmId, string? name, bool hostOnly, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(
            SessionFor(vmId), "Test-LazyVM", Present(("Name", name), ("HostOnly", hostOnly ? true : null)), cancellationToken)
            .ConfigureAwait(false);
        return output.Select(LazyVMCheck).ToList();
    }

    /// <summary>Reads one <c>LazyVM.Check</c> object.</summary>
    internal static VMCheck LazyVMCheck(PSObject check)
    {
        return new(
            check.PropertyText("Area"),
            check.PropertyText("Check"),
            check.PropertyText("Status"),
            check.PropertyText("Detail"),
            check.PropertyText("Fix"));
    }
}
