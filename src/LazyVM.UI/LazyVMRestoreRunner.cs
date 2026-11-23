using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>
/// Runs the module's commands about a VM's restore points: listing them, and
/// returning the VM to one, which runs in a pwsh process of its own
/// (<see cref="RestoreLauncher"/>) so closing the app cannot stop it part way.
/// </summary>
public class LazyVMRestoreRunner(PowerShellSessionFactory sessions, RestoreLauncher launcher) : PowerShellCommandRunner(sessions)
{
    /// <summary>Runs <c>Get-LazyVMRestorePoint -Name</c> in the VM's session: its restore points, oldest first. None before the first.</summary>
    public virtual async Task<IReadOnlyList<VMRestorePoint>> GetLazyVMRestorePointsAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMRestorePoint", [("Name", name)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return output.Select(LazyVMToRestorePoint).ToList();
    }

    /// <summary>
    /// Runs <c>Restore-LazyVMTooling -Name -RestorePoint -Force</c> in a pwsh
    /// process of its own: returns the VM to the restore point
    /// <paramref name="stamp"/>, without the question the app has already
    /// asked. Never cancelled: a revert stopped half way leaves the VM
    /// between the two. Throws with the module's reason when it did not,
    /// such as while another run of the VM is going.
    /// </summary>
    public virtual async Task RestoreLazyVMToolingAsync(Guid? vmId, string name, string stamp)
    {
        await RunInOwnProcessAsync(moduleFolder => launcher.Start(new RestoreRequest(name, stamp), moduleFolder)).ConfigureAwait(false);
    }

    /// <summary>Reads one <c>LazyVM.RestorePoint</c> object. A time that cannot be read is left empty.</summary>
    internal static VMRestorePoint LazyVMToRestorePoint(PSObject point)
    {
        return new(
            point.PropertyText("RestorePoint"),
            point.ReadDate("Taken", "Taken", []),
            point.Read<bool?>("HasToolingList", "HasToolingList", []) ?? false);
    }
}
