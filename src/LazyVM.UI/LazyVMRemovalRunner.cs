using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs the module's commands that delete a VM: what deleting it would delete and keep, and the delete.</summary>
public class LazyVMRemovalRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>
    /// Runs <c>Get-LazyVMRemovalPlan -Name</c> in the VM's session: what
    /// deleting the VM would delete and keep. Throws with the module's reason
    /// when nothing could be removed, such as when another VM's settings
    /// cannot be read.
    /// </summary>
    public virtual async Task<RemovalPlan> GetLazyVMRemovalPlanAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMRemovalPlan", [("Name", name)], cancellationToken).ConfigureAwait(false);
        return output.Select(LazyVMRemovalPlan).FirstOrDefault()
            ?? throw new InvalidOperationException($"Get-LazyVMRemovalPlan said nothing about {name}.");
    }

    /// <summary>
    /// Runs <c>Remove-LazyVM -Name -Force</c> in the VM's session: deletes
    /// the VM, without the question the app has already asked, then closes
    /// its session, even when only part was removed: its Hyper-V Id may be
    /// gone. Never cancelled: a removal stopped half way leaves more behind.
    /// Throws with the module's reason when it removed nothing or only part,
    /// such as while another run of the VM is going.
    /// </summary>
    public virtual async Task RemoveLazyVMAsync(Guid? vmId, string name)
    {
        try
        {
            await InvokeAsync(SessionFor(vmId), "Remove-LazyVM", [("Name", name), ("Force", true)], CancellationToken.None, failsOnlyByThrowing: true)
                .ConfigureAwait(false);
        }
        finally
        {
            if (vmId is { } id)
            {
                Sessions.Close(id);
            }
        }
    }

    /// <summary>Reads one <c>LazyVM.RemovalPlan</c> object. A size that cannot be read counts as 0.</summary>
    internal static RemovalPlan LazyVMRemovalPlan(PSObject plan)
    {
        static long Size(PSObject source, string name)
        {
            return (long)(source.Read<double?>(name, name, []) ?? 0);
        }

        return new()
        {
            Name = plan.PropertyText("Name"),
            HyperVState = plan.PropertyText("HyperVState") is { Length: > 0 } state ? state : null,
            CheckpointCount = plan.Read<int?>("CheckpointCount", "CheckpointCount", []) ?? 0,
            ScheduledTasks = plan.ReadList("Tasks").Select(task => task.BaseObject.ToString() ?? string.Empty).ToList(),
            Items = plan.ReadList("Items").Select(item => new RemovalItem(item.PropertyText("Kind"), item.PropertyText("Path"), Size(item, "Size"))).ToList(),
            TotalSize = Size(plan, "Total"),
            Kept = plan.ReadList("Kept").Select(kept => new KeptItem(kept.PropertyText("Path"), kept.PropertyText("Reason"))).ToList(),
            WorkDisks = plan.ReadList("WorkDisks")
                .Select(disk => new WorkDisk(disk.PropertyText("Name"), disk.PropertyText("Path"), Size(disk, "Size"), disk.PropertyText("Advice")))
                .ToList(),
        };
    }
}
