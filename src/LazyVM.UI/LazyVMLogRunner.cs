using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs <c>Get-LazyVMLog</c> and reads a VM's log entries.</summary>
public class LazyVMLogRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>
    /// Runs <c>Get-LazyVMLog -Name -Tail</c> in the VM's session: the last
    /// <paramref name="tail"/> entries of its log, oldest first. None before
    /// there is a log.
    /// </summary>
    public virtual async Task<IReadOnlyList<VMLogEntry>> GetLazyVMLogAsync(Guid? vmId, string name, int tail, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMLog", [("Name", name), ("Tail", tail)], cancellationToken).ConfigureAwait(false);
        return output.Select(LazyVMLogEntry).ToList();
    }

    /// <summary>Reads one <c>LazyVM.LogEntry</c> object. A time that cannot be read is left empty.</summary>
    internal static VMLogEntry LazyVMLogEntry(PSObject entry)
    {
        return new(
            entry.ReadDate("Time", "Time", []),
            entry.PropertyText("Level"),
            entry.PropertyText("Message"));
    }
}
