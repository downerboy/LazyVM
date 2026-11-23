using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs the module's commands about a VM's BitLocker recovery keys: listing them, one password, and exporting them.</summary>
public class LazyVMRecoveryKeysRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>Runs <c>Get-LazyVMRecoveryKey -Name</c> in the VM's session: its recovery keys, without their passwords. None while none is stored.</summary>
    public virtual async Task<IReadOnlyList<VMRecoveryKey>> GetLazyVMRecoveryKeysAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMRecoveryKey", [("Name", name)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return output.Select(LazyVMRecoveryKey).ToList();
    }

    /// <summary>
    /// Runs <c>Get-LazyVMCredential -Name -RecoveryPassword</c> in the VM's
    /// session and gives only the password of the disk
    /// <paramref name="diskGuid"/>, for the moment it is shown. The others
    /// are not kept.
    /// </summary>
    public virtual async Task<string> GetLazyVMRecoveryPasswordAsync(Guid? vmId, string name, string diskGuid, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(
            SessionFor(vmId), "Get-LazyVMCredential", [("Name", name), ("RecoveryPassword", true)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return LazyVMDiskRecoveryPasswordOf(output, diskGuid);
    }

    /// <summary>
    /// Runs <c>Export-LazyVMRecoveryKey -Name -Path</c> in the VM's session,
    /// with <c>-Force</c> when <paramref name="force"/>, which the app passes
    /// only after asking. Never cancelled. Gives the file written and the
    /// module's warnings. Throws with the module's reason when nothing was
    /// written.
    /// </summary>
    public virtual async Task<RecoveryKeyExport> ExportLazyVMRecoveryKeysAsync(Guid? vmId, string name, string path, bool force)
    {
        var (output, warnings) = await InvokeWithWarningsAsync(
            SessionFor(vmId), "Export-LazyVMRecoveryKey", Present(("Name", name), ("Path", path), ("Force", force ? true : null)), CancellationToken.None,
            failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        var written = output.Select(file => file.PropertyText("FullName")).FirstOrDefault(full => full.Length > 0) ?? path;
        return new RecoveryKeyExport(written, warnings);
    }

    /// <summary>Reads one <c>LazyVM.RecoveryKey</c> object. A date that cannot be read is left empty.</summary>
    internal static VMRecoveryKey LazyVMRecoveryKey(PSObject key)
    {
        return new(
            key.PropertyText("Disk"),
            key.PropertyText("DiskGuid"),
            key.PropertyText("KeyId"),
            key.ReadDate("Recorded", "Recorded", []),
            key.Read<bool?>("Exported", "Exported", []) ?? false);
    }

    /// <summary>The recovery password of the disk <paramref name="diskGuid"/> among <paramref name="keys"/>. Throws when it has none.</summary>
    internal static string LazyVMDiskRecoveryPasswordOf(IEnumerable<PSObject> keys, string diskGuid)
    {
        return keys
            .Where(key => string.Equals(key.PropertyText("DiskGuid"), diskGuid, StringComparison.OrdinalIgnoreCase))
            .Select(key => key.PropertyText("RecoveryPassword"))
            .FirstOrDefault(password => password.Length > 0)
            ?? throw new InvalidOperationException(
                "No recovery password is stored for that disk now. Close this window and open it again to see the keys stored now.");
    }
}
