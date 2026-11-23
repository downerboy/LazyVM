using LazyVM.UI.Wpf.ViewModels;

using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Opens the Checks, Log, Build and build progress windows: one Checks window
/// for the host and one per VM, one Log window per VM, one Build window, and
/// one progress window per VM. Opening one that is open brings it to the
/// front instead. It also starts the runs a VM window offers: a build from
/// a chosen phase, shown in its progress window, and maintenance; and
/// deletes a VM, once its delete dialog has had a Yes. One Restore window
/// per VM lists its restore points, and returns the VM to one after asking.
/// One Recovery keys window per VM lists its BitLocker recovery keys, shows
/// a password only when asked, and exports the keys to a file. One Password
/// window per VM shows the account LazyVM signs in with, its password hidden
/// until asked for, and copies it to the clipboard for three minutes. One
/// Security findings window per VM lists what its last scan found, and the
/// findings approved, and approves or revokes one after asking. A command
/// about a VM takes its Hyper-V Id, empty for a VM not built yet, so it runs
/// in the VM's own PowerShell session.
/// </summary>
public class ToolWindows(Runners runners, WindowTracker windows, Dialogs dialogs, BuildLauncher launcher, TimeProvider clock, SecretClipboard? clipboard = null)
{
    private const string _BUILD_KEY = "build";

    /// <summary>
    /// Raised when a build ended, a build or maintenance started, a delete,
    /// a restore or an export of recovery keys ended (even one that failed),
    /// or a security finding was approved or revoked, so the list can be read again.
    /// </summary>
    public ListChanges Changes { get; } = new();

    /// <summary>Every phase of a build, for choosing the one a build starts at.</summary>
    public virtual Task<IReadOnlyList<BuildPhase>> GetBuildPhasesAsync(CancellationToken cancellationToken)
    {
        return runners.Build.GetLazyVMBuildPhasesAsync(cancellationToken);
    }

    /// <summary>
    /// Starts building an existing VM, such as from the phase a failed build
    /// was in, in a pwsh process of its own, and shows its progress. Throws
    /// when it could not start.
    /// </summary>
    public virtual async Task StartBuildAsync(Guid? vmId, BuildRequest request)
    {
        var moduleFolder = await runners.Build.GetModuleFolderAsync(CancellationToken.None);
        var build = launcher.Start(request, moduleFolder);
        OpenProgress(vmId, request.Name, build);
        Changes.Raise();
    }

    /// <summary>Starts the VM's maintenance task, as the nightly run does. Throws with the reason when it did not start.</summary>
    public virtual async Task StartMaintenanceAsync(Guid? vmId, string vmName)
    {
        await runners.Build.StartLazyVMMaintenanceAsync(vmId, vmName, CancellationToken.None);
        Changes.Raise();
    }

    /// <summary>Opens the documentation page in the browser. Throws with the reason when the browser did not open.</summary>
    public virtual Task OpenHelpAsync(HelpTopic topic)
    {
        return runners.Help.ShowLazyVMHelpAsync(topic, CancellationToken.None);
    }

    /// <summary>What deleting the VM would delete and keep. Throws with the reason when it cannot be deleted.</summary>
    public virtual Task<RemovalPlan> GetRemovalPlanAsync(Guid? vmId, string vmName)
    {
        return runners.Removal.GetLazyVMRemovalPlanAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>
    /// Deletes the VM, without asking: <see cref="Dialogs.ConfirmRemoval"/> has, and
    /// closes its PowerShell session. Throws with what went wrong, such as
    /// what is left.
    /// </summary>
    public virtual async Task RemoveVMAsync(Guid? vmId, string vmName)
    {
        try
        {
            await runners.Removal.RemoveLazyVMAsync(vmId, vmName);
        }
        finally
        {
            Changes.Raise();
        }
    }

    /// <summary>The VM's restore points, oldest first.</summary>
    public virtual Task<IReadOnlyList<VMRestorePoint>> GetRestorePointsAsync(Guid? vmId, string vmName)
    {
        return runners.Restore.GetLazyVMRestorePointsAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>Returns the VM to a restore point, without asking: <see cref="Dialogs.ConfirmRestore"/> has. Throws with the module's reason when it did not.</summary>
    public virtual async Task RestoreToolingAsync(Guid? vmId, string vmName, string stamp)
    {
        try
        {
            await runners.Restore.RestoreLazyVMToolingAsync(vmId, vmName, stamp);
        }
        finally
        {
            Changes.Raise();
        }
    }

    /// <summary>
    /// Shows the VM's restore points, or brings its open window to the front,
    /// and returns the window's view model, so a refresh can reach it.
    /// </summary>
    public RestoreViewModel OpenRestore(LazyVMDashboard entry)
    {
        var key = "restore:" + entry.Name;
        if (windows.Activate<RestoreViewModel>(key) is { } open)
        {
            return open;
        }
        var restore = new RestoreViewModel(entry, this, dialogs);
        windows.Track(key, restore);
        _ = restore.LoadAsync();
        return restore;
    }

    /// <summary>The VM's recovery keys, without their passwords.</summary>
    public virtual Task<IReadOnlyList<VMRecoveryKey>> GetRecoveryKeysAsync(Guid? vmId, string vmName)
    {
        return runners.RecoveryKeys.GetLazyVMRecoveryKeysAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>The recovery password of one of the VM's disks, read now, to be shown.</summary>
    public virtual Task<string> GetRecoveryPasswordAsync(Guid? vmId, string vmName, string diskGuid)
    {
        return runners.RecoveryKeys.GetLazyVMRecoveryPasswordAsync(vmId, vmName, diskGuid, CancellationToken.None);
    }

    /// <summary>Writes the VM's recovery keys to <paramref name="path"/>, replacing it when <paramref name="force"/>. Throws with the module's reason when it did not.</summary>
    public virtual async Task<RecoveryKeyExport> ExportRecoveryKeysAsync(Guid? vmId, string vmName, string path, bool force)
    {
        try
        {
            return await runners.RecoveryKeys.ExportLazyVMRecoveryKeysAsync(vmId, vmName, path, force);
        }
        finally
        {
            Changes.Raise();
        }
    }

    /// <summary>
    /// Shows the VM's recovery keys, or brings its open window to the front.
    /// Closing the window forgets every password it showed.
    /// </summary>
    public RecoveryKeysViewModel OpenRecoveryKeys(LazyVMDashboard entry)
    {
        var key = "recovery-keys:" + entry.Name;
        if (windows.Activate<RecoveryKeysViewModel>(key) is { } open)
        {
            return open;
        }
        var keys = new RecoveryKeysViewModel(entry, this, dialogs);
        windows.Track(key, keys, keys.Forget);
        _ = keys.LoadAsync();
        return keys;
    }

    /// <summary>The clipboard a copied password goes on, for the whole app: the app clears it when it closes.</summary>
    public SecretClipboard Clipboard { get; } = clipboard ?? new SecretClipboard(clock);

    /// <summary>The user name LazyVM signs in to the VM with. Throws with the module's reason, such as when none is stored.</summary>
    public virtual Task<string> GetUserNameAsync(Guid? vmId, string vmName)
    {
        return runners.Credentials.GetLazyVMUserNameAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>The VM's password, read now, to be shown or copied.</summary>
    public virtual Task<string> GetPasswordAsync(Guid? vmId, string vmName)
    {
        return runners.Credentials.GetLazyVMPasswordAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>Shows the account LazyVM signs in to the VM with, or brings its open window to the front. Closing the window forgets the password.</summary>
    public PasswordViewModel OpenPassword(LazyVMDashboard entry)
    {
        var key = "password:" + entry.Name;
        if (windows.Activate<PasswordViewModel>(key) is { } open)
        {
            return open;
        }
        var password = new PasswordViewModel(entry, this);
        windows.Track(key, password, password.Forget);
        _ = password.LoadAsync();
        return password;
    }

    /// <summary>The findings of the VM's last security scan, less the approved ones.</summary>
    public virtual Task<IReadOnlyList<VMSecurityFinding>> GetSecurityFindingsAsync(Guid? vmId, string vmName)
    {
        return runners.SecurityFindings.GetLazyVMSecurityFindingsAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>The VM's approved findings, with when and why each was approved.</summary>
    public virtual Task<IReadOnlyList<VMSecurityApproval>> GetSecurityApprovalsAsync(Guid? vmId, string vmName)
    {
        return runners.SecurityFindings.GetLazyVMSecurityApprovalsAsync(vmId, vmName, CancellationToken.None);
    }

    /// <summary>Approves the finding, without asking: <see cref="Dialogs.ConfirmSecurityChange"/> has. Throws with the module's reason when it refused.</summary>
    public virtual async Task ApproveSecurityFindingAsync(Guid? vmId, string vmName, string id, string reason)
    {
        try
        {
            await runners.SecurityFindings.ApproveLazyVMSecurityFindingAsync(vmId, vmName, id, reason);
        }
        finally
        {
            Changes.Raise();
        }
    }

    /// <summary>Revokes the approval, without asking: <see cref="Dialogs.ConfirmSecurityChange"/> has. Throws with the module's reason when it refused.</summary>
    public virtual async Task RevokeSecurityFindingAsync(Guid? vmId, string vmName, string id)
    {
        try
        {
            await runners.SecurityFindings.RevokeLazyVMSecurityFindingAsync(vmId, vmName, id);
        }
        finally
        {
            Changes.Raise();
        }
    }

    /// <summary>
    /// Shows the VM's security findings and approved findings, or brings its
    /// open window to the front, and returns the window's view model, so a
    /// refresh can reach it.
    /// </summary>
    public SecurityFindingsViewModel OpenSecurityFindings(LazyVMDashboard entry)
    {
        var key = "security-findings:" + entry.Name;
        if (windows.Activate<SecurityFindingsViewModel>(key) is { } open)
        {
            return open;
        }
        var findings = new SecurityFindingsViewModel(entry, this, dialogs);
        windows.Track(key, findings);
        _ = findings.LoadAsync();
        return findings;
    }

    /// <summary>Shows the checks of the VM <paramref name="vmName"/>, or of the host, and runs them.</summary>
    public void OpenChecks(Guid? vmId, string? vmName, bool hostOnly)
    {
        if (windows.Activate<ChecksViewModel>(ChecksKey(vmName)) is not null)
        {
            return;
        }
        var checks = new ChecksViewModel(runners.Checks, vmId, vmName, hostOnly);
        windows.Track(ChecksKey(vmName), checks);
        _ = checks.RunAsync();
    }

    /// <summary>Shows checks that have already run, such as the ones made when the app starts.</summary>
    public void ShowChecks(ChecksViewModel checks)
    {
        if (windows.Activate<ChecksViewModel>(ChecksKey(checks.VMName)) is null)
        {
            windows.Track(ChecksKey(checks.VMName), checks);
        }
    }

    /// <summary>Shows the VM's log and reads it.</summary>
    public void OpenLog(Guid? vmId, string vmName)
    {
        var key = "log:" + vmName;
        if (windows.Activate<LogViewModel>(key) is not null)
        {
            return;
        }
        var log = new LogViewModel(runners.Log, vmId, vmName);
        windows.Track(key, log);
        _ = log.LoadAsync();
    }

    /// <summary>Shows the Build new VM window. <paramref name="existingNames"/> are the VMs there are already.</summary>
    public void OpenBuild(IEnumerable<string> existingNames)
    {
        if (windows.Activate<BuildViewModel>(_BUILD_KEY) is not null)
        {
            return;
        }
        // A new VM has no Hyper-V Id until its build creates it.
        var build = new BuildViewModel(runners.Build, launcher, existingNames, (name, started) => OpenProgress(null, name, started));
        windows.Track(_BUILD_KEY, build);
        _ = build.LoadAsync();
    }

    /// <summary>Shows the VM's window, or brings its open window to the front. A VM that is deleted closes its window.</summary>
    public void OpenVM(LazyVMDashboard entry)
    {
        var key = VMKey(entry.Name);
        if (windows.Activate<VMViewModel>(key) is not null)
        {
            return;
        }
        var viewModel = new VMViewModel(entry, this, dialogs);
        // A deleted VM has nothing left to show.
        viewModel.Removed += (_, _) => windows.Close(viewModel);
        windows.Track(key, viewModel);
        _ = viewModel.LoadAsync();
    }

    /// <summary>Shows what a refresh read in the VM windows that are open.</summary>
    public void UpdateVMs(IEnumerable<LazyVMDashboard> entries)
    {
        foreach (var entry in entries)
        {
            windows.Find<VMViewModel>(VMKey(entry.Name))?.Update(entry);
        }
    }

    /// <summary>
    /// Shows the progress of the VM's build: of <paramref name="started"/>,
    /// the build the app has just started, or with none, of the build
    /// running now. Closing the window stops only the following.
    /// </summary>
    public void OpenProgress(Guid? vmId, string vmName, StartedBuild? started)
    {
        var key = "progress:" + vmName;
        if (windows.Find<BuildProgressViewModel>(key) is { } existing)
        {
            if (started is null || !existing.IsFinished)
            {
                windows.Activate<BuildProgressViewModel>(key);
                return;
            }
            // A new build of the same VM: the window of the last one makes way for it.
            windows.Close(key);
        }
        var progress = new BuildProgressViewModel(runners.Dashboard, runners.Build, vmId, vmName, started, clock,
            phase => StartBuildAsync(vmId, new BuildRequest(vmName, null, null, phase)));
        progress.Ended += (_, _) => Changes.Raise();
        windows.Track(key, progress, progress.StopFollowing);
        _ = progress.FollowAsync();
    }

    private static string ChecksKey(string? vmName)
    {
        return "checks:" + (vmName ?? string.Empty);
    }

    private static string VMKey(string vmName)
    {
        return "vm:" + vmName;
    }
}
